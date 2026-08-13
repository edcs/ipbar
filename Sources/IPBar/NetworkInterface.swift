import Darwin
import Foundation
import SystemConfiguration

struct NetworkInterface: Identifiable, Hashable, Sendable {
    enum Family: String, Sendable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
    }

    enum Kind: Sendable {
        case wifi, ethernet, tunnel, cellular, loopback, virtual, other

        var isPhysical: Bool { self == .wifi || self == .ethernet || self == .cellular }
    }

    let bsdName: String
    let address: String
    let family: Family
    let kind: Kind
    let isLinkLocal: Bool
    var friendlyName: String?

    var id: String { "\(bsdName)|\(address)" }
    var label: String { friendlyName ?? bsdName }
}

enum InterfaceScanner {
    /// Enumerates every up interface with an assigned IPv4/IPv6 address.
    ///
    /// `getifaddrs` is the only complete source here — SystemConfiguration
    /// omits transient interfaces such as VPN tunnels, which is exactly what
    /// we need to see. We use SC only to decorate the results with the
    /// human-readable names shown in Network settings.
    static func scan() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        let decoration = decorations()
        var results: [NetworkInterface] = []
        var cursor = head

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0 else { continue }
            guard let sockaddr = current.pointee.ifa_addr else { continue }

            let family: NetworkInterface.Family
            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET: family = .ipv4
            case AF_INET6: family = .ipv6
            default: continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let bsdName = String(validatingCString: current.pointee.ifa_name) ?? ""
            let kind: NetworkInterface.Kind = flags & IFF_LOOPBACK != 0
                ? .loopback
                : classify(bsdName: bsdName, scType: decoration.types[bsdName])

            results.append(NetworkInterface(
                bsdName: bsdName,
                address: address,
                family: family,
                kind: kind,
                isLinkLocal: isLinkLocal(address, family: family),
                friendlyName: decoration.names[bsdName]
            ))
        }

        return results
    }

    /// The interface carrying the default route, i.e. where general traffic
    /// actually leaves the machine. This is the signal that distinguishes a
    /// full-tunnel VPN from a split-tunnel one.
    static func primaryInterface(family: NetworkInterface.Family) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "IPBar.primary" as CFString, nil, nil) else { return nil }
        let key = family == .ipv4 ? "State:/Network/Global/IPv4" : "State:/Network/Global/IPv6"
        guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private static func classify(bsdName: String, scType: String?) -> NetworkInterface.Kind {
        if let scType {
            switch scType as CFString {
            case kSCNetworkInterfaceTypeIEEE80211: return .wifi
            case kSCNetworkInterfaceTypeEthernet: return .ethernet
            case kSCNetworkInterfaceTypeWWAN: return .cellular
            case kSCNetworkInterfaceTypeIPSec, kSCNetworkInterfaceTypePPP, kSCNetworkInterfaceTypeL2TP:
                return .tunnel
            default: break
            }
        }

        for prefix in ["utun", "ipsec", "ppp", "tun", "tap", "gpd", "wg"] where bsdName.hasPrefix(prefix) {
            return .tunnel
        }
        for prefix in ["awdl", "llw", "bridge", "ap", "anpi", "vmenet", "vnic", "XHC"] where bsdName.hasPrefix(prefix) {
            return .virtual
        }
        return bsdName.hasPrefix("en") ? .ethernet : .other
    }

    private static func isLinkLocal(_ address: String, family: NetworkInterface.Family) -> Bool {
        switch family {
        case .ipv4: return address.hasPrefix("169.254.")
        case .ipv6:
            let lowered = address.lowercased()
            return lowered.hasPrefix("fe80:") || lowered.hasPrefix("fe80::")
        }
    }

    private static func decorations() -> (names: [String: String], types: [String: String]) {
        var names: [String: String] = [:]
        var types: [String: String] = [:]

        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            if let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsdName] = name
            }
            if let type = SCNetworkInterfaceGetInterfaceType(interface) as String? {
                types[bsdName] = type
            }
        }

        return (names, types)
    }
}
