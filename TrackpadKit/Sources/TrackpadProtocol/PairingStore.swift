import Foundation
import Security

/// Where the shared secret lives on each device.
///
/// The Keychain rather than `UserDefaults`, because this key is the whole of the trust
/// between the two: anything holding it can move the pointer and type on the desktop. In
/// defaults it would sit in a world-readable plist and travel in backups as plain text.
///
/// Shared by both ends deliberately — it is the same secret, stored the same way, and one
/// implementation is one place to get the attributes right. It is the only part of this
/// module that is not about bytes on the wire.
public struct PairingStore {
    private let service: String
    private let account: String

    public init(service: String = "TrackpadPhone", account: String = "pairing-secret") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    public func save(_ secret: Data) -> Bool {
        // Delete first rather than update: an add that collides and an update that finds
        // nothing are two different failures, and this has neither.
        SecItemDelete(query as CFDictionary)

        var request = query
        request[kSecValueData as String] = secret
        // The phone is used while it is locked in the hand and the Mac reads this at login,
        // before anyone has typed anything — so the item has to survive being asked for
        // while the device is locked, as long as it has been unlocked once since boot.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }

    /// The stored secret, or a fresh random one saved on the way out.
    public func loadOrCreate() -> Data {
        if let existing = load(), existing.count == PairingCode.secretByteCount { return existing }
        var bytes = [UInt8](repeating: 0, count: PairingCode.secretByteCount)
        // From the system's own generator; `Int.random` is not a source to build trust on.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes)
        save(secret)
        return secret
    }
}
