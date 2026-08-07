// Does a flag set on a posted event leak into the events created after it?
//
// The project already paid for this once with Control: a ⌃-flagged key event with no real
// keystroke left the session's modifier state inconsistent, and the next click inherited a
// phantom Control — which on macOS is a right click. The zoom path did the same with ⌘, and
// ⌘-click on a Dock icon reveals the item in Finder — which is the reported "clicking an
// app in the Dock opens the Applications folder instead".
//
// Repeats the experiment at several delays, because the leak turned out not to survive
// every gap: whatever posts next with clean flags puts the state back.
//
// Only ordinary scroll events are posted, one notch each, alternating direction so the
// experiment leaves whatever is under the pointer where it found it.
//
//   swiftc -O Spike/phantom-modifier.swift -o /tmp/phantom-modifier && /tmp/phantom-modifier

import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func commandOnAFreshMouseEvent() -> Bool? {
    guard let probe = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
        mouseButton: .left
    ) else { return nil }
    return probe.flags.contains(.maskCommand)
}

func postFlaggedScroll(_ notch: Int32) {
    guard let scroll = CGEvent(
        scrollWheelEvent2Source: source, units: .pixel,
        wheelCount: 1, wheel1: notch, wheel2: 0, wheel3: 0
    ) else { return }
    scroll.flags = .maskCommand
    scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    scroll.post(tap: .cghidEventTap)
}

print("=== flag on the event, no keystroke (what the zoom used to do) ===")
for delayMs in [0, 5, 20, 60, 150, 400] {
    postFlaggedScroll(delayMs % 2 == 0 ? 1 : -1)
    usleep(UInt32(delayMs) * 1000)
    let leaked = commandOnAFreshMouseEvent()
    print(String(format: "  +%4d ms   ⌘ on the next event: %@", delayMs,
                 leaked == true ? "YES — a click here is a ⌘-click" : "no"))
}

print("\n=== modifier pressed for real, then released (the fix) ===")
func modifier(down: Bool) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: down) else { return }
    event.type = .flagsChanged
    event.flags = down ? .maskCommand : []
    event.post(tap: .cghidEventTap)
    usleep(15_000)
}

for delayMs in [0, 5, 20, 60, 150, 400] {
    modifier(down: true)
    postFlaggedScroll(delayMs % 2 == 0 ? -1 : 1)
    modifier(down: false)
    usleep(UInt32(delayMs) * 1000)
    let leaked = commandOnAFreshMouseEvent()
    print(String(format: "  +%4d ms   ⌘ on the next event: %@", delayMs,
                 leaked == true ? "YES" : "no"))
}
