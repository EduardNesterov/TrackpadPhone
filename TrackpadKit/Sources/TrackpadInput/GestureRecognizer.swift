import Foundation
import TrackpadProtocol

/// Physical size of the touch surface. Everything the recogniser reasons about is in
/// millimetres, so thresholds hold across devices and orientations.
public struct SurfaceGeometry: Sendable, Equatable {
    public var widthMM: Double
    public var heightMM: Double

    public init(widthMM: Double, heightMM: Double) {
        self.widthMM = widthMM
        self.heightMM = heightMM
    }
}

struct Vec: Equatable {
    var x: Double = 0
    var y: Double = 0

    static func - (a: Vec, b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y) }
    static func / (a: Vec, d: Double) -> Vec { d == 0 ? .init() : Vec(x: a.x / d, y: a.y / d) }
    var length: Double { (x * x + y * y).squareRoot() }
}

/// Turns a stream of touch snapshots into pointer, scroll and gesture events.
///
/// This is the piece the architecture puts on the Mac rather than the phone: tuning it is
/// most of the project's work, and here it is a rebuild away instead of a reinstall away.
/// It touches no platform API, so a recorded finger stream replays identically in a test.
public final class GestureRecognizer {
    public var config: GestureConfig
    public var surface: SurfaceGeometry

    public init(config: GestureConfig = GestureConfig(),
                surface: SurfaceGeometry = SurfaceGeometry(widthMM: 70, heightMM: 150)) {
        self.config = config
        self.surface = surface
        pointerVelocity.maxAge = config.pointerVelocityWindow
        velocityTracker.window = config.flickWindow
        velocityTracker.restTimeout = config.flickRestTimeout
        velocityTracker.minimumTravelMM = config.flickMinimumTravelMM
    }

    // MARK: State

    private enum Phase {
        case idle
        /// One finger down; still could turn out to be a tap.
        case oneFinger
        case pointing
        case dragging
        /// Two fingers down; scroll and pinch are still both possible.
        case twoFinger
        case scrolling
        case pinching
        /// Enough fingers for a swipe are down; waiting to see it travel far enough.
        case swipeArmed
        /// Three fingers down, nothing picked up yet.
        case threeFingerArmed
        /// Three fingers carrying the pointer with the button held down.
        case threeFingerDragging
        /// The hand left mid-drag. The button stays down for a moment in case it comes
        /// back, which is what makes a 65-mm surface enough to cross a desktop.
        case threeFingerHeld
        /// A gesture already fired, or a finger lifted mid-gesture. Swallow everything
        /// until the surface is clear — otherwise lifting one finger out of two would
        /// hand the remaining one to the pointer and make the cursor jump.
        case ignoring
    }

    private struct Tracked {
        var start: Vec
        var current: Vec
        var travel: Double = 0
        var startTime: Double
    }

    private var phase: Phase = .idle
    private var tracked: [UInt8: Tracked] = [:]

    /// Seconds since the recogniser started, accumulated from the phone's own clock so
    /// that network jitter cannot stretch or compress gesture timing.
    private var now: Double = 0
    private var lastSensorUs: UInt32?

    private var gestureAnchor = Vec()
    private var gestureStartTime: Double = 0
    private var lastCentroid = Vec()
    private var startSeparation: Double = 0
    private var lastZoomStep = 0

    private var velocityTracker = VelocityTracker()
    private var pointerVelocity = PointerVelocity()
    private var speedSmoother = SpeedSmoother()

    private var lastClickTime: Double = -.infinity
    private var lastClickPosition = Vec()
    private var lastClickCount = 0
    private var dragArmedUntil: Double = -.infinity

    /// How many fingers the three-finger drag last saw. A finger joining or leaving moves
    /// the centroid without the hand moving at all, and following that would throw the
    /// cursor across the screen mid-drag.
    private var dragContacts = 0
    private var dragResumeDeadline: Double = -.infinity

    public func reset() {
        phase = .idle
        tracked.removeAll()
        lastSensorUs = nil
        velocityTracker.reset()
        pointerVelocity.reset()
        speedSmoother.reset()
        lastClickCount = 0
        dragArmedUntil = -.infinity
        dragContacts = 0
        dragResumeDeadline = -.infinity
        framedSinceTick = 0
    }

    /// Frame time already counted since the last tick, so the two clocks do not both pay
    /// for the same milliseconds.
    private var framedSinceTick: Double = 0

    /// Lets time pass while the phone is silent. Call it steadily; `elapsed` is real seconds.
    ///
    /// Everything else here is driven by frames, deliberately — the phone's own clock cannot
    /// be stretched by the network. The drag's re-grab window is the exception, because it
    /// has to expire while the surface is *empty*, and an empty surface is exactly when the
    /// phone stops sending. A frame-driven deadline there is one that may never arrive, and
    /// it never did: the drag stayed picked up, swallowing every touch after it, until the
    /// receiver's stall watchdog let go of the button a second and a half later. Shortening
    /// the window changed nothing, because this deadline was never reached at all.
    ///
    /// Only the time frames did not already account for is added, so a hand still leaving
    /// the surface — which does send frames — cannot make the window expire twice as fast.
    public func tick(elapsed: Double) -> [InputEvent] {
        let unaccounted = max(0, elapsed - framedSinceTick)
        framedSinceTick = 0
        guard phase == .threeFingerHeld else { return [] }

        now += unaccounted
        guard now >= dragResumeDeadline else { return [] }
        phase = tracked.isEmpty ? .idle : .ignoring
        return [.dragEnded]
    }

    /// True while the drag owns the surface, whether or not fingers are on it.
    private var isThreeFingerDragging: Bool {
        phase == .threeFingerArmed || phase == .threeFingerDragging || phase == .threeFingerHeld
    }

    // MARK: Entry point

    public func process(_ frame: TouchFrame) -> [InputEvent] {
        advanceClock(frame.tSensorUs)
        let dt = lastDelta

        var events: [InputEvent] = []
        let positions = frame.contacts.reduce(into: [UInt8: Vec]()) { result, contact in
            result[contact.id] = Vec(
                x: Double(contact.x) * surface.widthMM,
                y: Double(contact.y) * surface.heightMM
            )
        }

        updateTracked(positions)

        // A running three-finger drag owns every contact count, including zero. The button
        // is down, so handing one or two fingers left over from an untidy lift back to the
        // pointer would drop whatever is being carried, halfway to wherever it was going.
        if isThreeFingerDragging {
            return handleThreeFingerDrag(count: positions.count, dt: dt)
        }

        switch positions.count {
        case 0: events += handleLiftOff()
        case 1: events += handleOneFinger(dt: dt)
        case 2: events += handleTwoFingers(dt: dt)
        case 3 where config.threeFingerDrag: events += armThreeFingerDrag()
        case 3: events += handleSwipe()
        case 4 where config.threeFingerDrag: events += handleSwipe()
        default:
            events += closeCurrentGesture()
            phase = .ignoring
        }

        return events
    }

    /// Terminates an in-progress scroll.
    ///
    /// A scroll that opened with `.began` and never closed leaves the system holding an
    /// unfinished gesture: no rubber-band release, no momentum, and system shortcuts can
    /// be swallowed while it believes one is still running.
    ///
    /// - Parameter fingersLeaving: true when this is the hand lifting off, false when the
    ///   gesture became something else. It decides whether the scroll gets to coast, and
    ///   the distinction matters more than it looks: fingers almost never leave the
    ///   surface in the same frame, so a two-finger scroll normally ends by dropping to
    ///   one contact — and closing *that* with zero velocity kills inertia on every
    ///   flick that does not happen to lift perfectly evenly.
    private func closeScroll(fingersLeaving: Bool = false) -> [InputEvent] {
        guard phase == .scrolling else { return [] }
        let exit = fingersLeaving ? velocityTracker.velocity(at: now) : nil
        let coasting = (exit?.length ?? 0) >= config.momentumMinSpeedMMPerS
        return [.scroll(
            dxMM: 0, dyMM: 0,
            phase: .ended(
                velocityX: coasting ? exit!.x : 0,
                velocityY: coasting ? exit!.y : 0
            )
        )]
    }

    /// Builds a pointer move, carrying the speed the acceleration curve should be read at.
    ///
    /// Both corrections live here rather than in the curve, because both are about the
    /// *estimate* and not about the shape of the response — and here they are testable
    /// without a Mac.
    private func moveEvent(delta: Vec, dt: Double, dragging: Bool = false) -> InputEvent {
        pointerVelocity.add(delta: delta, dt: dt, at: now)
        var speed = speedSmoother.follow(
            pointerVelocity.speed, dt: dt, fallTime: config.speedFallTime
        )
        if dragging { speed = max(speed, config.dragSpeedFloorMMPerS) }
        return .move(dxMM: delta.x, dyMM: delta.y, speedMMPerS: speed)
    }

    /// Closes whatever the current phase is holding open before another gesture takes the
    /// surface.
    ///
    /// A scroll left unfinished leaves the system inside a gesture that never ended. A drag
    /// left unfinished leaves the mouse button physically *down*, and nothing later in the
    /// stream releases it — landing two more fingers during a tap-drag did exactly that.
    private func closeCurrentGesture() -> [InputEvent] {
        phase == .dragging ? [.dragEnded] : closeScroll()
    }

    /// Wrapping subtraction: the phone's microsecond counter rolls over every 71 minutes,
    /// and a session outlives that. Gaps between frames never approach it.
    private var lastDelta: Double = 0

    private func advanceClock(_ sensorUs: UInt32) {
        if let previous = lastSensorUs {
            lastDelta = Double(sensorUs &- previous) / 1_000_000
            // A gap this large means the finger rested; do not let it drive velocity.
            if lastDelta > 1 { lastDelta = 0 }
            now += lastDelta
            framedSinceTick += lastDelta
        } else {
            lastDelta = 0
        }
        lastSensorUs = sensorUs
    }

    private func updateTracked(_ positions: [UInt8: Vec]) {
        for (id, point) in positions {
            if var existing = tracked[id] {
                existing.travel += (point - existing.current).length
                existing.current = point
                tracked[id] = existing
            } else {
                tracked[id] = Tracked(start: point, current: point, startTime: now)
            }
        }
        for id in tracked.keys where positions[id] == nil {
            // Stashed before removal: by the time the lift-off handler runs, the fingers
            // it needs to judge as a tap are already gone from `tracked`.
            lastLifted = tracked[id]
            tracked[id] = nil
        }
    }

    private var centroid: Vec {
        guard !tracked.isEmpty else { return Vec() }
        let sum = tracked.values.reduce(Vec()) { $0 + $1.current }
        return sum / Double(tracked.count)
    }

    private var separation: Double {
        let points = tracked.values.map(\.current)
        guard points.count >= 2 else { return 0 }
        return (points[0] - points[1]).length
    }

    // MARK: Zero fingers

    private func handleLiftOff() -> [InputEvent] {
        defer {
            phase = .idle
            velocityTracker.reset()
        }
        switch phase {
        case .oneFinger:
            return tapEvents(button: .left)
        case .twoFinger:
            return tapEvents(button: .right)
        case .dragging:
            return [.dragEnded]
        case .scrolling:
            return closeScroll(fingersLeaving: true)
        default:
            return []
        }
    }

    /// A tap only counts if the finger was down briefly and barely moved. Whichever
    /// finger we still remember carries the timing; they lifted together.
    private func tapEvents(button: MouseButton) -> [InputEvent] {
        guard let sample = tracked.values.first ?? lastLifted else { return [] }
        let duration = now - sample.startTime
        guard duration <= config.tapMaxDuration, sample.travel <= config.tapSlopMM else {
            return []
        }

        guard button == .left else { return [.click(.right, count: 1)] }

        let withinTime = now - lastClickTime <= config.doubleClickWindow
        let withinSpace = (sample.current - lastClickPosition).length <= config.doubleClickSlopMM
        lastClickCount = withinTime && withinSpace ? min(lastClickCount + 1, 3) : 1
        lastClickTime = now
        lastClickPosition = sample.current
        // A finger landing right after a tap and then moving means "drag", not "click
        // again" — macOS calls this dragging with tap.
        dragArmedUntil = now + config.dragArmWindow
        return [.click(.left, count: lastClickCount)]
    }

    private var lastLifted: Tracked?

    // MARK: One finger

    private func handleOneFinger(dt: Double) -> [InputEvent] {
        guard let id = tracked.keys.first, let contact = tracked[id] else { return [] }

        switch phase {
        case .idle:
            phase = .oneFinger
            lastCentroid = contact.current
            pointerVelocity.reset()
            speedSmoother.reset()
            return []

        case .oneFinger:
            guard contact.travel > config.tapSlopMM else { return [] }
            // Committed to motion. Release everything travelled since touch-down rather
            // than only this frame's delta: the slop is a dead zone for *deciding*, and
            // swallowing the movement as well is what makes a pointer feel like it sticks
            // before it starts.
            let delta = contact.current - contact.start
            lastCentroid = contact.current
            let elapsed = max(dt, now - contact.startTime)

            // If a tap just happened, this is the drag half of a tap-and-a-half rather
            // than a fresh pointer move.
            if now <= dragArmedUntil {
                phase = .dragging
                dragArmedUntil = -.infinity
                return [.dragBegan, moveEvent(delta: delta, dt: elapsed, dragging: true)]
            }
            phase = .pointing
            return [moveEvent(delta: delta, dt: elapsed)]

        case .pointing, .dragging:
            let delta = contact.current - lastCentroid
            lastCentroid = contact.current
            return [moveEvent(delta: delta, dt: dt, dragging: phase == .dragging)]

        default:
            // A finger left a multi-finger gesture, so the hand is on its way off the
            // surface. This transition — not the moment the surface finally goes empty —
            // is where a two-finger gesture actually ends, because two fingers hardly ever
            // leave in the same frame. Deferring the decision to full lift-off means the
            // right click is simply never emitted, and a scroll loses its momentum.
            let closing = phase == .twoFinger
                ? tapEvents(button: .right)
                : closeScroll(fingersLeaving: true)
            phase = .ignoring
            return closing
        }
    }

    // MARK: Two fingers

    private func handleTwoFingers(dt: Double) -> [InputEvent] {
        let current = centroid

        switch phase {
        case .idle, .oneFinger, .pointing:
            phase = .twoFinger
            gestureAnchor = current
            gestureStartTime = now
            lastCentroid = current
            startSeparation = separation
            lastZoomStep = 0
            velocityTracker.reset()
            return []

        case .twoFinger:
            let separationDelta = separation - startSeparation
            let spread = abs(separationDelta)
            let drift = (current - gestureAnchor).length

            // Both fingers sliding together is a scroll; fingers moving apart or together
            // is a pinch. Each branch must require its own signal to be the larger one.
            //
            // Testing the thresholds in sequence instead meant the smaller threshold
            // always won the race: a real pinch anchors the thumb, so the centroid drifts
            // by half the spread and crossed the 1 mm scroll threshold long before the
            // spread reached the 4 mm pinch threshold. Every pinch became a sideways
            // scroll. Waiting while neither signal leads costs a few frames and cannot
            // stall, because one of them always pulls ahead.
            if spread > config.pinchSlopMM, spread > drift {
                phase = .pinching
                return zoomEvents(separationDelta: separationDelta)
            }
            if drift > config.scrollSlopMM, drift >= spread {
                phase = .scrolling
                let delta = current - lastCentroid
                lastCentroid = current
                velocityTracker.reset()
                velocityTracker.add(current, at: now)
                return [.scroll(dxMM: delta.x, dyMM: delta.y, phase: .began)]
            }
            return []

        case .scrolling:
            let delta = current - lastCentroid
            lastCentroid = current
            velocityTracker.add(current, at: now)
            return [.scroll(dxMM: delta.x, dyMM: delta.y, phase: .changed)]

        case .pinching:
            return zoomEvents(separationDelta: separation - startSeparation)

        default:
            return []
        }
    }

    private func zoomEvents(separationDelta: Double) -> [InputEvent] {
        let step = Int((separationDelta / config.pinchStepMM).rounded(.towardZero))
        guard step != lastZoomStep else { return [] }
        defer { lastZoomStep = step }
        return [.zoom(steps: step - lastZoomStep)]
    }

    // MARK: Three-finger drag

    private func armThreeFingerDrag() -> [InputEvent] {
        // A gesture that already fired keeps the surface until the hand leaves; picking
        // something up on the way out is not what the fingers meant.
        guard phase != .ignoring else { return [] }
        let closing = closeCurrentGesture()
        phase = .threeFingerArmed
        gestureAnchor = centroid
        gestureStartTime = now
        dragContacts = 3
        return closing
    }

    /// Three fingers press the button and carry the pointer with their centroid.
    ///
    /// The whole of it is written around the surface being small. A phone is 65 mm across;
    /// a window crossing a desktop needs several times that, so the drag has to survive the
    /// hand lifting and landing again. That is why the button stays down through
    /// `.threeFingerHeld` instead of the gesture ending where the fingers do.
    private func handleThreeFingerDrag(count: Int, dt: Double) -> [InputEvent] {
        let current = centroid

        switch phase {
        case .threeFingerArmed:
            // Nothing has been picked up yet, so a fourth finger is still free to mean
            // something else. Once the button is down it is not.
            if count >= 4 { return handleSwipe() }
            guard count >= 3 else {
                // Three fingers tapped, or one left before the drag committed. Either way
                // nothing was picked up, so there is nothing to drop — and the leftovers
                // are a hand on its way off, not a new gesture.
                phase = count == 0 ? .idle : .ignoring
                return []
            }
            let delta = current - gestureAnchor
            guard delta.length > config.dragSlopMM else { return [] }
            phase = .threeFingerDragging
            lastCentroid = current
            pointerVelocity.reset()
            speedSmoother.reset()
            // Down first, then the travel since touch-down: the press has to land where the
            // cursor still is, or the drag starts by missing what it was aimed at.
            return [
                .dragBegan,
                moveEvent(delta: delta, dt: max(dt, now - gestureStartTime), dragging: true),
            ]

        case .threeFingerDragging:
            guard count >= 3 else {
                // Fingers never leave together, so a lift shows up as 3 → 2 and *this* is
                // where the re-grab window starts. Waiting for the surface to empty would
                // spend most of the window on the fingers still coming off.
                phase = .threeFingerHeld
                dragResumeDeadline = now + resumeWindow()
                return []
            }
            guard count == dragContacts else {
                dragContacts = count
                lastCentroid = current
                return []
            }
            let delta = current - lastCentroid
            lastCentroid = current
            return [moveEvent(delta: delta, dt: dt, dragging: true)]

        case .threeFingerHeld:
            if count >= 3 {
                // Back on the surface in time: same drag, new grip. No `dragBegan` — the
                // button never came up, and re-announcing it would buzz and re-click.
                phase = .threeFingerDragging
                dragContacts = count
                lastCentroid = current
                pointerVelocity.reset()
                speedSmoother.reset()
                return []
            }
            guard now >= dragResumeDeadline else { return [] }
            phase = count == 0 ? .idle : .ignoring
            return [.dragEnded]

        default:
            return []
        }
    }

    /// How long to keep holding after the hand leaves.
    ///
    /// A hand that ran out of surface and one that has finished both look the same at the
    /// moment they lift, and one timeout cannot suit both: short enough to drop promptly is
    /// too short to get a grip again. So the two are told apart by what the hand was doing —
    /// still pushing towards a border it had already reached means it will be back.
    private func resumeWindow() -> Double {
        let stillPushing = pointerVelocity.speed >= config.dragRunOutSpeedMMPerS
        guard stillPushing, handIsAtBorder(heading: pointerVelocity.displacement) else {
            return config.dragResumeWindow
        }
        return config.dragEdgeResumeWindow
    }

    /// Is the hand pressed against the border it has been travelling towards?
    ///
    /// Checked against the *fingers* rather than their centroid: three fingers spread across
    /// a 65-mm phone hold the centroid in the middle by construction, so it only reaches a
    /// side border once an outer finger has already left the surface. Only the axes the hand
    /// actually travelled along count — drifting a millimetre sideways is not running out of
    /// room in that direction.
    private func handIsAtBorder(heading: Vec) -> Bool {
        let points = tracked.values.map(\.current)
        guard !points.isEmpty else { return false }

        let margin = config.dragEdgeMarginMM
        let significant = max(max(abs(heading.x), abs(heading.y)) * 0.3, 0.5)
        var atBorder = false
        if heading.x > significant {
            atBorder = atBorder || points.contains { surface.widthMM - $0.x <= margin }
        }
        if -heading.x > significant {
            atBorder = atBorder || points.contains { $0.x <= margin }
        }
        if heading.y > significant {
            atBorder = atBorder || points.contains { surface.heightMM - $0.y <= margin }
        }
        if -heading.y > significant {
            atBorder = atBorder || points.contains { $0.y <= margin }
        }
        return atBorder
    }

    // MARK: Swipes

    /// Four fingers while the three-finger drag is on, three while it is off.
    private func handleSwipe() -> [InputEvent] {
        let current = centroid

        switch phase {
        case .swipeArmed:
            let delta = current - gestureAnchor
            guard max(abs(delta.x), abs(delta.y)) > config.swipeThresholdMM else { return [] }
            phase = .ignoring
            if abs(delta.x) > abs(delta.y) {
                return [.shortcut(delta.x > 0 ? .navigateForward : .navigateBack)]
            }
            // Downwards has no counterpart: App Exposé is a symbolic hotkey and the system
            // will not accept a synthesised one.
            guard delta.y < 0 else { return [] }
            return [.shortcut(.missionControl)]

        case .ignoring:
            return []

        default:
            let closing = closeCurrentGesture()
            phase = .swipeArmed
            gestureAnchor = current
            lastCentroid = current
            return closing
        }
    }
}
