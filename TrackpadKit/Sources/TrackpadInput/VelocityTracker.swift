import Foundation

/// Measures how fast the fingers were moving *just before* they left the surface.
///
/// This is what separates a flick, which should coast, from scrolling to a spot and
/// stopping there, which should not. The distinction is entirely about the last few tens
/// of milliseconds: an average over the whole gesture cannot see it, and neither can an
/// exponential smoother, which keeps a memory of motion the user has already abandoned.
///
/// So: a short sliding window, and two ways to say "no". Either no movement arrived
/// recently — the finger was resting when it lifted — or it moved too little inside the
/// window to count as intent.
struct VelocityTracker {
    struct Sample {
        var time: Double
        var position: Vec
    }

    /// How far back to measure. Long enough to average out one noisy frame, short enough
    /// that only the end of the gesture is in view.
    var window: Double = 0.06
    /// If nothing has moved for this long, the finger had already stopped. The phone sends
    /// no frames while a finger is still, so this is also what a genuine pause looks like.
    var restTimeout: Double = 0.05
    /// Movement inside the window below this is drift, not a throw.
    var minimumTravelMM: Double = 1.0

    private var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func add(_ position: Vec, at time: Double) {
        samples.append(Sample(time: time, position: position))
        // Keep one sample older than the window so it can anchor the measurement; drop
        // anything older still.
        while samples.count > 2, samples[1].time < time - window {
            samples.removeFirst()
        }
    }

    /// - Returns: velocity in mm/s over the recent window, or nil when the fingers were
    ///   effectively at rest and no inertia was asked for.
    func velocity(at now: Double) -> Vec? {
        guard let newest = samples.last, let oldest = samples.first else { return nil }
        guard now - newest.time <= restTimeout else { return nil }

        let interval = newest.time - oldest.time
        guard interval > 0 else { return nil }

        let displacement = newest.position - oldest.position
        guard displacement.length >= minimumTravelMM else { return nil }

        return Vec(x: displacement.x / interval, y: displacement.y / interval)
    }
}
