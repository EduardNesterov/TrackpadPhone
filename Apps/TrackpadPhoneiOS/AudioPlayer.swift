import AVFoundation
import TrackpadProtocol

/// Plays the Mac's audio, and measures what it costs to do so.
///
/// This is a spike, and its job is a number rather than a feature. There is **no jitter
/// buffer and no clock correction here on purpose**: those are the expensive parts, and
/// building them before knowing the latency would be building on an unmeasured foundation
/// — the same mistake M0 existed to avoid.
///
/// So expect it to click, and expect it to drift apart over minutes. What it reports is the
/// real budget: how long the Mac's capture buffer is, how unevenly packets actually arrive,
/// and what iOS charges for output. Those decide whether video is even worth attempting.
@Observable
@MainActor
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var packetsReceived = 0
    private(set) var packetsLost = 0
    /// Spread of packet arrival times. This is the number that sets the jitter buffer, and
    /// therefore most of the latency — a 5 ms stream arriving 40 ms apart needs 40 ms of
    /// slack whatever else is done.
    private(set) var arrivalJitterP95Ms: Double = 0
    private(set) var outputLatencyMs: Double = 0
    private(set) var queuedMs: Double = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var lastSeq: UInt16?
    private var lastArrival: Double?
    private var gaps: [Double] = []
    private var scheduledFrames = 0

    func start(sampleRate: Double = 48000) {
        guard !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback so it keeps going with the ringer switch off — this is the point of
            // the feature, not an alert sound.
            try session.setCategory(.playback, mode: .default)
            // Ask for a small buffer. iOS treats it as a hint, and the granted value shows
            // up in `outputLatency` below, which is what gets reported rather than the ask.
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            outputLatencyMs = session.outputLatency * 1000

            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: 2, interleaved: false)
            self.format = format
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isPlaying = false
        scheduledFrames = 0
        queuedMs = 0
    }

    func resetStats() {
        packetsReceived = 0
        packetsLost = 0
        gaps.removeAll()
        arrivalJitterP95Ms = 0
    }

    func play(_ chunk: AudioChunk) {
        // Started by the first packet rather than by a button: the Mac decides when the
        // stream exists, and a second switch on the phone would only be another thing to
        // forget. 48 kHz is assumed — the Mac reports its actual rate in the menu, so a
        // mismatch would be visible rather than mysterious.
        if !isPlaying { start() }
        guard isPlaying, let format else { return }

        let now = CACurrentMediaTime() * 1000
        if let previous = lastArrival {
            let gap = now - previous
            if gap < 500 { gaps.append(gap) }
            if gaps.count > 400 { gaps.removeFirst(gaps.count - 400) }
        }
        lastArrival = now

        if let last = lastSeq {
            let missing = Int(chunk.seq &- last) - 1
            if missing > 0, missing < 100 { packetsLost += missing }
        }
        lastSeq = chunk.seq
        packetsReceived += 1

        if packetsReceived.isMultiple(of: 20), gaps.count > 10 {
            let sorted = gaps.sorted()
            arrivalJitterP95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            outputLatencyMs = AVAudioSession.sharedInstance().outputLatency * 1000
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(chunk.frameCount)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)

        for frame in 0 ..< chunk.frameCount {
            channels[0][frame] = Float(chunk.samples[frame * 2]) / 32767
            channels[1][frame] = Float(chunk.samples[frame * 2 + 1]) / 32767
        }

        scheduledFrames += chunk.frameCount
        queuedMs = Double(scheduledFrames) / format.sampleRate * 1000
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledFrames = max(0, self.scheduledFrames - chunk.frameCount)
                self.queuedMs = Double(self.scheduledFrames) / format.sampleRate * 1000
            }
        }
    }
}
