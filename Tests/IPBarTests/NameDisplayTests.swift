import Foundation
import Testing
@testable import IPBar

@Suite("How a named address is shown")
@MainActor
struct NameDisplayTests {
    private let address = "83.151.201.105"

    private func model(_ mode: NameDisplay, named: Bool = true) -> NetworkModel {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let preferences = Preferences(defaults: defaults)
        preferences.nameDisplay = mode
        if named {
            preferences.labels = [AddressLabel(pattern: address, name: "Home",
                                               scope: .publicAddress)]
        }
        return NetworkModel(preferences: preferences)
    }

    @Test("name only")
    func nameOnly() {
        #expect(model(.name).display(address, scope: .publicAddress) == "Home")
    }

    @Test("name and address together")
    func nameAndAddress() {
        #expect(model(.nameAndAddress).display(address, scope: .publicAddress)
                == "Home (83.151.201.105)")
    }

    @Test("address only, ignoring the name")
    func addressOnly() {
        #expect(model(.address).display(address, scope: .publicAddress) == "83.151.201.105")
    }

    @Test("an address with no name is just the address, whatever the setting",
          arguments: [NameDisplay.name, .nameAndAddress, .address])
    func unnamedIsAlwaysTheAddress(_ mode: NameDisplay) {
        #expect(model(mode, named: false).display(address, scope: .publicAddress) == address)
    }

    @Test("a name for the wrong scope does not apply")
    func scopeIsRespected() {
        // The label is public; asking as a local address must not pick it up.
        #expect(model(.name).display(address, scope: .localAddress) == address)
    }

    @Test("nothing to show stays nothing")
    func noAddress() {
        #expect(model(.nameAndAddress).display(nil, scope: .publicAddress) == nil)
    }
}

@Suite("A named network in the menu bar")
@MainActor
struct NetworkNameDisplayTests {
    private let home = NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                  descriptor: "Wi-Fi · router 172.16.132.1")

    private func model(_ mode: NameDisplay = .name,
                       source: DisplaySource = .publicAddress,
                       named: Bool = true) -> NetworkModel {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let preferences = Preferences(defaults: defaults)
        preferences.nameDisplay = mode
        preferences.displaySource = source
        if named {
            preferences.labels = [AddressLabel(key: .network(gateway: home.gateway,
                                                             descriptor: home.descriptor),
                                               name: "Home")]
        }
        let key = home
        return NetworkModel(preferences: preferences, gateway: { _ in key })
    }

    @Test("a network name replaces the public address")
    func replacesPublic() {
        let model = self.model()
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("a network name replaces a local address too")
    func replacesLocal() {
        let model = self.model(source: .localAddress)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("both mode shows one name rather than repeating it")
    func bothCollapses() {
        let model = self.model(source: .both)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("both mode still joins two different names")
    func bothJoins() {
        let model = self.model(source: .both, named: false)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "192.168.1.77 · 203.0.113.42")
    }

    @Test("name and address shows both")
    func nameAndAddress() {
        let model = self.model(.nameAndAddress)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home (203.0.113.42)")
    }

    @Test("the address setting suppresses a network name too")
    func addressOnly() {
        let model = self.model(.address)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "203.0.113.42")
    }

    @Test("an unknown network leaves the address alone")
    func unknownNetwork() {
        let model = self.model()
        let elsewhere = NetworkKey(gateway: "00:11:22:33:44:55", descriptor: "Wi-Fi · router 10.0.0.1")
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: elsewhere)
        #expect(model.menuBarText == "203.0.113.42")
        #expect(model.networkName == nil)
    }

    @Test("networkName reports the current network's name for the panel")
    func panelName() {
        let model = self.model()
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.networkName == "Home")
    }
}
