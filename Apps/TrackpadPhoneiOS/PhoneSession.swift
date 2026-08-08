import Foundation
import Network
import Observation
import QuartzCore
import TrackpadProtocol
import UIKit

/// Owns the link to the Mac: who it is, where it is, and the sealed channel to it.
///
/// Three things that used to be one typed address. *Who* comes from the QR code, and is a
/// shared secret rather than a name — the Mac refuses anything that cannot prove it holds
/// the same one. *Where* comes from Bonjour, because an address is the router's to change
/// and a phone that has been paired should never have to be told about it again. The
/// addresses from the code are kept only as a fallback for networks that filter mDNS.
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

    /// The Mac this phone is paired with, or nil while it is paired with none.
    private(set) var pairedName: String?
    var isPaired: Bool { pairedName != nil }

    /// Whether the Mac has said anything lately.
    ///
    /// Not the same question as `state`, and the difference is the whole point: UDP has no
    /// session, so a socket reports itself ready whether or not anything is listening at the
    /// far end — doubly so on the fallback path, where the address is one we were told about
    /// once and nobody has confirmed since. `state` says a socket is open. This says the Mac
    /// is there. Only the second one is worth a green dot.
    private(set) var isLive = false

    /// When the Mac last answered. Every packet from it counts, but in practice it is the
    /// answer to `hello`, twice a second's worth of silence apart.
    private var lastHeardAt: Date?
    private var lastAttemptAt = Date.distantPast
    private var watchdog: Timer?

    /// Silence this long means the link is gone, whatever the socket believes. Three missed
    /// answers: long enough to ride out one lost packet and a slow moment, short enough that
    /// a hand reaching for the trackpad finds it already reconnected.
    private static let silenceMeansGone: TimeInterval = 6
    /// And how often to try again while it stays gone. Cheap — a few packets — but no point
    /// hammering a Mac that is switched off.
    private static let retryEvery: TimeInterval = 5

    /// Persisted so the choice survives a relaunch; haptics are polarising enough to be
    /// worth a switch rather than a decision made for the user.
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey)
            haptics.isEnabled = hapticsEnabled
        }
    }

    /// Multiplies every buzz. Kept on the phone rather than the Mac because it is about
    /// how this handset feels in this hand, not about what happened on the desktop.
    var hapticStrength: Double {
        didSet {
            UserDefaults.standard.set(hapticStrength, forKey: Self.hapticStrengthKey)
            haptics.strength = hapticStrength
        }
    }

    private let haptics = Haptics()

    private static let hapticsKey = "trackpadphone.haptics"
    private static let hapticStrengthKey = "trackpadphone.hapticStrength"
    private static let nameKey = "trackpadphone.macName"
    private static let addressesKey = "trackpadphone.macAddresses"
    private static let portKey = "trackpadphone.macPort"
    private static let defaultPort: UInt16 = 51888

    /// Overridable the same way as the host, so a second receiver can be tested without
    /// disturbing one already running: `-trackpadphone.port 51889`.
    private static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "trackpadphone.port")
        return stored > 0 && stored <= 65535 ? UInt16(stored) : defaultPort
    }

    private let queue = DispatchQueue(label: "trackpadphone.sender")
    private let pairing = PairingStore()
    /// Nil only when nothing is paired; every packet goes through it otherwise.
    private var channel: SecureChannel?
    private var connection: NWConnection?
    private var helloTimer: Timer?
    /// Fires when Bonjour has had long enough. See `connect()`.
    private var fallbackTask: Task<Void, Never>?
    private var sequence: UInt16 = 0
    private let sessionID = UInt32.random(in: .min ... .max)
    private let startedAt = CACurrentMediaTime()

    private var lastContactCount = 0

    init() {
        pairedName = UserDefaults.standard.string(forKey: Self.nameKey)
        hapticsEnabled = UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true
        hapticStrength = UserDefaults.standard.object(forKey: Self.hapticStrengthKey) as? Double ?? 1.0
        haptics.isEnabled = hapticsEnabled
        haptics.strength = hapticStrength
        // Starting the engine up front matters: the first pattern on a cold engine is
        // late by tens of milliseconds, which is exactly the click you most want to feel.
        haptics.start()
        startWatchdog()
    }

    /// Reconnects when the link has gone quiet, and keeps `isLive` honest.
    ///
    /// This is what makes pairing a one-time thing rather than something to redo whenever
    /// the app has been in the background. iOS tears the connection down while the app is
    /// suspended and nothing brings it back on its own; before this, re-scanning the code
    /// was the shortest route back — which is why pairing looked like it kept falling off.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTheLinkIsAlive() }
        }
    }

    private func checkTheLinkIsAlive() {
        let silence = lastHeardAt.map { Date().timeIntervalSince($0) } ?? .infinity
        isLive = silence < Self.silenceMeansGone

        guard isPaired, !isLive else { return }
        guard Date().timeIntervalSince(lastAttemptAt) >= Self.retryEvery else { return }
        connect()
    }

    private func nowMicroseconds() -> UInt32 {
        UInt32(truncatingIfNeeded: Int((CACurrentMediaTime() - startedAt) * 1_000_000))
    }

    // MARK: - Connection

    /// Pairs with a scanned code and connects straight away.
    ///
    /// The secret goes to the Keychain, the rest to defaults: only the secret is worth
    /// protecting, and a name and an address are worth being able to read when something
    /// does not work.
    func pair(with code: PairingCode) {
        pairing.save(code.secret)
        pairedName = code.serviceName
        UserDefaults.standard.set(code.serviceName, forKey: Self.nameKey)
        UserDefaults.standard.set(code.addresses, forKey: Self.addressesKey)
        UserDefaults.standard.set(Int(code.port), forKey: Self.portKey)
        connect()
    }

    func unpair() {
        disconnect()
        pairing.clear()
        pairedName = nil
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.addressesKey)
    }

    func connect() {
        disconnect()
        lastAttemptAt = Date()
        // Cleared rather than kept: an old answer must not make a fresh connection look
        // alive before the Mac has said anything through it.
        lastHeardAt = nil
        isLive = false
        guard let secret = pairing.load(), let name = pairedName else {
            state = .failed("scan the code on your Mac")
            return
        }
        channel = SecureChannel(secret: secret, role: .phone)
        state = .connecting

        // By name, not by address: Network.framework resolves the Bonjour service itself
        // and follows it when the Mac's address changes, which is the entire reason the
        // address field is gone.
        open(to: .service(
            name: name, type: PairingCode.bonjourType, domain: "local.", interface: nil
        ))

        // mDNS is filtered on some networks — office Wi-Fi especially — and there the
        // resolution above never completes and never fails either. So the addresses from
        // the code get their turn if nothing has come up by then.
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.state != .connected else { return }
            self.connectToStoredAddress()
        }
    }

    private func connectToStoredAddress() {
        let addresses = UserDefaults.standard.stringArray(forKey: Self.addressesKey) ?? []
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        guard let first = addresses.first,
              let port = NWEndpoint.Port(rawValue: UInt16(stored > 0 ? stored : Int(Self.port)))
        else { return }
        open(to: .hostPort(host: NWEndpoint.Host(first), port: port))
    }

    private func open(to endpoint: NWEndpoint) {
        connection?.cancel()
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)

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
        fallbackTask?.cancel()
        fallbackTask = nil
        helloTimer?.invalidate()
        helloTimer = nil
        connection?.cancel()
        connection = nil
        state = .idle
    }

    /// Plays a click on demand, so the strength slider can be judged while dragging it
    /// instead of by putting the phone down and tapping.
    func previewHaptic() {
        haptics.play(Feedback(kind: .click, intensity: 255))
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
        guard state == .connected else { return }
        let tUs = UInt32(truncatingIfNeeded: Int((timestamp - startedAt) * 1_000_000))
        let frame = TouchFrame(seq: sequence, tSensorUs: tUs, contacts: contacts)
        sequence &+= 1
        send(.touchFrame(frame))

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

    func send(_ key: KeyInput) {
        guard state == .connected else { return }
        // Sent once, deliberately, unlike hello. Keystrokes carry no sequence number and
        // the Mac has no way to recognise a repeat, so a redundant copy would type the
        // character twice — and a doubled letter is a worse failure than a missed one,
        // because the user cannot tell it was the network. Reliability here belongs on
        // the control channel that M1 will bring, not in blind repetition.
        send(.keyInput(key))
    }

    private func send(_ packet: Packet) {
        guard let channel else { return }
        connection?.send(content: channel.seal(packet), completion: .idempotent)
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
        guard let channel, let packet = try? channel.open(data) else { return }
        // Anything at all from the Mac is proof it is there; it cannot be forged, because
        // it came through the sealed channel.
        lastHeardAt = Date()
        isLive = true
        if case .feedback(let feedback) = packet { haptics.play(feedback) }
    }
}
