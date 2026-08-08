import Foundation
import Network
import TrackpadProtocol

/// UDP listener: finds the phone, proves it is the phone, and hands its packets on.
///
/// Everything runs on `queue`, so the mutable state below is single-threaded despite
/// the class being handed to Network's callbacks.
public final class Receiver: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case listening
        case connected
        case failed(String)
    }

    /// Reported on the receiver's queue; the menu bar hops to the main actor itself.
    public var onStatus: (@Sendable (Status) -> Void)?
    /// Per-second throughput line. Wanted by the command-line tool, noise in an app.
    public var logsStatistics = true

    /// Starts using a pairing secret, or stops when handed nil.
    ///
    /// A method rather than a property because everything here lives on `queue`, and a
    /// getter that hopped onto it would deadlock the first time the queue asked itself.
    public func usePairing(secret: Data?) {
        queue.async { self.channel = secret.map { SecureChannel(secret: $0, role: .mac) } }
    }

    /// Whether an unsealed packet is still accepted.
    ///
    /// Off while the phone is being brought across, because the Mac cannot be updated and
    /// the phone left behind: on a machine whose only pointer *is* this app, a pairing that
    /// fails the first time would leave nobody able to click the menu that fixes it. The
    /// user turns it on once they have seen the phone connect paired, and from then on the
    /// port answers to nobody else.
    public func setRequiresPairing(_ required: Bool) {
        queue.async { self.pairingRequired = required }
    }

    /// Turns the per-event log on and off while running.
    ///
    /// Through the queue because that is where the session is read from, and off by default
    /// because it is not free: a line per recognised event is a synchronous write about a
    /// hundred and twenty times a second, and everything behind it in the queue waits for
    /// the filesystem. Wanted while hunting a gesture, paid for the rest of the time.
    public func setDebugLogging(_ enabled: Bool) {
        queue.async { self.session.debug = enabled }
    }

    private var channel: SecureChannel?
    private var pairingRequired = false
    private var lastRefusalLoggedMs: Double = -.infinity

    /// Bonjour instance name, so the phone can tell one Mac from another and find it again
    /// after its address changes. The pairing code carries the same name.
    public var serviceName: String = Host.current().localizedName ?? "Mac"

    private let queue: DispatchQueue
    private let session: Session
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Where to send feedback. One phone at a time, so the most recent sender is it.
    private var replyTo: NWConnection?

    public init(session: Session, port: UInt16, queue: DispatchQueue) {
        self.session = session
        self.port = NWEndpoint.Port(rawValue: port)!
        self.queue = queue
    }

    public func start() throws {
        session.onFeedback = { [weak self] feedback in
            guard let self, let connection = self.replyTo else { return }
            connection.send(content: self.wrap(.feedback(feedback)), completion: .idempotent)
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Peer-to-peer deliberately *off*, and it costs a feature nobody used to buy back
        // one that everybody feels.
        //
        // Turning it on makes the Mac an active participant in AWDL, and an active AWDL
        // participant time-shares the Wi-Fi radio: the chip leaves the router's channel for
        // the peer-to-peer ones and comes back, roughly once a beacon interval. Nothing is
        // lost — the frames queue while it is away and arrive in a burst — but the pointer
        // freezes for that whole absence. Measured: the phone's own clock showed gaps of no
        // more than 25 ms while the Mac saw 90 to 100 ms, once or twice a second, which is
        // exactly what "the cursor moves in jerks" is.
        //
        // What it gives up is working with no router at all, phone straight to Mac. That
        // has never been used here: both ends are on the same network, and Bonjour
        // advertising works over it without any of this.
        params.includePeerToPeer = false

        let listener = try NWListener(using: params, on: port)
        // Advertised rather than left to be typed: the Mac's address is the router's to
        // change, and a phone that has been paired should not have to be told about it.
        listener.service = NWListener.Service(name: serviceName, type: PairingCode.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection)
            print("peer connected: \(connection.endpoint)")
            self.onStatus?(.connected)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("listening on udp/\(self.port.rawValue)")
                self.onStatus?(.listening)
            case .failed(let error):
                // Never exit() from here. This is a library, and in the menu bar app that
                // would kill the host process instead of surfacing a recoverable error.
                print("listener failed: \(error)")
                self.onStatus?(.failed(error.localizedDescription))
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        startStatsTimer()
        startTickTimer()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(data, from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        guard let packet = open(data) else { return }

        switch packet {
        case .hello(let hello):
            replyTo = connection
            session.handle(hello)

        case .touchFrame(let frame):
            replyTo = connection
            session.handle(frame, arrivedAtMs: Receiver.nowMs())

        case .keyInput(let key):
            session.handle(key)

        case .feedback:
            break  // Mac never receives these.
        }
    }

    /// Opens a datagram, or decides it is not worth listening to.
    ///
    /// Silence is the entire answer to a packet that fails: a wrong key, a rewritten byte
    /// and a replay are all somebody who is not the paired phone, and there is nothing to
    /// say to them. Malformed rubbish is expected anyway on an open UDP port.
    private func open(_ data: Data) -> Packet? {
        if let channel {
            do {
                return try channel.open(data)
            } catch ChannelError.notSealed {
                // An unpaired phone. The rule below decides whether to hear it.
            } catch {
                // The one failure with no symptom to look at: everything is running, the
                // packets arrive, and the pointer does not move. Said once a second so a
                // flood cannot bury the rest of the log.
                let now = Receiver.nowMs()
                if now - lastRefusalLoggedMs > 1000 {
                    lastRefusalLoggedMs = now
                    print("refused a packet: \(error). Re-scan the pairing code on the phone.")
                }
                return nil
            }
        }
        guard !pairingRequired else { return nil }
        return try? Packet.decode(data)
    }

    /// Seals a reply when there is a channel, and sends it plainly when there is not — so
    /// haptics keep working through the changeover in both directions.
    private func wrap(_ packet: Packet) -> Data {
        channel.map { $0.seal(packet) } ?? packet.encode()
    }

    private static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// Gives the recogniser a clock of its own.
    ///
    /// The phone sends only while it is being touched, so anything that has to keep running
    /// without fresh frames rides on this: the drag's re-grab window, which must expire on
    /// an empty surface, and the edge push, which must glide while the fingers hold still.
    ///
    /// 120 Hz because the push turns into visible steps at anything slower, and the elapsed
    /// time is *measured* rather than assumed — a timer that fires late still moves the
    /// pointer by what the nominal interval said, and that irregularity is exactly what a
    /// glide shows up as stutter.
    private func startTickTimer() {
        let interval = 1.0 / 120
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Receiver.nowMs()
            let elapsed = min((now - (self.lastTickMs ?? now - interval * 1000)) / 1000, 0.1)
            self.lastTickMs = now
            self.session.tick(elapsed: elapsed)
        }
        timer.resume()
        tickTimer = timer
    }

    private var tickTimer: DispatchSourceTimer?
    private var lastTickMs: Double?

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.session.endDragIfPhoneWentAway(nowMs: Receiver.nowMs())
            let stats = self.session.drainStats()
            guard self.logsStatistics, stats.frames > 0 else { return }
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
            }
            // p99 as well as p95, because a stall that happens twice a second is under two
            // per cent of the frames — invisible at p95, and the whole of what the hand
            // feels. Sensor beside arrival, so a stall names its own culprit.
            print(String(
                format: "%4d fps   arrival p50 %5.1f  p95 %5.1f  p99 %6.1f   sensor p50 %5.1f  p99 %6.1f   lost %d   discarded %d",
                stats.frames,
                percentile(stats.interArrivalMs, 0.5),
                percentile(stats.interArrivalMs, 0.95),
                percentile(stats.interArrivalMs, 0.99),
                percentile(stats.sensorGapMs, 0.5),
                percentile(stats.sensorGapMs, 0.99),
                stats.lost, stats.discarded
            ))
        }
        timer.resume()
        statsTimer = timer
    }

    private var statsTimer: DispatchSourceTimer?
}
