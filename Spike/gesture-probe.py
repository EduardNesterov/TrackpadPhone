#!/usr/bin/env python3
"""Sends specific gestures at the Mac receiver so its --debug output can be read back.

Where fake-phone.py checks that packets survive the wire, this one checks that a gesture
means what it should. Run the receiver with --debug next to it.

    python3 gesture-probe.py 127.0.0.1 51890
"""

import socket
import struct
import sys
import time

VERSION = 1
T_TOUCH_FRAME = 0x01
T_HELLO = 0x02
COORD_SCALE = 16384
SURFACE_W_MM = 144.8   # landscape iPhone, matching what the app reports
SURFACE_H_MM = 66.6

PHASE_BEGAN, PHASE_MOVED = 0, 1
HZ = 120


class Probe:
    def __init__(self, host, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.connect((host, port))
        self.seq = 0
        self.start = time.monotonic()
        self.fingers = {}
        self.seen = set()
        self.last_count = 0
        for _ in range(3):
            self.sock.send(struct.pack(
                "<BBIffB", VERSION, T_HELLO,
                int(time.time()) & 0xFFFFFFFF, SURFACE_W_MM, SURFACE_H_MM, 5
            ))
            time.sleep(0.01)

    def _t_us(self):
        return int((time.monotonic() - self.start) * 1e6) & 0xFFFFFFFF

    def _emit(self):
        contacts = []
        for cid, (x, y) in sorted(self.fingers.items()):
            phase = PHASE_MOVED if cid in self.seen else PHASE_BEGAN
            self.seen.add(cid)
            contacts.append((cid, phase, x / SURFACE_W_MM, y / SURFACE_H_MM))

        payload = struct.pack("<BBHIBB", VERSION, T_TOUCH_FRAME, self.seq,
                              self._t_us(), len(contacts), 0)
        for cid, phase, nx, ny in contacts:
            payload += struct.pack("<BBhhH", cid, phase,
                                   round(nx * COORD_SCALE), round(ny * COORD_SCALE), 2048)
        self.sock.send(payload)
        self.seq = (self.seq + 1) & 0xFFFF

        # The phone repeats frames where the contact count changed; mirror that so the
        # receiver sees exactly the traffic it sees in real use.
        if len(contacts) != self.last_count:
            self.last_count = len(contacts)

    def place(self, cid, x, y):
        self.fingers[cid] = (x, y)

    def hold(self, seconds):
        for _ in range(max(1, int(seconds * HZ))):
            self._emit()
            time.sleep(1 / HZ)

    def move_all(self, dx, dy, seconds):
        steps = max(1, int(seconds * HZ))
        start = dict(self.fingers)
        for step in range(1, steps + 1):
            f = step / steps
            for cid, (x, y) in start.items():
                self.fingers[cid] = (x + dx * f, y + dy * f)
            self._emit()
            time.sleep(1 / HZ)

    def lift_all(self):
        self.fingers.clear()
        self.seen.clear()
        self._emit()
        time.sleep(0.05)


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 51888
    p = Probe(host, port)

    print("\n--- single-finger tap (expect: click(left, 1)) ---")
    p.place(0, 70, 33)
    p.hold(0.06)
    p.lift_all()
    time.sleep(0.6)

    print("\n--- two-finger tap (expect: click(right, 1)) ---")
    p.place(0, 60, 33)
    p.place(1, 84, 33)
    p.hold(0.06)
    p.lift_all()
    time.sleep(0.6)

    print("\n--- three fingers landing one at a time, swipe up (expect: missionControl) ---")
    p.place(0, 50, 40)
    p.hold(0.03)
    p.place(1, 70, 40)
    p.hold(0.03)
    p.place(2, 90, 40)
    p.hold(0.03)
    p.move_all(0, -22, 0.25)
    p.lift_all()
    time.sleep(0.6)

    print("\n--- three fingers swipe left (expect: spaceLeft) ---")
    p.place(0, 70, 33)
    p.place(1, 90, 33)
    p.place(2, 110, 33)
    p.hold(0.04)
    p.move_all(-40, 0, 0.25)
    p.lift_all()
    time.sleep(0.4)


if __name__ == "__main__":
    main()
