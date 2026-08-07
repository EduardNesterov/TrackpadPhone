import Foundation
import TrackpadProtocol

/// Ties the system audio tap to the phone.
///
/// Float32 in, Int16 out: the tap delivers float, the wire carries integers because that
/// halves the bandwidth for no audible cost at 16 bits, and the phone's audio engine is
/// happy with either. No compression — see `AudioChunk`.
@available(macOS 14.2, *)
public final class AudioStreamer: @unchecked Sendable {
    public struct Stats: Sendable {
        public var packetsSent = 0
        public var framesDropped = 0
        public var captureBufferMs: Double = 0
        public var sampleRate: Double = 0
    }

    /// Sends every packet twice.
    ///
    /// A lost audio packet cannot be asked for again — by the time the loss is noticed the
    /// moment has passed — so the only defence is to have already sent a spare. At
    /// 1.5 Mbit/s the copy costs nothing on a local network, and it turns isolated loss,
    /// which is what Wi-Fi actually produces, into no loss at all. The phone drops the
    /// copy by sequence number.
    public var sendsRedundantCopies = true

    public private(set) var stats = Stats()
    public var isRunning: Bool { capture != nil }

    private var capture: AudioCapture?
    private let send: (Packet) -> Void
    private var sequence: UInt16 = 0
    /// Left over when a driver buffer does not divide evenly into packets.
    private var pending: [Int16] = []
    private var pendingHostUs: UInt32 = 0

    public init(send: @escaping (Packet) -> Void) {
        self.send = send
    }

    public func start() throws {
        guard capture == nil else { return }
        let capture = AudioCapture()
        capture.onAudio = { [weak self] samples, frames, channels, hostTime in
            self?.handle(samples, frames: frames, channels: channels, hostTime: hostTime)
        }
        try capture.start()
        self.capture = capture

        stats = Stats()
        stats.captureBufferMs = capture.format?.bufferMilliseconds ?? 0
        stats.sampleRate = capture.format?.sampleRate ?? 0
    }

    public func stop() {
        capture?.stop()
        capture = nil
        pending.removeAll()
    }

    // MARK: - Conversion

    private func handle(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, hostTime: UInt64) {
        guard frames > 0, channels > 0 else { return }

        if pending.isEmpty {
            pendingHostUs = UInt32(truncatingIfNeeded: Self.microseconds(fromHostTime: hostTime))
        }
        pending.reserveCapacity(pending.count + frames * 2)

        for frame in 0 ..< frames {
            // Mono is duplicated and anything wider is truncated to the front pair: the
            // phone has two ears and no way to use a centre channel.
            let left = samples[frame * channels]
            let right = channels > 1 ? samples[frame * channels + 1] : left
            pending.append(Self.toInt16(left))
            pending.append(Self.toInt16(right))
        }

        let framesPerPacket = AudioChunk.maxFrames
        while pending.count >= framesPerPacket * 2 {
            let payload = Array(pending.prefix(framesPerPacket * 2))
            pending.removeFirst(framesPerPacket * 2)
            let chunk = AudioChunk(
                seq: sequence, tHostUs: pendingHostUs,
                frameCount: framesPerPacket, samples: payload
            )
            send(.audio(chunk))
            if sendsRedundantCopies { send(.audio(chunk)) }
            sequence &+= 1
            stats.packetsSent += 1
            // Roughly every two seconds at 200 packets/s. Without it there is no way to
            // tell "capturing but not sending" from "not capturing" other than by ear.
            if stats.packetsSent.isMultiple(of: 400) {
                print("audio: \(stats.packetsSent) packets sent")
            }
            // The remainder belongs to a later instant; advance the stamp with it.
            pendingHostUs &+= UInt32(Double(framesPerPacket) / max(stats.sampleRate, 1) * 1_000_000)
        }
    }

    /// Clamped, not wrapped. Float audio can exceed ±1 after mixing, and letting that wrap
    /// turns a loud passage into white noise.
    private static func toInt16(_ value: Float) -> Int16 {
        let scaled = max(-1, min(1, value)) * 32767
        return Int16(scaled)
    }

    /// Read once at first use and never written again — the timebase cannot change while
    /// the machine is running.
    private nonisolated(unsafe) static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func microseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        hostTime * UInt64(timebase.numer) / UInt64(timebase.denom) / 1000
    }
}
