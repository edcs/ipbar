import Testing
@testable import IPBar

@Suite("Which changes are worth announcing")
struct ChangeDetectorTests {
    private func snap(_ ip: String?, _ vpn: VPNState.Mode) -> NetworkSnapshot {
        NetworkSnapshot(publicIP: ip, vpn: vpn)
    }

    // MARK: VPN

    @Test("a weakening tunnel is announced", arguments: [
        (VPNState.Mode.full, VPNState.Mode.off),
        (.full, .split),
        (.split, .off)
    ])
    func weakening(_ pair: (VPNState.Mode, VPNState.Mode)) {
        let changes = ChangeDetector.changes(from: snap("203.0.113.42", pair.0),
                                             to: snap("203.0.113.42", pair.1))
        #expect(changes == [.vpnWeakened(from: pair.0, to: pair.1)])
    }

    @Test("a strengthening or unchanged tunnel is silent", arguments: [
        (VPNState.Mode.off, VPNState.Mode.full),
        (.off, .split),
        (.split, .full),
        (.off, .off),
        (.full, .full),
        (.split, .split)
    ])
    func notWeakening(_ pair: (VPNState.Mode, VPNState.Mode)) {
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", pair.0),
                                       to: snap("203.0.113.42", pair.1)).isEmpty)
    }

    @Test("every mode pair is accounted for")
    func allPairsCovered() {
        // Guards against a fourth mode being added and silently falling
        // through whichever branch happens to catch it.
        var weakening = 0
        for from in VPNState.Mode.allCases {
            for to in VPNState.Mode.allCases {
                let changes = ChangeDetector.changes(from: snap("1.1.1.1", from),
                                                     to: snap("1.1.1.1", to))
                if !changes.isEmpty { weakening += 1 }
            }
        }
        #expect(VPNState.Mode.allCases.count == 3)
        #expect(weakening == 3)
    }

    @Test("coverage ordering is explicit, not declaration order")
    func coverageOrdering() {
        // The enum declares `off, full, split`, so declaration order says the
        // opposite of what coverage means.
        #expect(VPNState.Mode.off.coverage < VPNState.Mode.split.coverage)
        #expect(VPNState.Mode.split.coverage < VPNState.Mode.full.coverage)
    }

    // MARK: Public IP

    @Test("a different address is announced")
    func addressChanged() {
        let changes = ChangeDetector.changes(from: snap("203.0.113.41", .off),
                                             to: snap("203.0.113.42", .off))
        #expect(changes == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("the same address is silent")
    func addressUnchanged() {
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", .off),
                                       to: snap("203.0.113.42", .off)).isEmpty)
    }

    @Test("losing the address is not a change")
    func addressLost() {
        // The struck-through globe already says the internet is unreachable.
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", .off),
                                       to: snap(nil, .off)).isEmpty)
    }

    @Test("a first address with no baseline is not a change")
    func firstAddress() {
        #expect(ChangeDetector.changes(from: snap(nil, .off),
                                       to: snap("203.0.113.42", .off)).isEmpty)
    }

    // MARK: Both at once

    @Test("both changing yields both, VPN first")
    func bothChanged() {
        let changes = ChangeDetector.changes(from: snap("203.0.113.41", .full),
                                             to: snap("203.0.113.42", .off))
        #expect(changes == [.vpnWeakened(from: .full, to: .off),
                            .publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }
}
