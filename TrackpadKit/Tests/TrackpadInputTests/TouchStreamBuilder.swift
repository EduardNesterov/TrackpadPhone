import Foundation
import TrackpadProtocol

@testable import TrackpadInput

/// Builds finger streams the way a hand would produce them, so tests read as gestures
/// rather than as arrays of coordinates.
///
/// Positions are in millimetres on the surface — the same unit the recogniser thinks in,
/// which means a threshold in `GestureConfig` and the movement in a test are directly
/// comparable instead of separated by a conversion nobody can check by eye.
struct TouchStreamBuilder {
    let surface: SurfaceGeometry
    var hz: Double = 120

    private var fingers: [UInt8: (x: Double, y: Double)] = [:]
    private var seen: Set<UInt8> = []
    private var seq: UInt16 = 0
    private var timeUs: UInt32 = 0
    private(set) var frames: [TouchFrame] = []

    init(surface: SurfaceGeometry = SurfaceGeometry(widthMM: 70, heightMM: 150)) {
        self.surface = surface
    }

    private var frameIntervalUs: UInt32 { UInt32(1_000_000 / hz) }

    /// Registers a finger without emitting. Placing several fingers then holding puts
    /// them all down in the same frame, which is what landing two fingers together looks
    /// like — emitting per placement would fake a one-finger phase that never happened.
    mutating func place(_ id: UInt8, xMM: Double, yMM: Double) {
        fingers[id] = (xMM, yMM)
    }

    mutating func hold(_ seconds: Double) {
        for _ in 0 ..< max(1, Int(seconds * hz)) { emit() }
    }

    mutating func move(_ id: UInt8, dxMM: Double, dyMM: Double, over seconds: Double) {
        let steps = max(1, Int(seconds * hz))
        guard let start = fingers[id] else { return }
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            fingers[id] = (start.x + dxMM * fraction, start.y + dyMM * fraction)
            emit()
        }
    }

    mutating func moveAll(dxMM: Double, dyMM: Double, over seconds: Double) {
        let steps = max(1, Int(seconds * hz))
        let start = fingers
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            for (id, origin) in start {
                fingers[id] = (origin.x + dxMM * fraction, origin.y + dyMM * fraction)
            }
            emit()
        }
    }

    /// Spreads fingers 0 and 1 while finger 0 stays put — how people actually pinch, with
    /// the thumb anchored. The centroid therefore drifts by half the separation change,
    /// which the symmetric version below hides completely.
    mutating func pinchOneAnchored(byMM amount: Double, over seconds: Double) {
        let steps = max(1, Int(seconds * hz))
        let start = fingers
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            if let b = start[1] { fingers[1] = (b.x + amount * fraction, b.y) }
            emit()
        }
    }

    /// Moves fingers 0 and 1 apart (positive) or together (negative) along x, keeping the
    /// midpoint fixed so the gesture is pure pinch with no centroid drift.
    mutating func pinch(byMM amount: Double, over seconds: Double) {
        let steps = max(1, Int(seconds * hz))
        let start = fingers
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            if let a = start[0] { fingers[0] = (a.x - amount / 2 * fraction, a.y) }
            if let b = start[1] { fingers[1] = (b.x + amount / 2 * fraction, b.y) }
            emit()
        }
    }

    mutating func lift(_ id: UInt8) {
        fingers[id] = nil
        emit()
    }

    mutating func liftAll() {
        fingers.removeAll()
        emit()
    }

    private mutating func emit() {
        let contacts = fingers.map { id, position in
            let phase: TouchPhase = seen.contains(id) ? .moved : .began
            return Contact(
                id: id,
                phase: phase,
                x: Float(position.x / surface.widthMM),
                y: Float(position.y / surface.heightMM)
            )
        }
        seen.formUnion(fingers.keys)
        frames.append(TouchFrame(seq: seq, tSensorUs: timeUs, contacts: contacts))
        seq &+= 1
        timeUs &+= frameIntervalUs
    }
}

extension GestureRecognizer {
    /// Runs a whole stream and returns everything it produced.
    func run(_ builder: TouchStreamBuilder) -> [InputEvent] {
        builder.frames.flatMap { process($0) }
    }
}

extension Array where Element == InputEvent {
    var clicks: [InputEvent] {
        filter { if case .click = $0 { true } else { false } }
    }

    var scrolls: [InputEvent] {
        filter { if case .scroll = $0 { true } else { false } }
    }

    var moves: [InputEvent] {
        filter { if case .move = $0 { true } else { false } }
    }

    var shortcuts: [InputEvent] {
        filter { if case .shortcut = $0 { true } else { false } }
    }

    var zooms: [InputEvent] {
        filter { if case .zoom = $0 { true } else { false } }
    }

    /// Total pointer travel in millimetres.
    var totalMoveMM: (x: Double, y: Double) {
        reduce(into: (0.0, 0.0)) { total, event in
            if case .move(let dx, let dy, _) = event {
                total.0 += dx
                total.1 += dy
            }
        }
    }

    var totalScrollMM: (x: Double, y: Double) {
        reduce(into: (0.0, 0.0)) { total, event in
            if case .scroll(let dx, let dy, _) = event {
                total.0 += dx
                total.1 += dy
            }
        }
    }
}
