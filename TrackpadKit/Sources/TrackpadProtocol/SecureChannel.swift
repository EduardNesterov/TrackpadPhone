import CryptoKit
import Foundation

/// Which end is speaking. The two directions get different keys from the same shared
/// secret, because they share a nonce space otherwise — and a repeated nonce under
/// ChaCha20-Poly1305 does not degrade politely, it hands out the keystream.
public enum ChannelRole: Sendable {
    case phone
    case mac

    var sendingInfo: String { self == .phone ? "phone-to-mac" : "mac-to-phone" }
    var receivingInfo: String { self == .phone ? "mac-to-phone" : "phone-to-mac" }
}

public enum ChannelError: Error, Equatable, Sendable {
    /// Not one of ours at all — a plain unsealed packet, or noise on an open UDP port.
    case notSealed
    /// The tag did not verify: wrong key, or the bytes were altered on the way.
    case notAuthentic
    case truncated
    /// A counter that has been seen, or one so old the window has passed it by.
    case replayed
}

/// Authenticated encryption for everything on the wire.
///
/// The reason this exists is not privacy of finger coordinates. It is that the receiver
/// turns packets into *keystrokes and clicks on the desktop*, and an open UDP port therefore
/// hands anyone on the network a keyboard. Authentication is the point; encryption comes
/// along for free with the construction and pays for itself the first time someone types a
/// password on the phone.
///
/// Envelope, little-endian, all of it outside the ciphertext and all of it authenticated as
/// associated data:
///
///     u8 version, u8 0x20, u64 salt, u64 counter, ciphertext…, 16-byte tag
///
/// `0x20` is not a `Packet.WireType`, so a plain decoder rejects a sealed datagram and this
/// decoder rejects a plain one. That is what lets the Mac accept both during a changeover
/// instead of forcing both ends to be updated in the same minute.
///
/// **Salt.** Counters restart at zero every launch, so the key cannot be the same across two
/// launches or the nonces repeat. The sender picks eight random bytes per session and carries
/// them in every packet; the key is derived from the shared secret *and* those bytes, so a
/// repeat needs a 64-bit collision rather than a coincidence. The phone chooses; the Mac
/// adopts what it hears, so one session has one salt and the phone can derive the return key
/// before it has received anything.
public final class SecureChannel {
    private let secret: SymmetricKey
    private let role: ChannelRole

    private var salt: UInt64
    private var sendingKey: SymmetricKey
    private var receivingKey: SymmetricKey
    private var counter: UInt64 = 0

    /// - Parameter salt: only for tests; sessions pick their own.
    public init(secret: Data, role: ChannelRole, salt: UInt64? = nil) {
        self.secret = SymmetricKey(data: secret)
        self.role = role
        self.salt = salt ?? UInt64.random(in: .min ... .max)
        sendingKey = Self.derive(self.secret, salt: self.salt, info: role.sendingInfo)
        receivingKey = Self.derive(self.secret, salt: self.salt, info: role.receivingInfo)
    }

    private static func derive(_ secret: SymmetricKey, salt: UInt64, info: String) -> SymmetricKey {
        var saltBytes = salt.littleEndian
        let saltData = withUnsafeBytes(of: &saltBytes) { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: saltData,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    private func adopt(salt newSalt: UInt64) {
        guard newSalt != salt else { return }
        salt = newSalt
        sendingKey = Self.derive(secret, salt: newSalt, info: role.sendingInfo)
        receivingKey = Self.derive(secret, salt: newSalt, info: role.receivingInfo)
        // A new session on the other end starts its counters over, and so must the window
        // that judges them — otherwise every packet of the new session looks ancient.
        highestSeen = 0
        seenWindow = 0
    }

    // MARK: - Sealing

    private static let sealedType: UInt8 = 0x20
    private static let headerLength = 18

    public func seal(_ packet: Packet) -> Data {
        counter &+= 1
        var header = Data([protocolVersion, Self.sealedType])
        header.append(contentsOf: withUnsafeBytes(of: salt.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: counter.littleEndian) { Array($0) })

        guard let box = try? ChaChaPoly.seal(
            packet.encode(),
            using: sendingKey,
            nonce: Self.nonce(counter),
            authenticating: header
        ) else {
            // Sealing fails only if the system's own crypto does, which is not a case worth
            // a throwing API through every send site. An empty datagram is dropped by the
            // far end as truncated.
            return Data()
        }
        return header + box.ciphertext + box.tag
    }

    /// Counter in the low eight bytes, zeroes above. Uniqueness comes from the counter
    /// within a session and from the salt across them, so the nonce needs no randomness.
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: counter.littleEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[4 + index] = byte }
        }
        // The length is right by construction, so this cannot throw in practice.
        return (try? ChaChaPoly.Nonce(data: bytes)) ?? ChaChaPoly.Nonce()
    }

    // MARK: - Opening

    public func open(_ data: Data) throws -> Packet {
        guard data.count >= 2 else { throw ChannelError.truncated }
        guard data[data.startIndex] == protocolVersion,
              data[data.startIndex + 1] == Self.sealedType else { throw ChannelError.notSealed }
        guard data.count > Self.headerLength + 16 else { throw ChannelError.truncated }

        let header = data.prefix(Self.headerLength)
        let salt = Self.readUInt64(data, at: 2)
        let counter = Self.readUInt64(data, at: 10)

        // A peer that restarted brings a new salt, and it has to be heard rather than shut
        // out — but the key for it is derived into a local, not into this object. Adopting
        // first would let anyone reset the replay window with eight random bytes they have
        // no key to back up, and a reset window is a window that accepts replays.
        let key = salt == self.salt
            ? receivingKey
            : Self.derive(secret, salt: salt, info: role.receivingInfo)
        // Only the Mac follows the phone into a new session; the phone chose the salt, so
        // anything else reaching it is somebody else's traffic.
        guard role == .mac || salt == self.salt else { throw ChannelError.notAuthentic }

        let sealed = data.dropFirst(Self.headerLength)
        let tag = sealed.suffix(16)
        let ciphertext = sealed.dropLast(16)

        guard let box = try? ChaChaPoly.SealedBox(
                  nonce: Self.nonce(counter), ciphertext: ciphertext, tag: tag
              ),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: header)
        else { throw ChannelError.notAuthentic }

        // Verified, so this really is the far end starting over: now the state may move.
        if salt != self.salt { adopt(salt: salt) }
        // And only after the tag, or an attacker could exhaust the window with counters
        // they never had the key to produce.
        guard accept(counter: counter) else { throw ChannelError.replayed }
        return try Packet.decode(plain)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value |= UInt64(data[data.startIndex + offset + index]) << (8 * index)
        }
        return value
    }

    // MARK: - Replay

    /// Highest counter accepted, and a bitmap of the 63 before it.
    ///
    /// A window rather than "strictly increasing", because UDP reorders and a strict rule
    /// would drop perfectly good frames whenever it did — including the deliberate duplicate
    /// copies the phone sends when the contact count changes, which is exactly the traffic
    /// that must not be lost.
    private var highestSeen: UInt64 = 0
    private var seenWindow: UInt64 = 0

    private func accept(counter: UInt64) -> Bool {
        guard counter > 0 else { return false }
        if counter > highestSeen {
            let shift = counter - highestSeen
            seenWindow = shift >= 64 ? 0 : (seenWindow << shift)
            seenWindow |= 1
            highestSeen = counter
            return true
        }
        let back = highestSeen - counter
        guard back < 64 else { return false }
        let bit: UInt64 = 1 << back
        guard seenWindow & bit == 0 else { return false }
        seenWindow |= bit
        return true
    }
}
