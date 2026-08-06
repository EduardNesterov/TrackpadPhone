import CoreGraphics
import Foundation
import TrackpadProtocol

/// Interprets one phone's frame stream. All the "what did the finger mean" logic lives
/// on this side by design — see docs/ARCHITECTURE.md §1.
///
/// M0 recognises exactly two things: single-finger tracking and a tap. Scroll, drag and
/// multi-finger gestures are M2/M3, and faking them here would just produce numbers we'd
/// have to throw away.
final class Session {
    private let pointer: Pointer

    private var surfaceWidthMM: Double = 70
    private var surfaceHeightMM: Double = 150
    private var sessionID: UInt32?

    private var lastSeq: UInt16?
    private var lastTimeUs: UInt32?
    private var primary: (id: UInt8, x: Float, y: Float)?

    // Tap detection, in the phone's own time base.
    private var downTimeUs: UInt32?
    private var travelMM: Double = 0

    private let tapMaxDurationUs: UInt32 = 250_000
    private let tapMaxTravelMM: Double = 2.0

    private(set) var stats = Stats()

    struct Stats {
        var frames = 0
        /// Frames we threw away on purpose: duplicates and out-of-order arrivals. Healthy.
        var discarded = 0
        /// Gaps in the sequence space — frames that never arrived. This is the number
        /// that says something about the network, and it must not be mixed with the above.
        var lost = 0
        var interArrivalMs: [Double] = []
    }

    init(pointer: Pointer) {
        self.pointer = pointer
    }

    func handle(_ hello: Hello) {
        // A new session ID means the phone app restarted and tSensorUs went back to zero.
        // Everything derived from the old timeline has to go.
        if sessionID != hello.sessionID {
            lastSeq = nil
            lastTimeUs = nil
            primary = nil
            downTimeUs = nil
            sessionID = hello.sessionID
            pointer.resync()
        }
        surfaceWidthMM = Double(hello.surfaceWidthMM)
        surfaceHeightMM = Double(hello.surfaceHeightMM)
        print(String(
            format: "hello: session %08x, surface %.1f × %.1f mm, up to %d contacts",
            hello.sessionID, hello.surfaceWidthMM, hello.surfaceHeightMM, hello.maxContacts
        ))
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
        if let previousArrival = lastArrivalMs {
            let gap = arrivedAtMs - previousArrival
            // Gaps past half a second are the user's finger resting, not network jitter.
            // Counting them would make the percentiles meaningless.
            if gap < 500 { stats.interArrivalMs.append(gap) }
        }
        lastArrivalMs = arrivedAtMs

        // Wrapping subtraction: u32 microseconds roll over every 71 minutes, and a
        // session can outlive that. Frame gaps never approach it, so `&-` is exact.
        let dt: Double
        if let last = lastTimeUs {
            dt = Double(frame.tSensorUs &- last) / 1_000_000
        } else {
            dt = 0
        }
        lastTimeUs = frame.tSensorUs

        switch frame.contacts.count {
        case 1:
            track(frame.contacts[0], dt: dt, tUs: frame.tSensorUs)
        case 0:
            liftAll(tUs: frame.tSensorUs)
        default:
            // Two or more fingers: no cursor motion. Scroll lands at M2.
            primary = nil
            downTimeUs = nil
        }
        return true
    }

    private var lastArrivalMs: Double?

    private func track(_ contact: Contact, dt: Double, tUs: UInt32) {
        defer { primary = (contact.id, contact.x, contact.y) }

        guard let previous = primary, previous.id == contact.id else {
            // A fresh finger. Start a possible tap and re-read where the cursor really is.
            downTimeUs = tUs
            travelMM = 0
            pointer.resync()
            return
        }

        let deltaMM = CGPoint(
            x: Double(contact.x - previous.x) * surfaceWidthMM,
            y: Double(contact.y - previous.y) * surfaceHeightMM
        )
        travelMM += hypot(deltaMM.x, deltaMM.y)
        pointer.move(deltaMM: deltaMM, dt: dt)
    }

    private func liftAll(tUs: UInt32) {
        if let down = downTimeUs,
           tUs &- down < tapMaxDurationUs,
           travelMM < tapMaxTravelMM {
            pointer.click()
        }
        downTimeUs = nil
        primary = nil
    }

    func drainStats() -> Stats {
        defer { stats = Stats() }
        return stats
    }
}
