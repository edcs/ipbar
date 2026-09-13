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
