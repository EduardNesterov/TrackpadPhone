import Foundation
import Network
import Observation
import QuartzCore
import TrackpadProtocol
import UIKit

/// Owns the UDP link to the Mac and the round-trip measurement that M0 exists to produce.
///
/// No discovery and no encryption here — that is M1. Typing an IP is also worth keeping
/// afterwards as the fallback for networks where Bonjour is blocked.
@Observable
@MainActor
final class PhoneSession {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Most fingers seen during the current or most recent gesture.
    ///
    /// The peak rather than the live count, and it survives lift-off on purpose: while a
    /// gesture is happening your fingers cover the screen and your eyes are on the Mac,
    /// so a live readout is unreadable exactly when it matters. This answers "did the
    /// phone see three fingers?" after the fact.
    private(set) var peakContacts = 0
    private(set) var framesSent = 0
    private(set) var echoesReceived = 0
    private(set) var rttP50Ms: Double = 0
    private(set) var rttP95Ms: Double = 0
    private(set) var rttMaxMs: Double = 0

    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    /// Persisted so the choice survives a relaunch; haptics are polarising enough to be
    /// worth a switch rather than a decision made for the user.
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey)
            haptics.isEnabled = hapticsEnabled
        }
    }

    private let haptics = Haptics()

    private static let hapticsKey = "trackpadphone.haptics"
    private static let hostKey = "trackpadphone.host"
    private static let defaultPort: UInt16 = 51888

    /// Overridable the same way as the host, so a second receiver can be tested without
    /// disturbing one already running: `-trackpadphone.port 51889`.
    private static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "trackpadphone.port")
        return stored > 0 && stored <= 65535 ? UInt16(stored) : defaultPort
    }

    private let queue = DispatchQueue(label: "trackpadphone.sender")
    private var connection: NWConnection?
    private var helloTimer: Timer?
    private var sequence: UInt16 = 0
    private let sessionID = UInt32.random(in: .min ... .max)
    private let startedAt = CACurrentMediaTime()

    /// Last 300 samples, about 2.5 seconds of finger movement — recent enough to reflect
    /// the network as it is right now rather than an average over the whole session.
    private var rtts: [Double] = []
    private var lastContactCount = 0

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        hapticsEnabled = UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true
        haptics.isEnabled = hapticsEnabled
        // Starting the engine up front matters: the first pattern on a cold engine is
        // late by tens of milliseconds, which is exactly the click you most want to feel.
        haptics.start()
    }

    private func nowMicroseconds() -> UInt32 {
        UInt32(truncatingIfNeeded: Int((CACurrentMediaTime() - startedAt) * 1_000_000))
    }

    // MARK: - Connection

    func connect() {
        disconnect()
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let port = NWEndpoint.Port(rawValue: Self.port) else {
            state = .failed("enter the Mac's address")
            return
        }

        state = .connecting
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: port, using: params)

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .connected
                    self.sendHello()
                    self.startHelloTimer()
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    self.state = .idle
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive(on: connection)
    }

    func disconnect() {
        helloTimer?.invalidate()
        helloTimer = nil
        connection?.cancel()
        connection = nil
        state = .idle
    }

    func resetStats() {
        rtts.removeAll()
        framesSent = 0
        echoesReceived = 0
        rttP50Ms = 0
        rttP95Ms = 0
        rttMaxMs = 0
    }

    /// The Mac needs the size of the *touch surface*, not the screen — they differ once
    /// there is any chrome around it. Called on layout, so rotation re-announces.
    func updateSurface(points: CGSize, scale: CGFloat) {
        let mm = DeviceSurface.millimetres(forPoints: points, scale: scale)
        guard mm != surfaceMM else { return }
        surfaceMM = mm
        if state == .connected { sendHello() }
    }

    private var surfaceMM = CGSize(width: 70, height: 150)

    /// Repeats `hello` while connected.
    ///
    /// UDP has no session, so restarting the Mac receiver is invisible to the phone: it
    /// keeps sending frames to a listener that never learned the surface size and is
    /// therefore measuring every gesture in the wrong scale. Re-announcing costs 15 bytes
    /// every couple of seconds and makes a receiver restart heal itself.
    private func startHelloTimer() {
        helloTimer?.invalidate()
        helloTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .connected else { return }
                self.sendHello()
            }
        }
    }

    private func sendHello() {
        let hello = Hello(
            sessionID: sessionID,
            surfaceWidthMM: Float(surfaceMM.width),
            surfaceHeightMM: Float(surfaceMM.height),
            maxContacts: 5
        )
        // UDP gives no delivery guarantee and everything downstream depends on this
        // arriving, so say it three times.
        for _ in 0 ..< 3 {
            send(.hello(hello))
        }
    }

    // MARK: - Frames

    func send(contacts: [Contact], timestamp: TimeInterval) {
        if lastContactCount == 0, contacts.count > 0 {
            peakContacts = contacts.count  // new gesture: start counting again
        } else if contacts.count > peakContacts {
            peakContacts = contacts.count
        }
        guard state == .connected else { return }
        let tUs = UInt32(truncatingIfNeeded: Int((timestamp - startedAt) * 1_000_000))
        let frame = TouchFrame(seq: sequence, tSensorUs: tUs, contacts: contacts)
        sequence &+= 1
        send(.touchFrame(frame))
        framesSent += 1

        // A lost touch-down or touch-up is the one loss a snapshot protocol cannot paper
        // over, so repeat any frame where the contact count changed. 50 bytes is cheap.
        if contacts.count != lastContactCount {
            let repeated = TouchFrame(
                seq: frame.seq, tSensorUs: frame.tSensorUs, flags: .redundant, contacts: contacts
            )
            send(.touchFrame(repeated))
            send(.touchFrame(repeated))
            lastContactCount = contacts.count
        }
    }

    private func send(_ packet: Packet) {
        connection?.send(content: packet.encode(), completion: .idempotent)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                Task { @MainActor in self.handle(data) }
            }
            if error == nil {
                Task { @MainActor in self.receive(on: connection) }
            }
        }
    }

    private func handle(_ data: Data) {
        switch try? Packet.decode(data) {
        case .feedback(let feedback):
            haptics.play(feedback)
            return
        case .echoReply(let echo):
            recordRoundTrip(echo)
        default:
            return
        }
    }

    private func recordRoundTrip(_ echo: EchoReply) {
        // Both timestamps are on this device's clock, which is why the phone owns the
        // measurement — no clock sync with the Mac is needed or attempted.
        let rtt = Double(nowMicroseconds() &- echo.tSensorUs) / 1000
        guard rtt >= 0, rtt < 5000 else { return }

        echoesReceived += 1
        rtts.append(rtt)
        if rtts.count > 300 { rtts.removeFirst(rtts.count - 300) }

        // Percentiles are for the eyes only; recompute a few times a second, not 120.
        if echoesReceived % 10 == 0 {
            let sorted = rtts.sorted()
            rttP50Ms = sorted[sorted.count / 2]
            rttP95Ms = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            rttMaxMs = sorted[sorted.count - 1]
        }
    }
}
