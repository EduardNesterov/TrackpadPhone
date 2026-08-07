import Foundation
import os

/// Fixed-size ring of interleaved stereo samples, shared between the network and the audio
/// thread.
///
/// The audio render callback runs on a real-time thread: it must not allocate, must not
/// wait on anything that can be held for long, and must always return something. So the
/// storage is preallocated, the critical section is a pair of memory copies, and a read
/// that cannot be satisfied returns silence rather than blocking for more.
///
/// `os_unfair_lock` rather than a Swift lock: it is a few instructions when uncontended,
/// which is the normal case here — one writer, one reader, both brief.
final class AudioRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var filled = 0
    private var lock = os_unfair_lock()

    /// Silence is played until this much has accumulated.
    ///
    /// Without it the head start never forms: the speaker consumes as fast as the network
    /// delivers, the ring hovers at empty, and every packet that is even slightly late is
    /// an underrun. Priming is where the latency target actually takes effect.
    private var primeThreshold = 0
    private var primed = false

    /// Samples, not frames: stereo means two per frame.
    init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    func setPrimeThreshold(_ samples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        primeThreshold = samples
    }

    var filledSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return filled
    }

    /// - Returns: how many samples had to be discarded because the ring was full. Non-zero
    ///   means the phone is consuming slower than the Mac produces — the clock drift this
    ///   design has to survive.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var dropped = 0
        if filled + samples.count > capacity {
            // Drop from the *front*: the freshest audio is what the listener wants, and
            // discarding the newest would mean permanently playing further behind.
            let overflow = filled + samples.count - capacity
            readIndex = (readIndex + overflow) % capacity
            filled -= overflow
            dropped = overflow
        }

        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        filled += samples.count
        return dropped
    }

    /// Fills `destination` with up to `count` samples, padding with silence if short.
    ///
    /// - Returns: how many samples of silence had to be invented. Non-zero is an underrun,
    ///   which is exactly what a click sounds like.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if !primed {
            guard primeThreshold > 0, filled >= primeThreshold else {
                for index in 0 ..< count { destination[index] = 0 }
                return 0   // priming silence is expected, not an underrun
            }
            primed = true
        }

        let available = min(count, filled)
        for index in 0 ..< available {
            destination[index] = storage[(readIndex + index) % capacity]
        }
        readIndex = (readIndex + available) % capacity
        filled -= available

        if available < count {
            for index in available ..< count { destination[index] = 0 }
            // Ran dry. Rebuild the head start rather than limping along one packet deep,
            // where every jitter spike would click again.
            primed = false
        }
        return count - available
    }

    /// Throws away everything buffered. Used when the stream restarts, where playing the
    /// old contents would just be a burst of stale audio.
    func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        readIndex = 0
        writeIndex = 0
        filled = 0
        primed = false
    }

    /// Discards the oldest samples. The drift valve: when the ring creeps upwards over
    /// minutes because the Mac's clock runs slightly fast, this trims it back.
    func drop(samples count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let amount = min(count, filled)
        readIndex = (readIndex + amount) % capacity
        filled -= amount
    }
}
