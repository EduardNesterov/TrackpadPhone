import Foundation
import Network
import TrackpadProtocol

/// UDP listener. No discovery, no encryption, no pairing yet — that is M1.
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
            connection.send(content: Packet.feedback(feedback).encode(), completion: .idempotent)
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Enables AWDL, so this works over direct peer-to-peer Wi-Fi with no router.
        params.includePeerToPeer = true

        let listener = try NWListener(using: params, on: port)
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
        let packet: Packet
        do {
            packet = try Packet.decode(data)
        } catch {
            // Malformed input is expected on an open UDP port; drop it and move on.
            return
        }

        switch packet {
        case .hello(let hello):
            session.handle(hello)

        case .touchFrame(let frame):
            replyTo = connection
            let accepted = session.handle(frame, arrivedAtMs: Receiver.nowMs())
            if accepted {
                // Bounce the frame's identity straight back. The phone owns the RTT
                // measurement because only it has both timestamps on one clock.
                let reply = Packet.echoReply(EchoReply(
                    seq: frame.seq,
                    tSensorUs: frame.tSensorUs,
                    tServerUs: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
                ))
                connection.send(content: reply.encode(), completion: .idempotent)
            }

        case .keyInput(let key):
            session.handle(key)

        case .echoReply, .feedback:
            break  // Mac never receives these.
        }
    }

    private static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.session.endDragIfPhoneWentAway(nowMs: Receiver.nowMs())
            let stats = self.session.drainStats()
            guard self.logsStatistics, stats.frames > 0 else { return }
            let gaps = stats.interArrivalMs.sorted()
            let p50 = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            let p95 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
            print(String(
                format: "%4d fps   gap p50 %5.1f ms   p95 %5.1f ms   lost %d   discarded %d",
                stats.frames, p50, p95, stats.lost, stats.discarded
            ))
        }
        timer.resume()
        statsTimer = timer
    }

    private var statsTimer: DispatchSourceTimer?
}
