#!/usr/bin/env python3
"""Fake phone for testing the Mac receiver without an iPhone.

Builds packets straight from the spec in docs/ARCHITECTURE.md rather than reusing the
Swift encoder, so a mismatch between the two is a real finding and not a shared bug.

    python3 fake-phone.py 127.0.0.1
"""

import socket
import struct
import sys
import threading
import time

PORT = 51888
VERSION = 1
T_TOUCH_FRAME = 0x01
T_HELLO = 0x02
T_ECHO_REPLY = 0x10

COORD_SCALE = 16384
RADIUS_SCALE = 256

# iPhone 15 Pro-ish. Only the ratio and magnitude matter here.
SURFACE_W_MM = 70.6
SURFACE_H_MM = 146.7

PHASE_BEGAN, PHASE_MOVED, PHASE_STATIONARY = 0, 1, 2


def hello(session_id):
    return struct.pack(
        "<BBIffB", VERSION, T_HELLO, session_id, SURFACE_W_MM, SURFACE_H_MM, 5
    )


def touch_frame(seq, t_us, contacts, flags=0):
    out = struct.pack("<BBHIBB", VERSION, T_TOUCH_FRAME, seq & 0xFFFF, t_us & 0xFFFFFFFF,
                      len(contacts), flags)
    for cid, phase, x, y, radius_mm in contacts:
        out += struct.pack(
            "<BBhhH", cid, phase,
            max(-32768, min(32767, round(x * COORD_SCALE))),
            max(-32768, min(32767, round(y * COORD_SCALE))),
            max(0, min(65535, round(radius_mm * RADIUS_SCALE))),
        )
    return out


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((host, PORT))
    sock.settimeout(0.2)

    session_id = int(time.time()) & 0xFFFFFFFF
    start = time.monotonic()

    def t_us():
        return int((time.monotonic() - start) * 1e6)

    print(f"→ {host}:{PORT}  session {session_id:08x}")
    for _ in range(3):  # hello is not loss-tolerant; repeat it
        sock.send(hello(session_id))
        time.sleep(0.01)

    rtts = []
    stop = threading.Event()

    # Echoes must be timestamped the moment they land. Polling once per frame between
    # sleeps measures the poll interval, not the round trip — the first version of this
    # script reported 10 ms over loopback for exactly that reason.
    def reader():
        while not stop.is_set():
            try:
                data = sock.recv(64)
            except (socket.timeout, BlockingIOError):
                continue
            except OSError:
                return
            if len(data) == 12 and data[1] == T_ECHO_REPLY:
                _, _, _, sent_us, _ = struct.unpack("<BBHII", data)
                rtts.append((t_us() - sent_us) / 1000.0)

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    def drain():
        pass  # the reader thread handles it; kept so the phases below read the same

    seq = 0
    hz = 120
    step = 1.0 / hz

    # 1. Drag one finger to the right across the middle of the surface.
    print("… sweeping one finger right")
    frames = 60
    for i in range(frames):
        x = 0.30 + 0.40 * (i / (frames - 1))
        phase = PHASE_BEGAN if i == 0 else PHASE_MOVED
        sock.send(touch_frame(seq, t_us(), [(0, phase, x, 0.5, 8.0)]))
        seq += 1
        time.sleep(step)
        drain()

    # 2. Lift, slowly enough that it is not read as a tap.
    sock.send(touch_frame(seq, t_us(), []))
    seq += 1
    time.sleep(0.2)
    drain()

    # 3. A duplicate and a stale sequence number. Both must be discarded — watch "lost"
    #    stay put and the cursor not jump.
    print("… replaying a duplicate and a stale frame (both should be dropped)")
    dup = touch_frame(seq, t_us(), [(0, PHASE_MOVED, 0.5, 0.5, 8.0)])
    sock.send(dup)
    seq += 1
    time.sleep(step)
    sock.send(dup)                                    # same seq again
    time.sleep(step)
    sock.send(touch_frame(seq - 30, t_us(), []))      # far in the past
    time.sleep(0.2)
    sock.send(touch_frame(seq, t_us(), []))
    seq += 1
    time.sleep(0.2)
    drain()

    # 4. A tap: down and up inside 250 ms with almost no travel.
    print("… tapping (cursor should click where it stands)")
    sock.send(touch_frame(seq, t_us(), [(1, PHASE_BEGAN, 0.5, 0.5, 8.0)]))
    seq += 1
    time.sleep(0.05)
    sock.send(touch_frame(seq, t_us(), []))
    seq += 1
    time.sleep(0.3)
    drain()

    time.sleep(0.1)
    stop.set()
    samples = sorted(rtts)
    if samples:
        p50 = samples[len(samples) // 2]
        p95 = samples[min(len(samples) - 1, int(len(samples) * 0.95))]
        print(f"\nechoes {len(samples)}   RTT p50 {p50:.2f} ms   p95 {p95:.2f} ms   max {samples[-1]:.2f} ms")
        print("(loopback only — this is the receiver's own turnaround, not the Wi-Fi hop)")
    else:
        print("\nno echoes came back — receiver not running, or wrong host")


if __name__ == "__main__":
    main()
