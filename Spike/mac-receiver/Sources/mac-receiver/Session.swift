import Foundation
import TrackpadInput
import TrackpadProtocol

/// One phone's stream: frames in, system events out.
///
/// Deliberately thin. Deciding what fingers mean lives in `GestureRecognizer` and turning
/// that into events lives in `EventSynthesizer`; this only guards the sequence numbers and
/// keeps the statistics honest.
final class Session {
    private let recognizer: GestureRecognizer
    private let synthesizer: EventSynthesizer

    private var sessionID: UInt32?
    private var lastSeq: UInt16?
    private var lastArrivalMs: Double?

    private(set) var stats = Stats()

    struct Stats {
        var frames = 0
        /// Frames thrown away on purpose: duplicates and out-of-order arrivals. Healthy.
        var discarded = 0
        /// Gaps in the sequence space — frames that never arrived. This is the number that
        /// says something about the network, and it must not be mixed with the above.
        var lost = 0
        var interArrivalMs: [Double] = []
    }

    init(recognizer: GestureRecognizer, synthesizer: EventSynthesizer) {
        self.recognizer = recognizer
        self.synthesizer = synthesizer
    }

    func handle(_ hello: Hello) {
        recognizer.surface = SurfaceGeometry(
            widthMM: Double(hello.surfaceWidthMM),
            heightMM: Double(hello.surfaceHeightMM)
        )
        // A new session ID means the phone app restarted and tSensorUs went back to zero.
        // Everything derived from the old timeline has to go.
        if sessionID != hello.sessionID {
            sessionID = hello.sessionID
            lastSeq = nil
            recognizer.reset()
            synthesizer.resync()
            print(String(
                format: "hello: session %08x, surface %.1f × %.1f mm, up to %d contacts",
                hello.sessionID, hello.surfaceWidthMM, hello.surfaceHeightMM, hello.maxContacts
            ))
        }
    }

    /// - Returns: false if the frame was a duplicate or arrived out of order.
    @discardableResult
    func handle(_ frame: TouchFrame, arrivedAtMs: Double) -> Bool {
        if let last = lastSeq, !isNewer(frame.seq, than: last) {
            stats.discarded += 1
            return false
        }
        if let last = lastSeq {
            let gap = Int(frame.seq &- last) - 1
            // A huge jump means the sender restarted its counter, not that we lost 30k
            // frames. Don't let that poison the loss figure.
            stats.lost += gap > 0 && gap < 1000 ? gap : 0
        }
        lastSeq = frame.seq
        stats.frames += 1

        if let previous = lastArrivalMs {
            let gap = arrivedAtMs - previous
            // Gaps past half a second are the user's finger resting, not network jitter.
            // Counting them would make the percentiles meaningless.
            if gap < 500 { stats.interArrivalMs.append(gap) }
        }
        lastArrivalMs = arrivedAtMs

        for event in recognizer.process(frame) {
            synthesizer.apply(event)
        }
        return true
    }

    func drainStats() -> Stats {
        defer { stats = Stats() }
        return stats
    }
}
