import Foundation

/// What the QR code on the Mac's screen carries.
///
/// A URL rather than a packed blob, because this is the one part of the protocol a human
/// ever has to look at: when pairing does not work, being able to read the thing off a
/// screen and see which address it names is worth the extra bytes. A QR holds a couple of
/// thousand characters and this is under two hundred.
///
/// The addresses are a hint, not the mechanism. Discovery is Bonjour — the Mac's address
/// changes with the router's mood, and a code that pinned it would have to be rescanned
/// every time. They exist for the first connection and for networks where mDNS is filtered.
public struct PairingCode: Sendable, Equatable {
    /// The shared secret, 32 bytes. Everything on the wire is authenticated with it.
    public var secret: Data
    /// The Bonjour instance name, so a phone can tell one Mac from another.
    public var serviceName: String
    public var addresses: [String]
    public var port: UInt16

    public init(secret: Data, serviceName: String, addresses: [String], port: UInt16) {
        self.secret = secret
        self.serviceName = serviceName
        self.addresses = addresses
        self.port = port
    }

    public static let scheme = "trackpadphone"
    public static let secretByteCount = 32
    /// What the Mac advertises and the phone resolves. Lives here rather than beside the
    /// listener because the phone needs the same string and cannot import the Mac's half.
    public static let bonjourType = "_trackpadphone._udp"

    public var url: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems =
            [
                URLQueryItem(name: "v", value: "1"),
                URLQueryItem(name: "k", value: secret.base64EncodedString()),
                URLQueryItem(name: "n", value: serviceName),
                URLQueryItem(name: "p", value: String(port)),
            ] + addresses.map { URLQueryItem(name: "a", value: $0) }
        return components.url?.absoluteString ?? ""
    }

    public init?(url: String) {
        guard let components = URLComponents(string: url),
              components.scheme == Self.scheme,
              components.host == "pair",
              let items = components.queryItems else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard value("v") == "1",
              let encoded = value("k"),
              // `base64EncodedString` produces `+` and `/`, and a query strips nothing —
              // but a code copied through something that decodes `+` as a space would
              // arrive broken, so put it back rather than fail on it.
              let secret = Data(base64Encoded: encoded.replacingOccurrences(of: " ", with: "+")),
              secret.count == Self.secretByteCount,
              let name = value("n"),
              let port = UInt16(value("p") ?? "") else { return nil }

        self.init(
            secret: secret,
            serviceName: name,
            addresses: items.filter { $0.name == "a" }.compactMap(\.value),
            port: port
        )
    }
}
