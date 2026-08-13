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
