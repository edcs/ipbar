import Foundation
import Testing
@testable import IPBar

@Suite("Offering the sign-in page")
@MainActor
struct SignInPageTests {
    private func model() -> NetworkModel {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return NetworkModel(preferences: Preferences(defaults: defaults),
                            gateway: { _ in nil })
    }

    @Test("offered when on a network that cannot reach the internet")
    func onNetworkNoInternet() {
        // The panel already says a sign-in page is the usual cause. This is
        // the state where offering to open one is a fix rather than a guess.
        let model = self.model()
        model.applyForTesting(publicIPv4: nil, local: "192.168.1.77", key: nil)
        #expect(model.canOpenSignInPage)
    }

    @Test("not offered with no network at all")
    func noNetwork() {
        // Nothing to sign in to. The panel's own message here is "turn Wi-Fi
        // on or plug a cable in", and a sign-in button beside it would be noise.
        let model = self.model()
        model.applyForTesting(publicIPv4: nil, local: nil, key: nil)
        #expect(!model.canOpenSignInPage)
    }

    @Test("not offered when the internet is reachable")
    func online() {
        let model = self.model()
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: nil)
        #expect(!model.canOpenSignInPage)
    }

    @Test("not offered before the first lookup has finished")
    func neverChecked() {
        // isOffline is only true once a lookup has finished and failed, so a
        // slow first check must not flash a sign-in button.
        #expect(!model().canOpenSignInPage)
    }
}

@Suite("What the network is reached through")
@MainActor
struct NetworkFactsTests {
    private func model(_ facts: NetworkFacts) -> NetworkModel {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return NetworkModel(preferences: Preferences(defaults: defaults),
                            gateway: { _ in nil },
                            facts: { _ in facts })
    }

    @Test("the router and every resolver are exposed")
    func exposesFacts() {
        let model = self.model(NetworkFacts(router: "192.168.1.1",
                                            dns: ["192.168.1.1", "2a06:61c2::1"]))
        model.applyFactsForTesting()
        #expect(model.router == "192.168.1.1")
        #expect(model.dnsServers == ["192.168.1.1", "2a06:61c2::1"])
    }

    @Test("all resolvers are listed, not just the first")
    func listsEveryResolver() {
        // A machine with three resolvers has three, and the panel should say
        // so rather than implying there is one.
        let model = self.model(NetworkFacts(router: "10.0.0.1",
                                            dns: ["10.0.0.1", "1.1.1.1", "8.8.8.8"]))
        model.applyFactsForTesting()
        #expect(model.dnsServers.count == 3)
    }

    @Test("a network with no router or resolvers reads as empty, not as zeroes")
    func nothingKnown() {
        let model = self.model(NetworkFacts(router: nil, dns: []))
        model.applyFactsForTesting()
        #expect(model.router == nil)
        #expect(model.dnsServers.isEmpty)
    }
}
