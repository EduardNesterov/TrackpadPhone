import Foundation
import Network
import TrackpadProtocol

/// UDP listener. No discovery, no encryption, no pairing — M0 exists to produce a
/// latency number, and each of those would only add ways for it to fail.
///
/// Everything runs on `queue`, so the mutable state below is single-threaded despite
/// the class being handed to Network's callbacks.
final class Receiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "trackpadphone.receiver")
    private let session: Session
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init(session: Session, port: UInt16) {
        self.session = session
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
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
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("listening on udp/\(self.port.rawValue)")
            case .failed(let error):
                print("listener failed: \(error)")
                exit(1)
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

        case .echoReply:
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
            let stats = self.session.drainStats()
            guard stats.frames > 0 else { return }
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
