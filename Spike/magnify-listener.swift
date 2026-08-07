// Oracle for the "can we synthesise a real pinch" question.
//
// Opens a window and reports every gesture event that reaches it, two ways at once:
//
//   * view overrides — the event was delivered to a window as a genuine AppKit gesture,
//     which is exactly what Preview, Photos and Xcode read;
//   * a global monitor — the event existed at the NSEvent layer at all, even if it was
//     routed somewhere else.
//
// The two together separate "the event never got past the WindowServer" from "it got
// through but went nowhere", and those need completely different answers.
//
//   swiftc -O Spike/magnify-listener.swift -o /tmp/magnify-listener

import AppKit

func log(_ message: String) {
    let now = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000)
    print(String(format: "%9.3f  %@", now, message))
    fflush(stdout)
}

final class GestureView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func magnify(with event: NSEvent) {
        log("VIEW magnify  magnification=\(event.magnification)  phase=\(event.phase.rawValue)")
    }

    override func rotate(with event: NSEvent) {
        log("VIEW rotate  \(event.rotation)")
    }

    override func swipe(with event: NSEvent) {
        log("VIEW swipe  dx=\(event.deltaX) dy=\(event.deltaY)")
    }

    override func smartMagnify(with event: NSEvent) {
        log("VIEW smartMagnify")
    }

    override func scrollWheel(with event: NSEvent) {
        log("VIEW scroll  dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue)")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemTeal.setFill()
        dirtyRect.fill()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 200, y: 200, width: 600, height: 400)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "magnify listener"
        window.contentView = GestureView(frame: frame)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Screen coordinates are bottom-left origin; CGEvent uses top-left. Report the
        // centre in CGEvent's space so the sender can aim at it without converting.
        let screen = window.screen ?? NSScreen.main!
        let centre = CGPoint(
            x: window.frame.midX,
            y: screen.frame.height - window.frame.midY
        )
        log("READY  window centre in CGEvent space: \(Int(centre.x)) \(Int(centre.y))")

        NSEvent.addGlobalMonitorForEvents(
            matching: [.magnify, .rotate, .swipe, .smartMagnify, .beginGesture, .endGesture]
        ) { event in
            log("GLOBAL \(event.type.rawValue)  subtype=\(event.cgEvent?.getIntegerValueField(unsafeBitCast(UInt32(110), to: CGEventField.self)) ?? -1)")
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
