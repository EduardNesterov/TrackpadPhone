import Foundation
import Testing

@testable import TrackpadProtocol

/// Both ends of one pairing, as they exist in life: two objects that share nothing but the
/// secret and have to agree from there.
private func pair(secret: Data = Data(repeating: 7, count: 32)) -> (phone: SecureChannel, mac: SecureChannel) {
    (SecureChannel(secret: secret, role: .phone), SecureChannel(secret: secret, role: .mac))
}

private let sampleKey = KeyInput(keyCode: 0, modifiers: [], text: "пароль")

@Suite("Secure channel")
struct SecureChannelTests {
    @Test("A sealed packet opens at the other end and comes back unchanged")
    func roundTrip() throws {
        let (phone, mac) = pair()
        let sealed = phone.seal(.keyInput(sampleKey))
        #expect(try mac.open(sealed) == .keyInput(sampleKey))
    }

    /// The reason the whole thing exists: the receiver turns packets into keystrokes, so
    /// anything that cannot prove it holds the secret must not be heard at all.
    @Test("A packet from a different secret is refused")
    func wrongSecretIsRefused() {
        let stranger = SecureChannel(secret: Data(repeating: 9, count: 32), role: .phone)
        let (_, mac) = pair()
        #expect(throws: ChannelError.notAuthentic) {
            try mac.open(stranger.seal(.keyInput(sampleKey)))
        }
    }

    @Test("A single altered byte is refused")
    func tamperingIsRefused() {
        let (phone, mac) = pair()
        var sealed = phone.seal(.keyInput(sampleKey))
        sealed[sealed.count - 5] ^= 0x01
        #expect(throws: ChannelError.notAuthentic) { try mac.open(sealed) }
    }

    /// The header is outside the ciphertext, so it has to be authenticated explicitly. It
    /// is easy to leave it out and never notice: everything still round-trips.
    @Test("Rewriting the counter in the header is refused")
    func headerIsAuthenticated() {
        let (phone, mac) = pair()
        var sealed = phone.seal(.keyInput(sampleKey))
        sealed[10] ^= 0x08
        #expect(throws: ChannelError.notAuthentic) { try mac.open(sealed) }
    }

    @Test("A captured packet cannot be sent twice")
    func replayIsRefused() throws {
        let (phone, mac) = pair()
        let sealed = phone.seal(.click)
        _ = try mac.open(sealed)
        #expect(throws: ChannelError.replayed) { try mac.open(sealed) }
    }

    /// UDP reorders, and the phone deliberately sends duplicate copies of the frames that
    /// matter. A rule of "counters must increase" would throw away exactly that traffic.
    @Test("Packets that arrive out of order are still accepted")
    func reorderingSurvives() throws {
        let (phone, mac) = pair()
        let first = phone.seal(.hello(Hello(sessionID: 1, surfaceWidthMM: 70, surfaceHeightMM: 150, maxContacts: 5)))
        let second = phone.seal(.click)
        let third = phone.seal(.click)

        _ = try mac.open(third)
        _ = try mac.open(first)
        _ = try mac.open(second)
        // And the late ones are still each spent exactly once.
        #expect(throws: ChannelError.replayed) { try mac.open(first) }
    }

    /// Counters start over on every launch, so two sessions under one secret would repeat
    /// their nonces — which is the failure that hands out the keystream rather than merely
    /// leaking a repeat. The salt is what keeps the keys apart, and the Mac has to follow
    /// the phone into a new session without being restarted itself.
    @Test("A phone that restarts is heard again, with different bytes on the wire")
    func aRestartedPhoneIsHeard() throws {
        let secret = Data(repeating: 7, count: 32)
        let mac = SecureChannel(secret: secret, role: .mac)

        let first = SecureChannel(secret: secret, role: .phone, salt: 1)
        let second = SecureChannel(secret: secret, role: .phone, salt: 2)
        let sealedOnce = first.seal(.click)
        let sealedAgain = second.seal(.click)

        #expect(try mac.open(sealedOnce) == .click)
        #expect(try mac.open(sealedAgain) == .click)
        #expect(sealedOnce.dropFirst(18) != sealedAgain.dropFirst(18),
                "same packet, same counter, different session — the ciphertext must differ")
    }

    /// The Mac has to keep accepting the old, unsealed protocol while the phone is being
    /// updated, and it can only do that if the two are distinguishable by inspection.
    @Test("A plain packet is reported as unsealed rather than as an intruder")
    func plainPacketsAreToldApart() {
        let (_, mac) = pair()
        #expect(throws: ChannelError.notSealed) { try mac.open(Packet.click.encode()) }
    }

    @Test("Rubbish on the port is refused without crashing")
    func rubbishIsRefused() {
        let (_, mac) = pair()
        #expect(throws: (any Error).self) { try mac.open(Data([1, 0x20, 3])) }
        #expect(throws: (any Error).self) { try mac.open(Data()) }
        #expect(throws: (any Error).self) { try mac.open(Data(repeating: 0x20, count: 60)) }
    }

    @Test("The Mac can answer the phone once it has heard it")
    func repliesAreSealedToo() throws {
        let (phone, mac) = pair()
        _ = try mac.open(phone.seal(.click))
        let feedback = Packet.feedback(Feedback(kind: .click, intensity: 200))
        #expect(try phone.open(mac.seal(feedback)) == feedback)
    }
}

@Suite("Pairing code")
struct PairingCodeTests {
    private let code = PairingCode(
        secret: Data((0 ..< 32).map { UInt8($0) }),
        serviceName: "Mac mini Едуарда",
        addresses: ["192.168.1.10", "fe80::1"],
        port: 51888
    )

    @Test("A code survives the trip through a QR as a string")
    func roundTrip() throws {
        let parsed = try #require(PairingCode(url: code.url))
        #expect(parsed == code)
    }

    @Test("Anything that is not one of our codes is refused")
    func foreignCodesAreRefused() {
        #expect(PairingCode(url: "https://example.com") == nil)
        #expect(PairingCode(url: "trackpadphone://pair?v=1") == nil)
        #expect(PairingCode(url: "") == nil)
        // A secret of the wrong length is the interesting one: it parses, and it would
        // pair — into a channel that could never open a packet.
        #expect(PairingCode(url: "trackpadphone://pair?v=1&k=YWJj&n=x&p=1") == nil)
    }
}

private extension Packet {
    /// A short packet to seal when the contents do not matter.
    static let click = Packet.keyInput(KeyInput(keyCode: 36, modifiers: [], text: ""))
}
