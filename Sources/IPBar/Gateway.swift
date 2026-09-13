import Darwin
import Foundation
import SystemConfiguration

/// Identifies the network this Mac is attached to, by the link-layer address
/// of its gateway.
///
/// A gateway MAC is stable while an ISP rotates the public address behind it,
/// is the same across every satellite of a mesh network, and needs no
/// permission to read — unlike an SSID, which has required Location Services
/// since macOS 14.
struct NetworkKey: Hashable, Sendable {
    /// Lowercase, colon-separated, zero-padded: `74:24:9f:ab:0e:ab`.
    let gateway: String
    /// Captured when the network is named, for display only: `Wi-Fi · router 172.16.132.1`.
    let descriptor: String
}

/// One service's router, as SystemConfiguration reports it.
struct RouterCandidate: Hashable, Sendable {
    let serviceID: String
    let interface: String
    let router: String
}

enum GatewaySelection {
    /// Picks the router belonging to the primary physical interface.
    ///
    /// Deliberately not the default route. With a full-tunnel VPN up the
    /// default route points at the tunnel, and a point-to-point tunnel has no
    /// link layer — so its gateway has no ARP entry and the key would vanish
    /// the moment you connect. Filtering to physical interfaces gives a key
    /// that is byte-identical before and after a tunnel comes up.
    ///
    /// With both Wi-Fi and Ethernet up, `ServiceOrder` from
    /// `Setup:/Network/Global/IPv4` decides — that is the user's own priority
    /// from Network settings, rather than a rule we invented. Services missing
    /// from the order sort last, and ties fall back to the interface name so
    /// the same inputs always give the same key.
    static func choose(candidates: [RouterCandidate],
                       physicalInterfaces: Set<String>,
                       serviceOrder: [String]) -> RouterCandidate? {
        let physical = candidates.filter { physicalInterfaces.contains($0.interface) }
        guard physical.count > 1 else { return physical.first }

        return physical.min { lhs, rhs in
            let left = serviceOrder.firstIndex(of: lhs.serviceID) ?? Int.max
            let right = serviceOrder.firstIndex(of: rhs.serviceID) ?? Int.max
            if left != right { return left < right }
            return lhs.interface < rhs.interface
        }
    }

    /// Lowercase, colon-separated, zero-padded. `arp -a` prints a leading zero
    /// nibble truncated, which would let two networks collide on one key.
    static func formatMAC(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

enum GatewayScanner {
    /// The network this Mac is attached to, or nil when there isn't one.
    ///
    /// Failure is always total rather than partial: any step coming up empty
    /// yields nil, so a name is never guessed. Cellular and tethered links have
    /// no ARP table at all, so they resolve to nil by construction.
    static func current(interfaces: [NetworkInterface]) -> NetworkKey? {
        let physical = Set(interfaces.filter { $0.kind.isPhysical }.map(\.bsdName))
        guard let chosen = GatewaySelection.choose(candidates: routerCandidates(),
                                                   physicalInterfaces: physical,
                                                   serviceOrder: serviceOrder()) else { return nil }
        guard let mac = arpTable()[chosen.router] else { return nil }

        let friendly = interfaces.first { $0.bsdName == chosen.interface }?.label
            ?? chosen.interface
        return NetworkKey(gateway: mac,
                          descriptor: "\(friendly) · router \(chosen.router)")
    }

    /// Every service reporting both an interface and a router.
    static func routerCandidates() -> [RouterCandidate] {
        guard let store = SCDynamicStoreCreate(nil, "IPBar.routers" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(
                store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [] }

        return keys.compactMap { key in
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = dict["InterfaceName"] as? String,
                  let router = dict["Router"] as? String else { return nil }
            let parts = key.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return RouterCandidate(serviceID: String(parts[2]),
                                   interface: interface, router: router)
        }
    }

    /// The user's own service priority from Network settings.
    static func serviceOrder() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "IPBar.order" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(
                store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
              let order = dict["ServiceOrder"] as? [String] else { return [] }
        return order
    }

    /// The ARP table, via the same `sysctl` call `arp -a` makes.
    ///
    /// Entries with `sdl_alen != 6` are incomplete — exactly the rows `arp -a`
    /// prints as `(incomplete)` — and are skipped.
    static func arpTable() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return [:] }

        var result: [String: String] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < needed {
                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self)
                let length = Int(header.pointee.rtm_msglen)
                guard length > 0 else { break }
                defer { offset += length }

                // RTA_DST first (sockaddr_inarp, layout-compatible with
                // sockaddr_in for the fields we read), then RTA_GATEWAY
                // (sockaddr_dl carrying the MAC).
                let dstOffset = offset + MemoryLayout<rt_msghdr>.stride
                guard dstOffset + MemoryLayout<sockaddr_in>.size <= needed else { continue }
                let dst = base.advanced(by: dstOffset)
                    .assumingMemoryBound(to: sockaddr_in.self)
                guard dst.pointee.sin_family == sa_family_t(AF_INET) else { continue }

                var addr = dst.pointee.sin_addr
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil
                else { continue }

                let dlOffset = dstOffset + roundup(Int(dst.pointee.sin_len))
                guard dlOffset + MemoryLayout<sockaddr_dl>.size <= needed else { continue }
                let link = base.advanced(by: dlOffset)
                    .assumingMemoryBound(to: sockaddr_dl.self)
                let addressLength = Int(link.pointee.sdl_alen)
                guard addressLength == 6 else { continue }

                let nameLength = Int(link.pointee.sdl_nlen)
                let mac = withUnsafeBytes(of: link.pointee.sdl_data) { bytes in
                    GatewaySelection.formatMAC((0..<addressLength).map { bytes[nameLength + $0] })
                }
                result[String(cString: host)] = mac
            }
        }
        return result
    }

    /// Route message sockaddrs are padded to a 4-byte boundary.
    private static func roundup(_ length: Int) -> Int {
        length > 0
            ? (1 + ((length - 1) | (MemoryLayout<UInt32>.size - 1)))
            : MemoryLayout<UInt32>.size
    }
}
