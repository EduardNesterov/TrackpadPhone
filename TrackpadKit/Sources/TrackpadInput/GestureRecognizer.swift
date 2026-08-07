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
        case threeFinger
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

    private var velocity = Vec()

    private var lastClickTime: Double = -.infinity
    private var lastClickPosition = Vec()
    private var lastClickCount = 0
    private var dragArmedUntil: Double = -.infinity

    public func reset() {
        phase = .idle
        tracked.removeAll()
        lastSensorUs = nil
        velocity = Vec()
        lastClickCount = 0
        dragArmedUntil = -.infinity
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

        switch positions.count {
        case 0: events += handleLiftOff()
        case 1: events += handleOneFinger(dt: dt)
        case 2: events += handleTwoFingers(dt: dt)
        case 3: events += handleThreeFingers()
        default: phase = .ignoring
        }

        return events
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
            velocity = Vec()
        }
        switch phase {
        case .oneFinger:
            return tapEvents(button: .left)
        case .twoFinger:
            return tapEvents(button: .right)
        case .dragging:
            return [.dragEnded]
        case .scrolling:
            let coasting = velocity.length >= config.momentumMinSpeedMMPerS
            return [.scroll(
                dxMM: 0, dyMM: 0,
                phase: .ended(
                    velocityX: coasting ? velocity.x : 0,
                    velocityY: coasting ? velocity.y : 0
                )
            )]
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
            return []

        case .oneFinger:
            let delta = contact.current - lastCentroid
            lastCentroid = contact.current
            guard contact.travel > config.tapSlopMM else { return [] }
            // Committed to motion. If a tap just happened, this is the drag half of a
            // tap-and-a-half rather than a fresh pointer move.
            if now <= dragArmedUntil {
                phase = .dragging
                dragArmedUntil = -.infinity
                return [.dragBegan, .move(dxMM: delta.x, dyMM: delta.y, dt: dt)]
            }
            phase = .pointing
            return [.move(dxMM: delta.x, dyMM: delta.y, dt: dt)]

        case .pointing, .dragging:
            let delta = contact.current - lastCentroid
            lastCentroid = contact.current
            return [.move(dxMM: delta.x, dyMM: delta.y, dt: dt)]

        default:
            // Arrived here by lifting a finger out of a multi-finger gesture.
            phase = .ignoring
            return []
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
            velocity = Vec()
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
                updateVelocity(delta: delta, dt: dt)
                return [.scroll(dxMM: delta.x, dyMM: delta.y, phase: .began)]
            }
            return []

        case .scrolling:
            let delta = current - lastCentroid
            lastCentroid = current
            updateVelocity(delta: delta, dt: dt)
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

    /// Exponential smoothing. A single frame's delta is far too noisy to launch inertia
    /// with; a plain average over the whole gesture would ignore a late change of speed.
    private func updateVelocity(delta: Vec, dt: Double) {
        guard dt > 0 else { return }
        let instant = Vec(x: delta.x / dt, y: delta.y / dt)
        let smoothing = 0.7
        velocity = Vec(
            x: velocity.x * (1 - smoothing) + instant.x * smoothing,
            y: velocity.y * (1 - smoothing) + instant.y * smoothing
        )
    }

    // MARK: Three fingers

    private func handleThreeFingers() -> [InputEvent] {
        let current = centroid

        switch phase {
        case .threeFinger:
            let delta = current - gestureAnchor
            guard max(abs(delta.x), abs(delta.y)) > config.swipeThresholdMM else { return [] }
            phase = .ignoring
            if abs(delta.x) > abs(delta.y) {
                return [.shortcut(delta.x > 0 ? .spaceRight : .spaceLeft)]
            }
            return [.shortcut(delta.y < 0 ? .missionControl : .applicationWindows)]

        case .ignoring:
            return []

        default:
            phase = .threeFinger
            gestureAnchor = current
            lastCentroid = current
            return []
        }
    }
}
