import Foundation

/// M0 has no Bonjour discovery, so the phone needs an IP typed in by hand. Printing the
/// candidates saves a trip to System Settings — and a manual-address path is worth keeping
/// anyway as the fallback for when discovery fails on someone's network.
public enum LocalAddresses {
    public static func wifi() -> [String] {
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
                found.append("\(String(cString: host))   (\(name))")
            }
        }
        return found
    }
}
