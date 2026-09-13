import Foundation

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
