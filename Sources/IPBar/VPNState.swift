import Foundation

/// macOS gives no public API for "is a VPN connected" — `NEVPNManager` only
/// reports configurations your own app created. So we infer it from the
/// routing table instead, which is both API-free and provider-agnostic.
///
/// Two facts drive the result:
///
///   1. Which tunnel interfaces (`utun*`, `ipsec*`, `ppp*`) hold a *routable*
///      address. Modern macOS always keeps several `utun` interfaces up for
///      Handoff, Continuity and iCloud Private Relay, but those carry only
///      link-local addresses — requiring a routable one filters them out.
///   2. Whether the default route points at one of those tunnels. If it does,
///      everything is going through the VPN (full tunnel). If not, but a
///      tunnel is up, only some routes are (split tunnel — Tailscale and
///      similar mesh VPNs behave this way).
struct VPNState: Equatable, Sendable {
    enum Mode: String, Sendable {
        case off, full, split
    }

    var mode: Mode = .off
    var tunnels: [String] = []
    var primaryTunnel: String?

    var isActive: Bool { mode != .off }

    var summary: String {
        switch mode {
        case .off: return "No VPN"
        case .full: return "VPN — all traffic (\(primaryTunnel ?? "tunnel"))"
        case .split: return "VPN — split tunnel (\(tunnels.joined(separator: ", ")))"
        }
    }

    static func detect(interfaces: [NetworkInterface]) -> VPNState {
        let tunnels = interfaces.filter { $0.kind == .tunnel && !$0.isLinkLocal }
        let names = Array(Set(tunnels.map(\.bsdName))).sorted()
        guard !names.isEmpty else { return VPNState() }

        let primaries = [
            InterfaceScanner.primaryInterface(family: .ipv4),
            InterfaceScanner.primaryInterface(family: .ipv6)
        ].compactMap { $0 }

        if let primaryTunnel = primaries.first(where: names.contains) {
            return VPNState(mode: .full, tunnels: names, primaryTunnel: primaryTunnel)
        }
        return VPNState(mode: .split, tunnels: names, primaryTunnel: nil)
    }
}
