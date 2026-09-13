import Foundation

/// The facts a notification can be derived from, captured at one moment.
struct NetworkSnapshot: Hashable, Sendable {
    let publicIP: String?
    let vpn: VPNState.Mode
}

/// Something worth interrupting the user about.
enum NetworkChange: Hashable, Sendable {
    case vpnWeakened(from: VPNState.Mode, to: VPNState.Mode)
    case publicIPChanged(from: String, to: String)
}

enum ChangeDetector {
    /// The changes worth announcing, going from `baseline` to `current`.
    ///
    /// The VPN rule is that the tunnel now covers less than it did, not that
    /// it disappeared. `full → split` is the case that motivates it: a full
    /// tunnel dies while a mesh VPN stays up, so general traffic starts
    /// leaving in the clear while the panel still reads "some traffic through
    /// a VPN". A drop-only rule says nothing about the most dangerous state
    /// this app can observe.
    ///
    /// A missing public address is never a change. Losing the internet is not
    /// an address changing, and the struck-through globe already says it —
    /// which also means a first observation, with no address to compare
    /// against, announces nothing.
    static func changes(from baseline: NetworkSnapshot,
                        to current: NetworkSnapshot) -> [NetworkChange] {
        var changes: [NetworkChange] = []

        if current.vpn.coverage < baseline.vpn.coverage {
            changes.append(.vpnWeakened(from: baseline.vpn, to: current.vpn))
        }

        if let was = baseline.publicIP, let now = current.publicIP, was != now {
            changes.append(.publicIPChanged(from: was, to: now))
        }

        return changes
    }
}
