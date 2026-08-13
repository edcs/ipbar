import Foundation
import Testing
@testable import IPBar

@Suite("Naming an address in place")
struct InlineNamingTests {
    @Test("naming an unlabelled address adds one label")
    func addsLabel() {
        var labels: [AddressLabel] = []
        labels.setName("Office", for: "203.0.113.42", scope: .publicAddress)

        #expect(labels.count == 1)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Office")
        #expect(labels.first?.pattern == "203.0.113.42")
    }

    @Test("renaming updates in place rather than piling up duplicates")
    func updatesInPlace() {
        var labels: [AddressLabel] = []
        labels.setName("Office", for: "203.0.113.42", scope: .publicAddress)
        labels.setName("Studio", for: "203.0.113.42", scope: .publicAddress)
        labels.setName("Workshop", for: "203.0.113.42", scope: .publicAddress)

        #expect(labels.count == 1)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Workshop")
    }

    @Test("clearing the name removes the label")
    func clearingRemoves() {
        var labels: [AddressLabel] = []
        labels.setName("Office", for: "203.0.113.42", scope: .publicAddress)
        labels.setName("   ", for: "203.0.113.42", scope: .publicAddress)

        #expect(labels.isEmpty)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == nil)
    }

    @Test("a blank name on an unlabelled address adds nothing")
    func blankOnUnlabelled() {
        var labels: [AddressLabel] = []
        labels.setName("", for: "203.0.113.42", scope: .publicAddress)
        #expect(labels.isEmpty)
    }

    @Test("names are trimmed")
    func trims() {
        var labels: [AddressLabel] = []
        labels.setName("  Office  ", for: "203.0.113.42", scope: .publicAddress)
        #expect(labels.first?.name == "Office")
    }

    @Test("the same address can be named separately for public and local")
    func scopesAreIndependent() {
        var labels: [AddressLabel] = []
        labels.setName("Seen from outside", for: "203.0.113.42", scope: .publicAddress)
        labels.setName("Seen from here", for: "203.0.113.42", scope: .localAddress)

        #expect(labels.count == 2)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Seen from outside")
        #expect(labels.name(for: "203.0.113.42", scope: .localAddress) == "Seen from here")
    }

    @Test("a name inherited from a block is not this address's to remove")
    func inheritedNameIsNotOwned() {
        // The row shows "Office network" because a /24 covers it, but Remove
        // Name would be lying: the label belongs to the block.
        var labels = [AddressLabel(pattern: "203.0.113.0/24", name: "Office network")]

        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Office network")
        #expect(labels.hasOwnLabel(for: "203.0.113.42", scope: .publicAddress) == false)

        labels.removeLabel(for: "203.0.113.42", scope: .publicAddress)
        #expect(labels.count == 1, "the block label must survive")
    }

    @Test("naming an address inside a named block wins on specificity")
    func exactBeatsBlock() {
        var labels = [AddressLabel(pattern: "203.0.113.0/24", name: "Office network")]
        labels.setName("My desk", for: "203.0.113.42", scope: .publicAddress)

        #expect(labels.count == 2)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "My desk")
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress) == "Office network")
    }

    @Test("removing an address's own label falls back to the block")
    func removalFallsBack() {
        var labels = [AddressLabel(pattern: "203.0.113.0/24", name: "Office network")]
        labels.setName("My desk", for: "203.0.113.42", scope: .publicAddress)
        #expect(labels.hasOwnLabel(for: "203.0.113.42", scope: .publicAddress))

        labels.removeLabel(for: "203.0.113.42", scope: .publicAddress)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Office network")
    }

    @Test("an IPv6 address can be named the same way")
    func ipv6() {
        var labels: [AddressLabel] = []
        labels.setName("Home v6", for: "2a06:61c2:1738:0:e98d:4bd1:6925:4e84", scope: .publicAddress)
        #expect(labels.name(for: "2a06:61c2:1738:0:e98d:4bd1:6925:4e84",
                            scope: .publicAddress) == "Home v6")
    }
}
