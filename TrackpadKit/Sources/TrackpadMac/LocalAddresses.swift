import Foundation

/// The Mac's own addresses on the local network.
///
/// Discovery is Bonjour, so nobody types these any more. They go into the pairing code as a
/// hint — enough to connect the first time, and enough to keep working on a network where
/// mDNS is filtered, which is common enough on office Wi-Fi to be worth the two lines.
public enum LocalAddresses {
    /// Bare addresses, newest interface first as the system reports them.
    public static func all() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            // en0 is Wi-Fi on Apple Silicon Macs; en1+ covers Ethernet and adapters.
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                // Truncating at the null rather than handing the whole buffer to a String
                // initialiser that would keep every trailing zero.
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                found.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return found
    }

    /// The same list with the interface each address came from, for the menu.
    public static func described() -> [String] {
        zip(all(), interfaceNames()).map { "\($0)   (\($1))" }
    }

    private static func interfaceNames() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var names: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            names.append(name)
        }
        return names
    }
}
