import Foundation
import TrackpadInput
import TrackpadProtocol

/// One phone's stream: frames in, system events out.
///
/// Deliberately thin. Deciding what fingers mean lives in `GestureRecognizer` and turning
/// that into events lives in `EventSynthesizer`; this only guards the sequence numbers and
/// keeps the statistics honest.
public final class Session {
    private let recognizer: GestureRecognizer
    private let synthesizer: EventSynthesizer

    private var sessionID: UInt32?
    private var lastSeq: UInt16?
    private var lastArrivalMs: Double?

    public private(set) var stats = Stats()

    public struct Stats {
        var frames = 0
        /// Frames thrown away on purpose: duplicates and out-of-order arrivals. Healthy.
        var discarded = 0
        /// Gaps in the sequence space — frames that never arrived. This is the number that
        /// says something about the network, and it must not be mixed with the above.
        var lost = 0
        var interArrivalMs: [Double] = []
    }

    /// Prints the contact count on every change plus each recognised event. The first
    /// question when a gesture misbehaves is always "how many fingers did the Mac
    /// actually receive", and guessing at it wastes far more time than this costs.
    public var debug = false

    /// Called when something happened that the finger should feel. The Mac is the only
    /// side that knows a click landed, so the decision belongs here — the phone stays the
    /// dumb sensor the architecture calls for.
    public var onFeedback: ((Feedback) -> Void)?
    private var lastContactCount = -1

    private lazy var keyboard = Keyboard(source: synthesizer.source)

    public func handle(_ key: KeyInput) {
        if debug {
            print("\(Self.stamp())  ⌨ code \(key.keyCode) mods \(key.modifiers.rawValue) '\(key.text)'")
        }
        keyboard.apply(key)
    }

    public init(recognizer: GestureRecognizer, synthesizer: EventSynthesizer) {
        self.recognizer = recognizer
        self.synthesizer = synthesizer
    }

    public func handle(_ hello: Hello) {
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
    public func handle(_ frame: TouchFrame, arrivedAtMs: Double) -> Bool {
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

        if debug, frame.contacts.count != lastContactCount {
            lastContactCount = frame.contacts.count
            print("\(Self.stamp())  contacts: \(frame.contacts.count)  ids \(frame.contacts.map(\.id))")
        }

        for event in recognizer.process(frame) {
            if debug { print("\(Self.stamp())  → \(event)") }
            synthesizer.apply(event)
            if let feedback = Self.feedback(for: event) {
                onFeedback?(feedback)
            }
        }
        return true
    }

    /// Zoom is deliberately absent: a pinch emits a step every few millimetres, and
    /// buzzing on each one turns a smooth gesture into a rattle.
    private static func feedback(for event: InputEvent) -> Feedback? {
        switch event {
        case .click:
            return Feedback(kind: .click, intensity: 255)
        case .dragBegan, .dragEnded:
            return Feedback(kind: .click, intensity: 190)
        case .shortcut:
            return Feedback(kind: .gesture, intensity: 255)
        case .move, .scroll, .zoom:
            return nil
        }
    }

    /// Wall-clock stamp on every debug line, so a log can be lined up against what the
    /// user saw happen on screen.
    private static func stamp() -> String {
        let now = Date()
        let seconds = now.timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: now) + String(format: ".%03d", Int(seconds.truncatingRemainder(dividingBy: 1) * 1000))
    }

    public func drainStats() -> Stats {
        defer { stats = Stats() }
        return stats
    }
}
