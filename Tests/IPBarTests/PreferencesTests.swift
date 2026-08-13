import Foundation
import Testing
@testable import IPBar

@Suite("Preferences persistence")
@MainActor
struct PreferencesTests {
    private func scratchDefaults() -> UserDefaults {
        let name = "com.ipbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("defaults are sane on first launch")
    func firstLaunch() {
        let preferences = Preferences(defaults: scratchDefaults())
        #expect(preferences.displaySource == .publicAddress)
        #expect(preferences.showVPNIndicator)
        #expect(preferences.namesReplaceAddresses)
        #expect(preferences.refreshMinutes == 10)
        #expect(preferences.labels.isEmpty)
    }

    @Test("labels survive a round trip")
    func labelRoundTrip() {
        let defaults = scratchDefaults()
        let first = Preferences(defaults: defaults)
        first.labels = [
            AddressLabel(pattern: "203.0.113.42", name: "Office static", scope: .publicAddress),
            AddressLabel(pattern: "192.168.1.0/24", name: "Home LAN", scope: .localAddress)
        ]
        first.displaySource = .both
        first.refreshMinutes = 30

        let second = Preferences(defaults: defaults)
        #expect(second.labels.count == 2)
        #expect(second.labels.name(for: "203.0.113.42", scope: .publicAddress) == "Office static")
        #expect(second.labels.name(for: "192.168.1.77", scope: .localAddress) == "Home LAN")
        #expect(second.displaySource == .both)
        #expect(second.refreshMinutes == 30)
    }

    @Test("an invalid pattern persists but never matches")
    func invalidPatternPersists() {
        let defaults = scratchDefaults()
        let first = Preferences(defaults: defaults)
        first.labels = [AddressLabel(pattern: "typo-here", name: "Oops")]

        let second = Preferences(defaults: defaults)
        // Kept so the user can correct it in Settings rather than losing the row.
        #expect(second.labels.count == 1)
        #expect(second.labels.first?.isValid == false)
        #expect(second.labels.name(for: "1.2.3.4", scope: .publicAddress) == nil)
    }
}
