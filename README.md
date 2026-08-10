# TrackpadPhone

**An iPhone as a trackpad and keyboard for a Mac.** Local, encrypted, no account, no cloud —
the two devices talk directly over your own Wi-Fi and nothing else is involved.

A Mac mini ships without a pointing device. This turns the phone already sitting on the desk
into one that feels like Apple's own: velocity-dependent acceleration, scroll with inertia,
two-finger pinch, three-finger drag that keeps travelling when you run out of glass, and an
on-screen keyboard with word completion in three languages.

```
   iPhone (dumb sensor)                       Mac (everything else)
 ┌──────────────────────┐                   ┌──────────────────────────┐
 │ raw touches, 120 Hz  │   sealed UDP      │ gesture recognition      │
 │ no interpretation  ──┼──────────────────▶│ acceleration & inertia   │
 │ 50-byte snapshots    │   Bonjour, LAN    │ CGEvent synthesis        │
 └──────────────────────┘                   └──────────────────────────┘
```

---

## What it does

| Fingers | Gesture | Result |
|---|---|---|
| 1 | move | pointer, with a velocity-dependent gain curve |
| 1 | tap | click · double-click · tap-and-a-half to drag |
| 2 | tap | right click |
| 2 | slide | scroll, with rubber-banding and inertia |
| 2 | pinch | zoom, with inertia of its own |
| 3 | move | drag: button down, carry, and an edge push when the surface runs out |
| 4 | swipe | Mission Control · back · forward |

Plus a keyboard drawn from scratch — EN / UK / RU layouts, Mac modifier keys, word
completion from the system dictionaries, and press-and-hold delete that escalates to whole
words. And haptics: the Mac is the only side that knows a click landed, so it tells the
phone when to buzz.

Everything is tunable from the Mac's menu bar while it runs — pointer speed, scroll speed,
zoom speed, edge autoscroll — because tuning by feel is impossible if every change costs a
rebuild.

## The one architectural decision

**The phone is a dumb sensor. It sends raw touches and interprets nothing.**

Not for purity. Tuning how a trackpad *feels* is ninety per cent of the work, and on the Mac
that loop is a five-second rebuild instead of a reinstall to a device. It also means the
recognition layer touches no platform API at all, so a recorded finger stream replays
identically in a test — which is how 115 tests can cover behaviour that is otherwise only
reachable with a hand.

Three modules:

| | |
|---|---|
| `TrackpadProtocol` | wire format, pairing code, encrypted channel. Shared by both ends. |
| `TrackpadInput` | gesture recognition, acceleration, inertia. **No platform calls, fully tested.** |
| `TrackpadMac` | the only place that knows about CoreGraphics. |

## The protocol

UDP, because a lost touch sample is worth less than a late one. Every frame is a **snapshot,
not a delta** — a dropped "finger lifted" would otherwise stick a mouse button down forever.
A five-finger frame is 50 bytes, so frames never fragment.

```
common      u8 version, u8 type
touchFrame  + u16 seq, u32 tSensorUs, u8 count, u8 flags, count × contact
contact     u8 id, u8 phase, i16 x, i16 y, u16 majorRadius   (8 bytes)
hello       + u32 sessionID, f32 widthMM, f32 heightMM, u8 maxContacts
keyInput    + u16 keyCode, u8 modifiers, u8 textLength, textLength × u8 (UTF-8)
feedback    + u8 kind, u8 intensity
alive       — header only
```

Coordinates are fixed-point `i16` scaled by 2¹⁴, which leaves headroom past the edges: a
finger can legitimately report outside 0…1, and full-scale would clip it back to the border.

Reliability is selective rather than uniform. Ordinary movement is disposable — the next
frame is 8 ms away. The frames where the **contact count changes** are not, so those are sent
three times; a duplicate costs 50 bytes and a missed touch-down costs the gesture. Sequence
numbers use circular comparison, or the wrap from 65535 to 0 would stall the stream for 32k
frames.

Everything is measured in **millimetres**, not pixels or points. The phone reports its own
surface size in `hello`; thresholds on the Mac are therefore the same physical distance on
every device and in either orientation.

## Security

The receiver turns packets into keystrokes and clicks on the desktop. An open UDP port is
therefore a keyboard handed to anyone on the network — which is exactly what this was until
pairing landed.

- **Pairing by QR.** The Mac shows a code, the phone's camera reads it. A 32-byte secret goes
  to the Keychain on both ends; nothing is typed, and no address is ever entered.
- **ChaCha20-Poly1305** on every packet, from CryptoKit on both platforms.
- **Separate keys per direction**, derived with HKDF. The two directions share a nonce space
  otherwise, and a repeated nonce under this construction does not degrade politely — it
  hands out the keystream.
- **A random 8-byte session salt** in the key derivation, carried in every packet. Counters
  restart at zero on every launch, so without it two launches would repeat their nonces.
- **A 64-packet replay window**, not "counters must increase": UDP reorders, and the
  deliberate duplicate frames above are exactly the traffic a strict rule would throw away.
- The salt is adopted **only after the tag verifies** — otherwise eight random bytes from
  anyone would reset the replay window, and a reset window accepts replays.

Discovery is Bonjour (`_trackpadphone._udp`), so a paired phone finds the Mac again after the
router hands out new addresses. The addresses in the QR are a fallback for networks that
filter mDNS.

## The parts that took the work

**Acceleration is a curve, not a formula.** Piecewise-linear over seven knots, sub-unity at
the bottom — libinput decelerates to 0.3× down there, and that damped zone is precisely what
makes a single pixel reachable. A `base + k · speed` line cannot express it.

**The speed the curve is read at** runs over a trailing window that collapses on a direction
reversal or a sudden change of pace, because otherwise the gain built up going right is still
in the estimate when the finger starts going left.

**Inertia** is generated here, because macOS produces it below the layer injected events
enter. Scroll and zoom both coast, and both decide whether to coast from the last few tens of
milliseconds: a hand that had already stopped was placing the view exactly where it is.

**The edge push.** A phone is 140 mm across; a window crossing a desktop needs several times
that. So a three-finger drag pressed against a border keeps travelling — and *accelerates*
the longer you hold, because nudging an icon into place and carrying a window across a screen
are the same gesture with different amounts of patience behind them. The pointer is pushed
rather than the view scrolled: an application tracking a mouse drag runs its own event loop
that takes only dragged and up events, so a synthesised wheel event would sit in the queue
until the drag was over.

**The drag survives the hand leaving.** Fingers lift and land again, and the button stays
down in between — which is what makes 140 mm of glass enough to cross a desktop.

## Measured, not assumed

The interesting failures in this project were all things that looked like one component and
turned out to be another. Each of these is in the commit history with the numbers.

- **A synthesised gesture event crashes WindowServer.** `CGEventType` 29 — the private path
  to a real pinch — posts successfully, and a listening tap sees it with its fields intact.
  Inside WindowServer it reaches an assertion and aborts, taking the entire graphics session
  with it. One event is enough. So zoom is ⌘+scroll, and the real path would be a DriverKit
  virtual multitouch driver.
- **Symbolic hotkeys refuse synthesised input.** ⌃↑ was fired five ways — flag on the event,
  modifier as a key, modifier as `flagsChanged`, at both the HID and session taps — and moved
  nothing, while a listening tap confirmed every event arrived carrying `maskControl`.
  Mission Control is therefore launched as an application.
- **A modifier must be pressed for real.** A flag on an event with no matching keystroke
  leaves the session's modifier state inconsistent, and the *next* event inherits a phantom
  modifier. Measured: it appears ~20 ms after a flagged scroll and persists.
- **Peer-to-peer Wi-Fi makes the pointer stutter.** Advertising over Bonjour with
  `includePeerToPeer` makes the Mac an active AWDL participant, and an active participant
  time-shares the radio. Nothing is lost — frames queue while the chip is off-channel and
  arrive in a burst — but the pointer freezes for the absence. The phone's own clock showed
  gaps of at most 25 ms while the Mac saw 90–100 ms, once or twice a second.
- **The recogniser's clock stopped when nobody was touching.** An empty surface sends no
  frames, so windows that expire *between* gestures never expired: a click left the tap-drag
  armed and the next touch to move pressed the button instead of pointing — 77 seconds later,
  in the log that caught it.
- **A gap in the frame stream is usually a resting finger.** iOS sends no `touchesMoved` for a
  stationary touch. Of 36 apparent stalls inside a stroke, 35 were a finger that had simply
  stopped. The instrument that settles it is a pair of numbers: inter-arrival gaps beside the
  same gaps as the phone's own clock recorded them.

## Built with

Swift 6 · SwiftUI · UIKit touch handling · Network.framework (UDP, Bonjour) · CryptoKit ·
CoreGraphics event synthesis · AVFoundation · Core Haptics · `UITextChecker` · Swift Testing

**115 tests**, over synthesised finger streams — including the untidy ones: fingers that lift
one at a time, a pinch with the thumb anchored, a hand that lingers on the way off. Idealised
tests hid three real bugs in this project before that lesson stuck.

## Running it

Requires a Mac (macOS 14+), an iPhone (iOS 17+), and Xcode. Both halves build from the
command line:

```sh
./scripts/build-mac-app.sh && open dist/TrackpadPhone.app   # the Mac half
./scripts/install-phone.sh                                  # the phone half
```

The install script works out which Apple developer team owns the machine it is running on and
builds under it, so nothing has to be edited by hand. Full walkthrough, including pairing and
the things Apple makes you click once:
**[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md)**.

```sh
swift test --package-path TrackpadKit
```

## Limitations, honestly

- **A free Apple ID gives you seven days** before the app stops launching. Re-running the
  install script fixes it and loses nothing — the pairing lives in the Keychain, not the app.
- **No true pinch or rotate.** See the WindowServer note above; ⌘+scroll is the closest public
  stand-in, and it works wherever the application reads that as zoom.
- **No space switching or App Exposé.** Symbolic hotkeys, and the system refuses them.
- **Accept-only-paired starts off.** On a machine whose only pointer is this app, a rule that
  refuses an unpaired phone before you have seen a paired one work could leave you unable to
  click the menu item that undoes it. Turn it on once it is working.
- **Peer-to-peer (no-router) operation is off** for the reason in the AWDL note.

## Notes in other languages

Working notes and the architecture document were written in Russian and Ukrainian as the
project went; they are kept as they are rather than translated into something thinner:
[`docs/README.ru.md`](docs/README.ru.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
[`CLAUDE.md`](CLAUDE.md). The commit history is the real record of why things are the way
they are.

## License

MIT.
