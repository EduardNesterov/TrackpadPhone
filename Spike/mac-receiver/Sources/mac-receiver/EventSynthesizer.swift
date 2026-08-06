import CoreGraphics
import Foundation
import TrackpadInput

/// Turns recognised gestures into system input events.
///
/// This is the only file that knows about CoreGraphics — everything upstream deals in
/// millimetres and intent, which is what keeps the gesture layer testable.
final class EventSynthesizer {
    var acceleration = AccelerationCurve()
    /// Set from the system's own "natural scrolling" preference so scrolling agrees with
    /// whatever mouse or trackpad the user already has.
    var naturalScrolling = true

    private let source = CGEventSource(stateID: .hidSystemState)
    private let queue: DispatchQueue
    private let config: GestureConfig

    private var position: CGPoint
    private let bounds: CGRect
    /// Sub-point remainder. Without it, slow movement rounds to zero every frame and the
    /// cursor refuses to budge — the classic symptom of injected pointer input.
    private var residual = CGPoint.zero

    private var isDragging = false
    private var momentum = MomentumEngine()
    private var momentumTimer: DispatchSourceTimer?
    private var momentumRunning = false

    init(queue: DispatchQueue, config: GestureConfig) {
        self.queue = queue
        self.config = config
        bounds = EventSynthesizer.desktopBounds()
        position = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        naturalScrolling = EventSynthesizer.systemNaturalScrolling()
    }

    // MARK: - Entry point

    func apply(_ event: InputEvent) {
        switch event {
        case .move(let dx, let dy, let dt):
            cancelMomentum()
            move(dxMM: dx, dyMM: dy, dt: dt)

        case .click(let button, let count):
            cancelMomentum()
            click(button, count: count)

        case .dragBegan:
            cancelMomentum()
            isDragging = true
            post(.leftMouseDown, clickState: 1)

        case .dragEnded:
            isDragging = false
            post(.leftMouseUp, clickState: 1)

        case .scroll(let dx, let dy, let phase):
            scroll(dxMM: dx, dyMM: dy, phase: phase)

        case .zoom(let steps):
            zoom(steps: steps)

        case .shortcut(let shortcut):
            press(shortcut)
        }
    }

    // MARK: - Pointer

    private func move(dxMM: Double, dyMM: Double, dt: Double) {
        let distance = (dxMM * dxMM + dyMM * dyMM).squareRoot()
        let speed = dt > 0 ? distance / dt : 0
        let gain = acceleration.gain(speedMMPerS: speed)

        let wantX = dxMM * gain + residual.x
        let wantY = dyMM * gain + residual.y
        let stepX = wantX.rounded(.towardZero)
        let stepY = wantY.rounded(.towardZero)
        residual = CGPoint(x: wantX - stepX, y: wantY - stepY)

        guard stepX != 0 || stepY != 0 else { return }

        position.x = min(max(position.x + stepX, bounds.minX), bounds.maxX - 1)
        position.y = min(max(position.y + stepY, bounds.minY), bounds.maxY - 1)

        post(isDragging ? .leftMouseDragged : .mouseMoved, deltaX: Int64(stepX), deltaY: Int64(stepY))
    }

    /// Re-read the real cursor position, so we don't fight a mouse the user just moved.
    func resync() {
        if let live = CGEvent(source: nil)?.location { position = live }
        residual = .zero
    }

    private func click(_ button: MouseButton, count: Int) {
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        // The click count has to ride on the event itself. Two plain clicks in a row are
        // not a double click to macOS, no matter how close together they are.
        post(down, clickState: Int64(count), button: button)
        post(up, clickState: Int64(count), button: button)
    }

    private func post(
        _ type: CGEventType,
        deltaX: Int64 = 0,
        deltaY: Int64 = 0,
        clickState: Int64 = 0,
        button: MouseButton = .left
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: button == .left ? .left : .right
        ) else { return }

        // Absolute position alone is not enough: games, Blender and Figma's pan read the
        // delta fields and see nothing without these.
        if deltaX != 0 || deltaY != 0 {
            event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        }
        if clickState != 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    private func scroll(dxMM: Double, dyMM: Double, phase: ScrollPhase) {
        switch phase {
        case .began:
            cancelMomentum()
            postScroll(dxMM: dxMM, dyMM: dyMM, scrollPhase: 1, momentumPhase: 0)
        case .changed:
            postScroll(dxMM: dxMM, dyMM: dyMM, scrollPhase: 2, momentumPhase: 0)
        case .ended(let velocityX, let velocityY):
            postScroll(dxMM: 0, dyMM: 0, scrollPhase: 4, momentumPhase: 0)
            if velocityX != 0 || velocityY != 0 {
                startMomentum(velocityX: velocityX, velocityY: velocityY)
            }
        }
    }

    /// - Parameters:
    ///   - scrollPhase: 1 began, 2 changed, 4 ended, 0 during momentum.
    ///   - momentumPhase: 0 none, 1 begin, 2 continue, 3 end.
    private func postScroll(dxMM: Double, dyMM: Double, scrollPhase: Int64, momentumPhase: Int64) {
        // Sign convention: dy > 0 means the fingers moved down the surface. With natural
        // scrolling the content follows the fingers, which is a positive wheel delta.
        let direction: Double = naturalScrolling ? 1 : -1
        let deltaY = dyMM * config.scrollGain * direction
        let deltaX = dxMM * config.scrollGain * direction

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(deltaY)),
            wheel2: Int32(clamping: Int(deltaX)),
            wheel3: 0
        ) else { return }

        // Without these fields AppKit treats the run as a discrete mouse wheel: no
        // rubber-band at the edges, no smooth deceleration, visible stepping.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Momentum

    private func startMomentum(velocityX: Double, velocityY: Double) {
        momentum.start(velocityX: velocityX, velocityY: velocityY)
        momentumRunning = true
        postScroll(dxMM: 0, dyMM: 0, scrollPhase: 0, momentumPhase: 1)

        let interval = 1.0 / 120.0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let step = self.momentum.tick(dt: interval) else {
                self.finishMomentum()
                return
            }
            self.postScroll(dxMM: step.dxMM, dyMM: step.dyMM, scrollPhase: 0, momentumPhase: 2)
        }
        timer.resume()
        momentumTimer = timer
    }

    private func finishMomentum() {
        guard momentumRunning else { return }
        momentumTimer?.cancel()
        momentumTimer = nil
        momentumRunning = false
        momentum.stop()
        postScroll(dxMM: 0, dyMM: 0, scrollPhase: 0, momentumPhase: 3)
    }

    /// Any new touch stops the coast — a real trackpad catches the page under your finger.
    private func cancelMomentum() {
        if momentumRunning { finishMomentum() }
    }

    // MARK: - Keyboard-mapped gestures

    private func zoom(steps: Int) {
        guard steps != 0 else { return }
        // ⌘ + scroll is the closest public stand-in for a pinch: Safari, Preview, Maps,
        // Figma and Photoshop all read it as zoom, and unlike ⌘+/− it is continuous.
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(clamping: steps * 20),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.flags = .maskCommand
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func press(_ shortcut: Shortcut) {
        let (key, flags): (CGKeyCode, CGEventFlags) = switch shortcut {
        case .missionControl: (126, .maskControl)      // ⌃↑
        case .applicationWindows: (125, .maskControl)  // ⌃↓
        case .spaceLeft: (123, .maskControl)           // ⌃←
        case .spaceRight: (124, .maskControl)          // ⌃→
        }

        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System

    /// Union of all active displays, in the top-left-origin space CGEvent uses.
    private static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return ids.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    private static func systemNaturalScrolling() -> Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return global?["com.apple.swipescrolldirection"] as? Bool ?? true
    }
}
