import AppKit
import CoreGraphics
import Foundation
import TrackpadInput

/// Turns recognised gestures into system input events.
///
/// This is the only file that knows about CoreGraphics — everything upstream deals in
/// millimetres and intent, which is what keeps the gesture layer testable.
public final class EventSynthesizer {
    public var acceleration = AccelerationCurve()
    /// Set from the system's own "natural scrolling" preference so scrolling agrees with
    /// whatever mouse or trackpad the user already has.
    public var naturalScrolling = true
    /// Cursor points per millimetre of finger travel while scrolling. Held separately
    /// from the config it starts from, so a slider can move it while the receiver runs.
    public var scrollGain: Double

    let source = CGEventSource(stateID: .hidSystemState)
    private let queue: DispatchQueue
    private let config: GestureConfig

    private var position: CGPoint
    private let bounds: CGRect
    /// Sub-point remainder. Without it, slow movement rounds to zero every frame and the
    /// cursor refuses to budge — the classic symptom of injected pointer input.
    private var residual = CGPoint.zero
    /// The same sub-point remainder, kept separately for scrolling. Truncating each
    /// frame's delta without it threw away the fraction every time: at a typical 0.2 mm
    /// per frame that is over a third of the travel, and slow scrolling produced literally
    /// nothing because every frame rounded to zero.
    private var scrollResidual = CGPoint.zero

    private var isDragging = false
    private var momentum = MomentumEngine()
    private var momentumTimer: DispatchSourceTimer?
    private var momentumRunning = false

    public init(queue: DispatchQueue, config: GestureConfig) {
        self.queue = queue
        self.config = config
        scrollGain = config.scrollGain
        bounds = EventSynthesizer.desktopBounds()
        position = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        naturalScrolling = EventSynthesizer.systemNaturalScrolling()
    }

    // MARK: - Entry point

    public func apply(_ event: InputEvent) {
        switch event {
        case .move(let dx, let dy, let speed):
            cancelMomentum()
            move(dxMM: dx, dyMM: dy, speedMMPerS: speed)

        case .click(let button, let count):
            cancelMomentum()
            click(button, count: count)

        case .dragBegan:
            cancelMomentum()
            isDragging = true
            post(.leftMouseDown, clickState: 1)

        case .dragEnded:
            releaseDrag()

        case .scroll(let dx, let dy, let phase):
            scroll(dxMM: dx, dyMM: dy, phase: phase)

        case .zoom(let steps):
            cancelMomentum()
            zoom(steps: steps)

        case .shortcut(let shortcut):
            // Stop any coasting scroll first. While the system believes a scroll gesture
            // is still running it can swallow a symbolic hotkey outright, and reaching a
            // three-finger swipe by adding a finger to a scroll is the normal path here.
            cancelMomentum()
            press(shortcut)
        }
    }

    // MARK: - Pointer

    private func move(dxMM: Double, dyMM: Double, speedMMPerS: Double) {
        let gain = acceleration.pointsPerMillimetre(speedMMPerS: speedMMPerS)

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

    /// Lets go of the mouse button if a drag is still open.
    ///
    /// The three-finger drag deliberately outlives the fingers leaving the surface, so that
    /// a hand can re-grab and carry on. That is right while the phone is there and a trap
    /// when it stops being there: an app backgrounded or a Wi-Fi drop mid-drag would leave
    /// the button held down with nothing left to release it. Guarding on `isDragging` also
    /// keeps a late `dragEnded` from ending a drag the user started with a real mouse.
    ///
    /// - Returns: true if a drag was actually released.
    @discardableResult
    public func releaseDrag() -> Bool {
        guard isDragging else { return false }
        isDragging = false
        post(.leftMouseUp, clickState: 1)
        return true
    }

    /// Re-read the real cursor position, so we don't fight a mouse the user just moved.
    public func resync() {
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

    /// Time constant for evening out scroll delivery. Frames cross Wi-Fi with measured
    /// jitter of 13.8 ms at the 95th percentile on packets sent every 10 ms, so they arrive
    /// in clumps and then not at all — and posted as they land, that clumping is what the
    /// eye reads as a rough scroll. Draining a bucket instead spreads each clump over the
    /// gap that follows it. The cost is this much delay, which is far less noticeable on a
    /// scrolling page than on a pointer, and the reason the pointer keeps none of it.
    private static let scrollSmoothing = 0.012

    private var pendingScroll = CGPoint.zero
    private var scrollActive = false

    private func scroll(dxMM: Double, dyMM: Double, phase: ScrollPhase) {
        switch phase {
        case .began:
            cancelMomentum()
            scrollResidual = .zero
            pendingScroll = .zero
            scrollActive = true
            // Posted straight through: the start of a gesture is the one moment where
            // delay would be felt as the page refusing to move.
            postScroll(dxMM: dxMM, dyMM: dyMM, scrollPhase: 1, momentumPhase: 0)
        case .changed:
            pendingScroll.x += dxMM
            pendingScroll.y += dyMM
        case .ended(let velocityX, let velocityY):
            flushPendingScroll()
            scrollActive = false
            postScroll(dxMM: 0, dyMM: 0, scrollPhase: 4, momentumPhase: 0)
            if velocityX != 0 || velocityY != 0 {
                startMomentum(velocityX: velocityX, velocityY: velocityY)
            }
        }
    }

    /// Lets the accumulated scroll out at an even rate. Driven by the receiver's tick.
    public func tick(elapsed: Double) {
        guard scrollActive, elapsed > 0 else { return }
        let share = 1 - exp(-elapsed / Self.scrollSmoothing)
        let step = CGPoint(x: pendingScroll.x * share, y: pendingScroll.y * share)
        guard step.x != 0 || step.y != 0 else { return }
        pendingScroll.x -= step.x
        pendingScroll.y -= step.y
        // Fractions of a millimetre are normal here and are not lost: `postScroll` keeps
        // the sub-point remainder.
        postScroll(dxMM: step.x, dyMM: step.y, scrollPhase: 2, momentumPhase: 0)
    }

    private func flushPendingScroll() {
        guard pendingScroll.x != 0 || pendingScroll.y != 0 else { return }
        postScroll(dxMM: pendingScroll.x, dyMM: pendingScroll.y, scrollPhase: 2, momentumPhase: 0)
        pendingScroll = .zero
    }

    /// - Parameters:
    ///   - scrollPhase: 1 began, 2 changed, 4 ended, 0 during momentum.
    ///   - momentumPhase: 0 none, 1 begin, 2 continue, 3 end.
    private func postScroll(dxMM: Double, dyMM: Double, scrollPhase: Int64, momentumPhase: Int64) {
        // Sign convention: dy > 0 means the fingers moved down the surface. With natural
        // scrolling the content follows the fingers, which is a positive wheel delta.
        let direction: Double = naturalScrolling ? 1 : -1
        let wantY = dyMM * scrollGain * direction + scrollResidual.y
        let wantX = dxMM * scrollGain * direction + scrollResidual.x
        let deltaY = wantY.rounded(.towardZero)
        let deltaX = wantX.rounded(.towardZero)
        scrollResidual = CGPoint(x: wantX - deltaX, y: wantY - deltaY)

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
        // Flagging the event is correct here, unlike in `press` below: applications read
        // the modifier off the scroll event itself, and a scroll event carries no key
        // state for the system to disagree with. Pressing ⌘ for real would also have to
        // be held across the whole pinch, which this API shape cannot express.
        event.flags = .maskCommand
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private static let controlKey: CGKeyCode = 59

    /// Ways of expressing "hold Control" to the system. Which one a symbolic hotkey
    /// actually honours is not documented anywhere reliable, so the app can fire all
    /// three and record which one worked instead of anyone guessing.
    public enum ModifierStyle: String, CaseIterable, Sendable {
        /// Flag on the arrow event only — no modifier keystroke at all.
        case flagsOnly
        /// Control sent as an ordinary key down/up around the arrow.
        case modifierKey
        /// Control sent as a flagsChanged event, which is what real hardware produces.
        case flagsChanged
    }

    /// Sends ⌃↑ using a named strategy. Exposed for the diagnostic probe.
    public func sendMissionControl(style: ModifierStyle, tap: CGEventTapLocation = .cghidEventTap) {
        pressWithKeys(126, style: style, tap: tap)
    }

    /// Sends ⌃← through the plain key path, bypassing the Mission Control special case,
    /// so the probe can measure what happens to a synthesised keystroke.
    public func sendSpaceLeft(style: ModifierStyle, tap: CGEventTapLocation = .cghidEventTap) {
        pressWithKeys(123, style: style, tap: tap)
    }

    /// Sends an ordinary application shortcut (⌘ + key), as opposed to a system-wide
    /// symbolic hotkey. Whether these survive synthesis is a separate question, and the
    /// answer decides what the remaining gestures can usefully be mapped to.
    public func sendCommandKey(_ key: CGKeyCode) {
        postModifier(down: true, tap: .cghidEventTap, flags: .maskCommand)
        postKey(key, down: true, flags: .maskCommand)
        postKey(key, down: false, flags: .maskCommand)
        postModifier(down: false, tap: .cghidEventTap, flags: .maskCommand)
    }

    public func sendEscape() {
        postKey(53, down: true, flags: [])
        postKey(53, down: false, flags: [])
    }

    /// Sends a real ⌃-modified keystroke.
    ///
    /// Setting `flags = .maskControl` on the arrow event alone is not enough, and this
    /// cost two visible bugs. Mission Control and space switching are symbolic hotkeys
    /// handled by the WindowServer, which matches on the *actual* modifier state rather
    /// than on a flag decorating some other event — so the gesture fired, the event went
    /// out, and nothing happened.
    ///
    /// Worse, a flagged event with no matching modifier keystroke leaves the session's
    /// modifier state inconsistent, and later mouse events created from this source
    /// inherit the phantom Control. On macOS Control-click *is* right-click, so every
    /// subsequent tap turned into a context menu.
    ///
    /// Pressing and releasing the modifier for real fixes both.
    private func press(_ shortcut: Shortcut, style: ModifierStyle? = nil, tap: CGEventTapLocation = .cghidEventTap) {
        switch shortcut {
        case .missionControl:
            // Measured on macOS 26, not assumed: ⌃↑ was fired five ways — flag-only,
            // modifier-as-key and modifier-as-flagsChanged, at both the HID and session
            // taps — and moved nothing, while a listen-only tap confirmed every event
            // reached the stream carrying maskControl. Symbolic hotkeys are refused by
            // policy. Launching the application is the supported route and works.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))

        case .navigateBack:
            sendCommandKey(33)   // ⌘[
        case .navigateForward:
            sendCommandKey(30)   // ⌘]
        }
    }

    /// Kept for the diagnostic probe: fires ⌃← through the plain key path so the
    /// experiment above can be repeated if a future macOS changes the rules.
    private func pressWithKeys(_ key: CGKeyCode, style: ModifierStyle, tap: CGEventTapLocation) {
        switch style {
        case .flagsOnly:
            postKey(key, down: true, flags: .maskControl, tap: tap)
            postKey(key, down: false, flags: .maskControl, tap: tap)

        case .modifierKey:
            postKey(Self.controlKey, down: true, flags: .maskControl, tap: tap)
            postKey(key, down: true, flags: .maskControl, tap: tap)
            postKey(key, down: false, flags: .maskControl, tap: tap)
            postKey(Self.controlKey, down: false, flags: [], tap: tap)

        case .flagsChanged:
            // Real hardware reports a modifier as a flagsChanged event, not a key press.
            postModifier(down: true, tap: tap)
            postKey(key, down: true, flags: .maskControl, tap: tap)
            postKey(key, down: false, flags: .maskControl, tap: tap)
            postModifier(down: false, tap: tap)
        }
    }

    private func postModifier(down: Bool, tap: CGEventTapLocation = .cghidEventTap, flags: CGEventFlags = .maskControl) {
        let code: CGKeyCode = flags == .maskCommand ? 55 : Self.controlKey
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? flags : []
        event.post(tap: tap)
        usleep(15_000)
    }

    private func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, tap: CGEventTapLocation = .cghidEventTap) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: tap)
        // The WindowServer processes the modifier change asynchronously, and a hotkey
        // arriving in the same instant can be evaluated before Control is seen as down.
        // 15 ms is well inside human reaction time for something that fires once per
        // gesture, and far more forgiving than the 2 ms this started at.
        usleep(15_000)
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

    public static func systemNaturalScrolling() -> Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return global?["com.apple.swipescrolldirection"] as? Bool ?? true
    }
}
