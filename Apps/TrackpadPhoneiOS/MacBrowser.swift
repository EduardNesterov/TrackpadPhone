import Network
import Observation
import TrackpadProtocol

/// Finds Macs advertising the service, so the phone can connect to one by name.
///
/// This exists for more than convenience. Connecting to a Bonjour *endpoint* rather than to
/// an IP address is the only way Network.framework will put the link on AWDL — Apple's
/// peer-to-peer Wi-Fi, the one AirDrop uses — which goes directly between the two devices
/// instead of out to the access point and back. Typing an address always routes through the
/// router, whatever `includePeerToPeer` is set to.
///
/// Whether the direct path is actually better here is an open question worth measuring:
/// it removes the router hop and the contention with everyone else on the network, but the
/// radio has to time-share between the AWDL channel and the access point's, and that
/// hopping is itself a source of periodic jitter.
@Observable
@MainActor
final class MacBrowser {
    struct Found: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }

    private(set) var results: [Found] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.udp
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: bonjourServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] found, _ in
            Task { @MainActor in
                self?.results = found.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Found(name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        results = []
    }
}
