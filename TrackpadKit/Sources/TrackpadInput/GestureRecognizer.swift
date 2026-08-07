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

    /// Separation over time, so a pinch that is still opening when the fingers leave can
    /// carry on. The same tracker the scroll flick uses, fed a one-dimensional signal —
    /// its whole job is telling a throw from a hand that had already stopped, and that
    /// question is identical here.
    private var pinchTracker = VelocityTracker()
    private var zoomMomentum = MomentumEngine()
    /// Separation the coast has covered but not yet turned into whole zoom steps.
    private var zoomMomentumTravel: Double = 0

    private var lastClickTime: Double = -.infinity
    private var lastClickPosition = Vec()
    private var lastClickCount = 0
    private var dragArmedUntil: Double = -.infinity

    /// How many fingers the three-finger drag last saw. A finger joining or leaving moves
    /// the centroid without the hand moving at all, and following that would throw the
    /// cursor across the screen mid-drag.
    private var dragContacts = 0
    private var dragResumeDeadline: Double = -.infinity
    /// When fingers came back during a held drag, to tell a re-grab from a hand that means
    /// something else entirely.
    private var regrabTouchedAt: Double?
    /// Where the fingers were on the last frame that still had the whole hand carrying.
    ///
    /// Kept rather than read from the live contacts, because by the time the window has to
    /// be chosen the hand is already leaving: the finger that reached the border may be the
    /// one that went first, and a lost frame can take the whole hand away at once.
    private var lastDragPoints: [Vec] = []

    public func reset() {
        phase = .idle
        tracked.removeAll()
        lastSensorUs = nil
        velocityTracker.reset()
        pointerVelocity.reset()
        speedSmoother.reset()
        pinchTracker.reset()
        stopZoomMomentum()
        lastClickCount = 0
        dragArmedUntil = -.infinity
        dragContacts = 0
        dragResumeDeadline = -.infinity
        regrabTouchedAt = nil
        lastDragPoints = []
        edgePushLatch = Vec()
        framedSinceTick = 0
        tickedSinceFrame = 0
    }

    /// Everything the gesture that just finished was holding, dropped the moment the surface
    /// goes empty.
    ///
    /// Belt and braces against the one mistake this file has made in several shapes: a latch
    /// set by one gesture being read by the next. Nothing a later touch legitimately needs
    /// belongs here — the click chain and the arm a tap leaves for a drag are deliberately
    /// left alone, because linking one touch to the next is exactly their job. Both are
    /// bounded by the clock instead, which is the other half of this fix.
    private func clearFinishedGesture() {
        pointerVelocity.reset()
        speedSmoother.reset()
        pinchTracker.reset()
        lastZoomStep = 0
        dragContacts = 0
        regrabTouchedAt = nil
        lastDragPoints = []
        edgePushLatch = Vec()
    }

    /// Frame time already counted since the last tick, so the two clocks do not both pay
    /// for the same milliseconds.
    private var framedSinceTick: Double = 0
    /// And its mirror: tick time already counted since the last frame, so the gap that a
    /// returning frame reports is not charged a second time either.
    private var tickedSinceFrame: Double = 0

    /// Lets time pass while the phone is silent. Call it steadily; `elapsed` is real seconds.
    ///
    /// The recogniser's clock is otherwise driven by frames, deliberately — the phone's own
    /// timestamps cannot be stretched by the network. But an empty surface sends no frames
    /// at all, and windows that have to expire between gestures live exactly there: the
    /// drag's re-grab, the arm a tap leaves for the drag half of a tap-and-a-half, the
    /// double-click window. A frame-driven deadline in that gap is one that may never
    /// arrive, and none of them did.
    ///
    /// Only the time frames did not already account for is added, so a hand still leaving
    /// the surface — which does send frames — cannot make a window expire twice as fast.
    public func tick(elapsed: Double) -> [InputEvent] {
        let unaccounted = max(0, elapsed - framedSinceTick)
        framedSinceTick = 0
        now += unaccounted
        tickedSinceFrame += unaccounted

        // The zoom coast runs on an empty surface, whatever the phase says.
        var events = coastZoom(elapsed: elapsed)

        // The edge push runs on the *whole* interval, not the leftover: the fingers are on
        // the surface and sending frames the entire time, so there is no leftover, and its
        // whole point is to keep moving while they do not.
        if phase == .threeFingerDragging { return events + edgePush(elapsed: elapsed) }
        guard phase == .threeFingerHeld else { return events }

        guard now >= dragResumeDeadline else { return events }
        phase = tracked.isEmpty ? .idle : .ignoring
        events.append(.dragEnded)
        return events
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

        // A finger touching down catches the zoom where it is, the way it catches a
        // coasting scroll.
        if !positions.isEmpty { stopZoomMomentum() }

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
        defer { lastSensorUs = sensorUs }
        guard let previous = lastSensorUs else {
            lastDelta = 0
            return
        }
        let gap = Double(sensorUs &- previous) / 1_000_000

        // A gap this large is the hand having been away — the phone sends nothing while the
        // surface is empty. Time still passed and the clock has to take it, or every window
        // that expires *between* gestures never expires at all: the tap-drag arm stayed
        // open, so the next touch to move picked the button up instead of pointing, and two
        // taps a minute apart came out as a double click. What the gap must not do is drive
        // velocity, because the finger did not travel across it.
        lastDelta = gap > 1 ? 0 : gap

        // Whatever the ticks already credited during the silence is not charged again.
        let fresh = max(0, gap - tickedSinceFrame)
        tickedSinceFrame = 0
        now += fresh
        framedSinceTick += fresh
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
        // Runs after the return value is built, so the zoom coast still gets to read the
        // pinch tracker on its way out.
        defer {
            phase = .idle
            velocityTracker.reset()
            clearFinishedGesture()
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
        case .pinching:
            return startZoomMomentum()
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
            let closing: [InputEvent] = switch phase {
            case .twoFinger: tapEvents(button: .right)
            case .pinching: startZoomMomentum()
            default: closeScroll(fingersLeaving: true)
            }
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
            pinchTracker.reset()
            return []

        case .twoFinger:
            pinchTracker.add(Vec(x: separation, y: 0), at: now)
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
            pinchTracker.add(Vec(x: separation, y: 0), at: now)
            return zoomEvents(separationDelta: separation - startSeparation)

        default:
            return []
        }
    }

    /// Lets a pinch carry on after the fingers leave.
    ///
    /// Without it a zoom stops dead at lift-off, the same tell that a scroll without
    /// inertia gives. Whether to coast at all is the flick question again, so it is the
    /// same tracker and the same answer: fingers that had already stopped were placing the
    /// zoom exactly where it is, and carrying past that would be the surface arguing with
    /// the hand.
    private func startZoomMomentum() -> [InputEvent] {
        zoomMomentum.decayPerSecond = config.zoomMomentumDecayPerSecond
        zoomMomentum.stopSpeedMMPerS = config.zoomMomentumMinSpeedMMPerS
        guard let exit = pinchTracker.velocity(at: now),
              abs(exit.x) >= config.zoomMomentumMinSpeedMMPerS else { return [] }
        zoomMomentum.start(velocityX: exit.x, velocityY: 0)
        zoomMomentumTravel = 0
        return []
    }

    /// One tick of the zoom coast, in whole notches.
    private func coastZoom(elapsed: Double) -> [InputEvent] {
        guard zoomMomentum.isActive, let step = zoomMomentum.tick(dt: elapsed) else { return [] }
        zoomMomentumTravel += step.dxMM
        let notches = Int((zoomMomentumTravel / config.pinchStepMM).rounded(.towardZero))
        guard notches != 0 else { return [] }
        zoomMomentumTravel -= Double(notches) * config.pinchStepMM
        return [.zoom(steps: notches)]
    }

    private func stopZoomMomentum() {
        zoomMomentum.stop()
        zoomMomentumTravel = 0
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

        // A stroke that is already under way must not turn into a drag. Two more contacts
        // appearing in the middle of one are far more likely to be the side of a finger, a
        // knuckle, or a touch the phone mis-reported than a decision to pick something up:
        // a hand that means to drag plants three fingers together, it does not add them to
        // a movement in progress. Getting this wrong presses the mouse button under a
        // moving pointer, which is how text selects itself out of nowhere.
        if phase == .pointing || phase == .dragging {
            let closing = closeCurrentGesture()
            phase = .ignoring
            return closing
        }
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
            edgePushLatch = Vec()
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
            lastDragPoints = tracked.values.map(\.current)
            guard count == dragContacts else {
                dragContacts = count
                lastCentroid = current
                return []
            }
            let delta = current - lastCentroid
            lastCentroid = current
            // After the move, so the latch reads a heading that includes this frame.
            let carried = moveEvent(delta: delta, dt: dt, dragging: true)
            updateEdgePushLatch()
            return [carried]

        case .threeFingerHeld:
            if count >= 3 {
                // Back on the surface in time: same drag, new grip. No `dragBegan` — the
                // button never came up, and re-announcing it would buzz and re-click.
                phase = .threeFingerDragging
                dragContacts = count
                lastCentroid = current
                regrabTouchedAt = nil
                pointerVelocity.reset()
                speedSmoother.reset()
                // A new grip earns its own push: the old one was latched onto a border this
                // hand may have landed nowhere near.
                edgePushLatch = Vec()
                return []
            }

            // Fingers on the surface that are not on their way to three. Waiting out the
            // window for them would leave the trackpad dead for its whole length, so the
            // hand is taken at its word: whatever this is, it is not a re-grab.
            if count > 0 {
                let touchedAt = regrabTouchedAt ?? now
                regrabTouchedAt = touchedAt
                if now - touchedAt > config.dragRegrabTimeout {
                    regrabTouchedAt = nil
                    pointerVelocity.reset()
                    speedSmoother.reset()
                    // One finger carries on as an ordinary pointer from where it already
                    // is — making it lift and touch again for nothing would be worse than
                    // the wait it was let out of.
                    phase = count == 1 ? .oneFinger : .ignoring
                    return [.dragEnded]
                }
            } else {
                regrabTouchedAt = nil
            }

            guard now >= dragResumeDeadline else { return [] }
            phase = count == 0 ? .idle : .ignoring
            return [.dragEnded]

        default:
            return []
        }
    }

    /// Keeps a drag travelling while the fingers are pinned against a border.
    ///
    /// Selecting down a long page runs out of surface long before it runs out of page, and a
    /// window crossing a wide desktop runs out of it sideways even sooner — 70 mm of glass is
    /// a few hundred points of screen. The pointer is pushed on rather than the view
    /// scrolled: an application tracking a mouse drag runs its own event loop that takes only
    /// dragged and up events, so a synthesised wheel event would sit in the queue until the
    /// drag was over. Pushed to the edge of its view, the application scrolls itself — and
    /// extends the selection while it does, which is the part nothing outside it could get
    /// right.
    private func edgePush(elapsed: Double) -> [InputEvent] {
        guard elapsed > 0, let rate = edgePushRate() else { return [] }
        // `lastCentroid` is deliberately left alone: it is where the *fingers* are, and the
        // next frame measures against it. Advancing it by the push made every frame report
        // the push back as movement in the opposite direction — the pointer shook in place
        // and the page scrolled in lurches.
        //
        // Read at the curve's unity point rather than at the push rate, so screen travel
        // stays proportional to the ramp. Feeding the rate to a curve built for human hands
        // squared it: half-way into the zone moved a third as fast as the edge, not half.
        return [.move(
            dxMM: rate.x * elapsed,
            dyMM: rate.y * elapsed,
            speedMMPerS: config.dragSpeedFloorMMPerS
        )]
    }

    /// Which border each axis has latched onto: −1, 0 or +1. Cleared whenever a fresh grip
    /// takes the surface, so the push is something a hand earns rather than something it
    /// inherits.
    private var edgePushLatch = Vec()

    /// Decides which border, if any, the drag is pressing into.
    ///
    /// Two different questions, which is why the latch exists at all. *Starting* a push takes
    /// a hand actually travelling towards the border — sideways especially, because three
    /// fingers span half the width of a phone and end up inside the side zone without meaning
    /// anything by it, and a drag aimed straight down would then crab across the screen.
    /// *Continuing* one only takes the hand not turning back: pressing into the border and
    /// holding there is the whole gesture, and the speed estimate reads zero within a couple
    /// of frames of the hand stopping.
    ///
    /// Called from the frames rather than from the tick that asks for the push, because
    /// frames are where movement is visible. Judged at push time, the hand is already at rest
    /// against the border and nothing would ever latch.
    private func updateEdgePushLatch() {
        guard let box = dragBounds() else { return }
        let heading = pointerVelocity.displacement
        latch(&edgePushLatch.x, ahead: box.aheadX, behind: box.behindX,
              margin: config.dragEdgePushSideMarginMM, heading: heading.x)
        latch(&edgePushLatch.y, ahead: box.aheadY, behind: box.behindY,
              margin: config.dragEdgePushMarginMM, heading: heading.y)
    }

    /// Half a millimetre over the trailing window is the line between travelling and
    /// resting — small enough that a slow deliberate push still counts as one.
    private func latch(
        _ state: inout Double, ahead: Double, behind: Double, margin: Double, heading: Double
    ) {
        guard margin > 0 else {
            state = 0
            return
        }
        if state > 0, ahead > margin || heading < -0.5 { state = 0 }
        if state < 0, behind > margin || heading > 0.5 { state = 0 }
        guard state == 0 else { return }
        if ahead <= margin, heading > 0.5 { state = 1 }
        if behind <= margin, heading < -0.5 { state = -1 }
    }

    /// How much room the fingers have left in each direction, from the leading finger on
    /// each side rather than from the centroid: three fingers hold the centroid in the
    /// middle by construction, so it reaches a side border only once a finger has already
    /// left the surface.
    private func dragBounds() -> (aheadX: Double, behindX: Double, aheadY: Double, behindY: Double)? {
        let xs = lastDragPoints.map(\.x)
        let ys = lastDragPoints.map(\.y)
        guard let left = xs.min(), let right = xs.max(),
              let top = ys.min(), let bottom = ys.max() else { return nil }
        return (surface.widthMM - right, left, surface.heightMM - bottom, top)
    }

    /// Millimetres per second along each axis, positive right and down; nil when there is
    /// nothing to push. Both axes at once when the hand is cornered, which is the diagonal
    /// case and needs no special handling.
    private func edgePushRate() -> Vec? {
        guard config.dragEdgePushMaxMMPerS > 0, let box = dragBounds() else { return nil }
        let push = Vec(
            x: taperedRate(edgePushLatch.x, ahead: box.aheadX, behind: box.behindX,
                           margin: config.dragEdgePushSideMarginMM),
            y: taperedRate(edgePushLatch.y, ahead: box.aheadY, behind: box.behindY,
                           margin: config.dragEdgePushMarginMM)
        )
        return push == Vec() ? nil : push
    }

    /// Full rate at the very border, tapering to nothing at the edge of the zone, so
    /// crossing into it does not snatch the pointer.
    private func taperedRate(
        _ latched: Double, ahead: Double, behind: Double, margin: Double
    ) -> Double {
        guard margin > 0 else { return 0 }
        let room = latched > 0 ? ahead : behind
        guard latched != 0 else { return 0 }
        return latched * config.dragEdgePushMaxMMPerS * max(0, min(1, (margin - room) / margin))
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
        let points = lastDragPoints
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
