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

@Suite("Naming a network")
struct NetworkNamingTests {
    private let home = NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                  descriptor: "Wi-Fi · router 172.16.132.1")

    @Test("naming a network appends one label carrying its descriptor")
    func names() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)

        #expect(labels.count == 1)
        #expect(labels[0].name == "Home")
        #expect(labels[0].key == .network(gateway: "74:24:9f:ab:0e:ab",
                                          descriptor: "Wi-Fi · router 172.16.132.1"))
    }

    @Test("renaming the same network updates in place")
    func renames() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("House", for: home)

        #expect(labels.count == 1)
        #expect(labels[0].name == "House")
    }

    @Test("a descriptor that has drifted does not create a second label")
    func descriptorDriftDoesNotDuplicate() {
        // The gateway alone is the identity. If the router's address changes,
        // the descriptor goes stale but the label must stay one label.
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("Home", for: NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                                      descriptor: "Wi-Fi · router 10.9.9.1"))
        #expect(labels.count == 1)
    }

    @Test("clearing the name removes the label")
    func clearing() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("   ", for: home)
        #expect(labels.isEmpty)
    }

    @Test("a network label does not collide with an address label")
    func noCollisionWithAddresses() {
        var labels = [AddressLabel(pattern: "203.0.113.42", name: "Office")]
        labels.setNetworkName("Home", for: home)
        #expect(labels.count == 2)
    }

    @Test("removing a network name leaves address labels alone")
    func removal() {
        var labels = [AddressLabel(pattern: "203.0.113.42", name: "Office")]
        labels.setNetworkName("Home", for: home)
        labels.removeLabel(forKey: .network(gateway: home.gateway, descriptor: home.descriptor),
                           scope: .any)
        #expect(labels.count == 1)
        #expect(labels[0].name == "Office")
    }

    @Test("hasOwnLabel finds a named network")
    func ownership() {
        var labels: [AddressLabel] = []
        #expect(!labels.hasOwnLabel(forKey: .network(gateway: home.gateway,
                                                     descriptor: home.descriptor), scope: .any))
        labels.setNetworkName("Home", for: home)
        #expect(labels.hasOwnLabel(forKey: .network(gateway: home.gateway,
                                                    descriptor: home.descriptor), scope: .any))
    }
}
