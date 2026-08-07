import AVFoundation
import TrackpadProtocol

/// Plays the Mac's audio.
///
/// The network pushes and the speaker pulls, and they run on independent clocks that agree
/// about nothing. A ring buffer between them is what turns two irregular rhythms into one
/// steady stream — the first version scheduled each packet as it arrived, and every late
/// packet became an audible click.
///
/// Two problems have to be survived, and they are different:
///
/// * **Jitter** — packets arrive unevenly. Measured on this link: 10 ms apart nominally,
///   13.8 ms at p95. Solved by keeping a head start, which is bought with latency.
/// * **Drift** — the Mac's audio clock and the phone's differ by tens of parts per million,
///   so over minutes the buffer fills or empties however good the network is. Solved by
///   trimming when it creeps up and letting it refill when it creeps down.
@Observable
@MainActor
final class AudioPlayer {
    /// How much audio to keep ahead. The whole latency question lives in this number:
    /// larger is safer against jitter and further behind the picture.
    var targetLatencyMs: Double = 45 {
        didSet {
            UserDefaults.standard.set(targetLatencyMs, forKey: "audioTargetMs")
            ring.setPrimeThreshold(targetSamples)
        }
    }

    private(set) var isPlaying = false
    private(set) var packetsReceived = 0
    private(set) var packetsLost = 0
    private(set) var underruns = 0
    private(set) var overflows = 0
    private(set) var arrivalJitterP95Ms: Double = 0
    private(set) var outputLatencyMs: Double = 0
    private(set) var bufferedMs: Double = 0

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring = AudioRingBuffer(capacity: 48000 * 2)   // one second of stereo
    private let sampleRate: Double = 48000

    private var lastSeq: UInt16?
    private var lastArrival: Double?
    private var gaps: [Double] = []

    /// Written from the audio thread, read from the main one. A missed increment costs a
    /// wrong statistic and nothing else, which is not worth a lock on a real-time thread.
    private nonisolated(unsafe) var underrunCount = 0

    init() {
        if let stored = UserDefaults.standard.object(forKey: "audioTargetMs") as? Double {
            targetLatencyMs = stored
        }
        ring.setPrimeThreshold(targetSamples)
    }

    private var targetSamples: Int { Int(targetLatencyMs / 1000 * sampleRate) * 2 }

    // MARK: - Engine

    func start() {
        guard !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            outputLatencyMs = session.outputLatency * 1000

            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 2, interleaved: false) else { return }

            // A source node rather than scheduled buffers: its render block is pulled by the
            // hardware at the hardware's own pace, which is the only arrangement in which
            // the two clocks are allowed to disagree without the stream tearing.
            let ring = self.ring
            let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let frames = Int(frameCount)
                var scratch = [Float](repeating: 0, count: frames * 2)
                let missing = scratch.withUnsafeMutableBufferPointer { pointer -> Int in
                    guard let base = pointer.baseAddress else { return frames * 2 }
                    return ring.read(into: base, count: frames * 2)
                }
                if missing > 0 { self?.underrunCount += 1 }

                // Interleaved in the ring, planar in the node's buffers.
                for (channel, buffer) in buffers.enumerated() where channel < 2 {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0 ..< frames {
                        data[frame] = scratch[frame * 2 + channel]
                    }
                }
                return noErr
            }

            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            sourceNode = node
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        ring.reset()
        try? AVAudioSession.sharedInstance().setActive(false)
        isPlaying = false
        bufferedMs = 0
    }

    func resetStats() {
        packetsReceived = 0
        packetsLost = 0
        underruns = 0
        overflows = 0
        underrunCount = 0
        gaps.removeAll()
        arrivalJitterP95Ms = 0
    }

    // MARK: - Incoming

    func play(_ chunk: AudioChunk) {
        if !isPlaying { start() }
        guard isPlaying else { return }

        measureArrival()

        if let last = lastSeq {
            let missing = Int(chunk.seq &- last) - 1
            // A modest gap is loss. A huge one means the Mac restarted its stream, and
            // carrying the old buffer across would only play stale audio.
            if missing > 0, missing < 100 {
                packetsLost += missing
            } else if missing != 0 {
                ring.reset()
            }
        }
        lastSeq = chunk.seq
        packetsReceived += 1

        var samples = [Float](repeating: 0, count: chunk.samples.count)
        for index in 0 ..< chunk.samples.count {
            samples[index] = Float(chunk.samples[index]) / 32767
        }
        if ring.write(samples) > 0 { overflows += 1 }

        manageDrift()
    }

    private func measureArrival() {
        let now = CACurrentMediaTime() * 1000
        if let previous = lastArrival {
            let gap = now - previous
            if gap < 500 { gaps.append(gap) }
            if gaps.count > 400 { gaps.removeFirst(gaps.count - 400) }
        }
        lastArrival = now
    }

    /// Keeps the head start near its target.
    ///
    /// Nothing here is clever and it does not need to be: drift is tens of parts per
    /// million, so a correction every few seconds is ample. Trimming a few milliseconds is
    /// inaudible, while letting the buffer grow unchecked would put the sound a second
    /// behind the picture within an hour.
    private func manageDrift() {
        let filled = ring.filledSamples
        bufferedMs = Double(filled) / 2 / sampleRate * 1000

        // Half again over target is drift rather than a burst.
        if filled > targetSamples * 3 / 2 {
            ring.drop(samples: filled - targetSamples)
        }

        if packetsReceived.isMultiple(of: 20) {
            underruns = underrunCount
            if gaps.count > 10 {
                let sorted = gaps.sorted()
                arrivalJitterP95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            }
            outputLatencyMs = AVAudioSession.sharedInstance().outputLatency * 1000
        }
    }
}
