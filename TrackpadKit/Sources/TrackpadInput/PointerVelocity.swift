import Foundation

/// Takes the jitter out of the speed the acceleration curve is read at.
///
/// The curve multiplies every millimetre of finger travel by a factor read from the current
/// speed, so noise in the *estimate* becomes noise in the movement: a finger sliding at a
/// constant pace produces cursor steps of different sizes frame after frame, and that — not
/// the sensor — is what reads as a rough pointer. Frames arriving over Wi-Fi make it worse,
/// because an interval stretched by the network looks exactly like a finger that slowed down.
///
/// Position is deliberately left alone. It is ground truth; filtering it would cost latency
/// and quietly swallow travel, while filtering a derived quantity costs neither.
///
/// Rises pass through untouched and only falls decay. A flick has to reach its gain on the
/// first frame or the pointer feels like it needs a run-up, and the estimate below already
/// averages over a trailing window — so what is left worth removing is momentary dips.
struct SpeedSmoother {
    private var current: Double = 0

    mutating func reset() {
        current = 0
    }

    mutating func follow(_ speed: Double, dt: Double, fallTime: Double) -> Double {
        guard dt > 0, fallTime > 0 else {
            current = speed
            return speed
        }
        if speed >= current {
            current = speed
        } else {
            current += (speed - current) * (1 - exp(-dt / fallTime))
        }
        return current
    }
}

/// Estimates how fast the finger is moving, for the acceleration curve to act on.
///
/// A single frame's delta is far too noisy to drive gain — at 120 Hz one frame is under a
/// tenth of a millimetre, and quantisation alone swings the implied speed wildly. So the
/// estimate runs over a short trailing window, the approach libinput uses.
///
/// The window is not fixed, and that is the interesting part. It collapses when the motion
/// changes character:
///
/// * **On a direction reversal** — otherwise the speed built up going right is still in the
///   estimate when the finger starts going left, and the pointer leaves in the new
///   direction at a gain nobody asked for. This is what makes reversals overshoot.
/// * **On a sharp change of speed** — a flick after slow positioning should reach high gain
///   at once, not after the window has finished averaging the slow part away.
///
/// Between those, the longer window keeps steady movement smooth. Distance is the vector
/// sum rather than the sum of lengths, so a wandering finger reads as slow even though it
/// covers ground — which is right, because wandering is not travel.
struct PointerVelocity {
    /// Samples older than this never count, however still the finger has been.
    var maxAge: Double = 0.06
    /// Instantaneous speed exceeding the windowed estimate by this much means the motion
    /// has changed character, so the history is cut back to let the estimate catch up.
    var burstRatio: Double = 2.0

    private struct Sample {
        var time: Double
        var dt: Double
        var delta: Vec
    }

    private var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    mutating func add(delta: Vec, dt: Double, at time: Double) {
        guard dt > 0, dt < 1 else { return }

        let travelled = displacement
        if travelled.length > 0.1, delta.x * travelled.x + delta.y * travelled.y < 0 {
            samples.removeAll(keepingCapacity: true)
        } else {
            let windowed = speed
            if windowed > 0, delta.length / dt > windowed * burstRatio {
                samples.removeAll(keepingCapacity: true)
            }
        }

        samples.append(Sample(time: time, dt: dt, delta: delta))
        samples.removeAll { time - $0.time > maxAge }
    }

    private var displacement: Vec {
        samples.reduce(Vec()) { $0 + $1.delta }
    }

    /// Speed in millimetres per second over the retained window.
    ///
    /// Summing each sample's own interval rather than subtracting timestamps: a sample's
    /// delta covers the time *before* its timestamp, so the difference between first and
    /// last would leave out the oldest interval and overstate the speed.
    var speed: Double {
        // One sample is not an estimate, it is a single noisy frame — and after a reset
        // that is all there is. Reporting zero rather than the instantaneous value is
        // deliberate: the window has just been cleared because the motion changed, so the
        // honest answer is "not known yet", and the low-speed end of the curve is where
        // that belongs. It also means a correction after a reversal starts precise, and
        // that a tremor, which reverses every frame and never accumulates two samples,
        // never reads as fast travel.
        guard samples.count >= 2 else { return 0 }
        let elapsed = samples.reduce(0) { $0 + $1.dt }
        guard elapsed > 0 else { return 0 }
        return displacement.length / elapsed
    }
}
