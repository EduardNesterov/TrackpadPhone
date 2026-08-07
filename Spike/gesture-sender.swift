// Posts private gesture events (CGEventType 29) and watches whether they survive.
//
// ⚠️  THIS CRASHES THE WINDOWSERVER. Measured on macOS 26, 2026-08-07: one posted event
// is enough. It reaches `-[WSGestureEventProcessor annotate_internal:…]`, which fails an
// assertion and calls abort, and the whole graphical session restarts — every app closes,
// which from the user's chair is indistinguishable from a reboot. Crash report:
// /Library/Logs/DiagnosticReports/WindowServer-2026-08-07-183042.ips.
//
// Kept as the evidence, not as a tool. Do not run it on a machine anyone is using.
//
// There is no public way to synthesise a pinch: `CGEventType` has no gesture case and
// `CGEventField` has no gesture fields, so both are reached by bit-casting raw numbers.
// The numbers themselves are folklore — every project that does this carries the same
// reverse-engineered table — so rather than trust it, this sweeps the gesture-type field
// and lets the listener say which value, if any, macOS 26 turns into a real magnify.
//
// A listening tap runs alongside so that "nothing happened" can be split into "the event
// never left" and "the event left and was dropped on the way".
//
//   swiftc -O Spike/gesture-sender.swift -o /tmp/gesture-sender
//   /tmp/gesture-sender sweep <x> <y>        # try every gesture type in turn
//   /tmp/gesture-sender one <type> <x> <y>   # one type, a full began/changed/ended pinch

import CoreGraphics
import Foundation

func log(_ message: String) {
    let now = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000)
    print(String(format: "%9.3f  %@", now, message))
    fflush(stdout)
}

/// `CGEventType` and `CGEventField` are C enums imported as Swift enums, so unknown raw
/// values are unrepresentable through their initialisers. Same layout, so a bit-cast is
/// the only way to name a constant Apple did not publish.
func eventType(_ raw: UInt32) -> CGEventType { unsafeBitCast(raw, to: CGEventType.self) }
func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }

let kCGEventGesture: UInt32 = 29
/// Field numbers as carried by every project that has done this.
let gestureTypeField = field(110)
let gestureValueField = field(113)
let gesturePhaseField = field(132)

func post(gestureType: Int64, phase: Int64, value: Double, at point: CGPoint) {
    guard let event = CGEvent(source: nil) else {
        log("could not create an event at all")
        return
    }
    event.type = eventType(kCGEventGesture)
    event.location = point
    event.setIntegerValueField(gestureTypeField, value: gestureType)
    event.setIntegerValueField(gesturePhaseField, value: phase)
    event.setDoubleValueField(gestureValueField, value: value)
    event.post(tap: .cghidEventTap)
}

/// A whole pinch, the shape a real one has: open, a few steps of magnification, close.
func pinch(gestureType: Int64, at point: CGPoint) {
    post(gestureType: gestureType, phase: 1, value: 0, at: point)
    for _ in 0 ..< 5 {
        post(gestureType: gestureType, phase: 2, value: 0.08, at: point)
        usleep(16_000)
    }
    post(gestureType: gestureType, phase: 4, value: 0, at: point)
}

// MARK: - Listening tap

/// Counts our own events coming back out of the stream. Written as a global because an
/// event-tap callback is a bare C function pointer and cannot capture anything.
nonisolated(unsafe) var seenGestureEvents = 0

func startListeningTap() {
    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type.rawValue == kCGEventGesture {
            seenGestureEvents += 1
            let subtype = event.getIntegerValueField(field(110))
            log("TAP saw a gesture event, type field = \(subtype)")
        }
        return Unmanaged.passUnretained(event)
    }

    // Listen-only: the mask covers everything, because a gesture event's own bit is not
    // one of the named ones and guessing it wrong would look exactly like silence.
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask.max,
        callback: callback,
        userInfo: nil
    ) else {
        log("no event tap — Accessibility permission is missing")
        return
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("listening tap installed")
}

// MARK: - Main

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "sweep"

startListeningTap()
// Let the tap settle before anything is posted, or the first events race it.
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

switch mode {
case "one":
    let type = Int64(arguments[2]) ?? 8
    let point = CGPoint(x: Double(arguments[3]) ?? 500, y: Double(arguments[4]) ?? 400)
    log("posting gesture type \(type) at \(Int(point.x)),\(Int(point.y))")
    pinch(gestureType: type, at: point)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

default:
    let point = CGPoint(x: Double(arguments[2]) ?? 500, y: Double(arguments[3]) ?? 400)
    let range: ClosedRange<Int64> = 0 ... 64
    log("sweeping gesture types \(range.lowerBound)…\(range.upperBound) at \(Int(point.x)),\(Int(point.y))")
    for type in range {
        log("--> type \(type)")
        pinch(gestureType: type, at: point)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
}

log("done. gesture events seen in the stream: \(seenGestureEvents)")
