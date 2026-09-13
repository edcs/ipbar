import Foundation
import Testing
@testable import IPBar

/// Records what would have been shown, so nothing reaches the real
/// notification centre — which, with no bundle under `swift test`, would
/// abort the run rather than fail a test.
actor SpyNotifier: Notifier {
    private(set) var posted: [(change: NetworkChange, name: String?)] = []
    private let granted: Bool

    init(granted: Bool = true) { self.granted = granted }

    func requestAuthorization() async -> Bool { granted }
    func authorizationStatus() async -> NotifierAuthorization {
        granted ? .authorized : .denied
    }
    func post(_ change: NetworkChange, newAddressName: String?) async {
        posted.append((change, newAddressName))
    }
    var changes: [NetworkChange] { posted.map(\.change) }
}

@Suite("Confirming a change before announcing it")
@MainActor
struct ConfirmationTests {
    private func model(vpn: Bool = true, ip: Bool = true,
                       notifier: SpyNotifier, delay: Duration = .zero) -> NetworkModel {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let preferences = Preferences(defaults: defaults)
        preferences.notifyOnVPNWeakened = vpn
        preferences.notifyOnPublicIPChange = ip

        return NetworkModel(preferences: preferences,
                            gateway: { _ in nil },
                            notifier: notifier,
                            confirmationDelay: delay)
    }

    private func snap(_ ip: String?, _ vpn: VPNState.Mode) -> NetworkSnapshot {
        NetworkSnapshot(publicIP: ip, vpn: vpn)
    }

    @Test("the first observation announces nothing")
    func firstObservation() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a real drop is announced")
    func realDrop() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .off)])
    }

    @Test("a partial recovery is announced as what it actually is")
    func partialRecovery() async {
        // full → off → split must announce full → split, not the stale full → off.
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .split))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .split)])
    }

    @Test("an address change survives a gap with no internet")
    func addressChangeAcrossGap() async {
        // X → nil → Y is a change. The baseline must survive the nil rather
        // than being cleared by it, or the notification has no "from".
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap(nil, .off))
        #expect(await spy.changes.isEmpty)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes
                == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("coming back on the same address announces nothing")
    func sameAddressAcrossGap() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap(nil, .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a disabled toggle silences its own change only")
    func togglesGateIndependently() async {
        let spy = SpyNotifier()
        let model = self.model(vpn: false, ip: true, notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes
                == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("both toggles off means nothing is ever posted")
    func bothOff() async {
        let spy = SpyNotifier()
        let model = self.model(vpn: false, ip: false, notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a named new address is named in the notification")
    func namedAddress() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        model.preferencesForTesting.labels = [
            AddressLabel(pattern: "203.0.113.42", name: "Home", scope: .publicAddress)
        ]
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.posted.first?.name == "Home")
    }

    @Test("successive changes each get announced once")
    func successiveChanges() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        // The baseline advances after posting, so a state that has already
        // been announced is not announced again on every later refresh.
        #expect(await spy.changes.count == 1)
    }

    // MARK: - The real Task-based window

    // A zero delay takes the synchronous branch in `noteChanges`, which never
    // assigns `confirmationTask` at all. The tests below run with a real, if
    // short, delay so the scheduled `Task` actually executes and `confirm`
    // re-measures at close rather than replaying the snapshot the window
    // opened on.

    @Test("a change posts after the delay, not before")
    func postsAfterDelayNotBefore() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy, delay: .milliseconds(50))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        #expect(await spy.changes.isEmpty)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .off)])
    }

    @Test("a second change mid-window does not open a second window or double-post")
    func secondChangeMidWindowDoesNotDoublePost() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy, delay: .milliseconds(50))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        // Still inside the first window: this must not start a second one.
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .split))

        try? await Task.sleep(for: .milliseconds(150))
        // Not just one post — the *right* one: the window must re-measure at
        // close and report the split it was last actually given, not the
        // stale off it opened on.
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .split)])
    }

    @Test("a blip that heals during the window is never announced")
    func blipHeals() async {
        // full → off → full, with the window still open when the last full
        // arrives. Production re-measures at close and sees full → full,
        // which is not a weakening at all — so nothing should be posted.
        // Against a seam that replays the stale opening snapshot instead,
        // this posts "VPN disconnected": the exact false alarm the
        // confirmation window exists to prevent.
        let spy = SpyNotifier()
        let model = self.model(notifier: spy, delay: .milliseconds(50))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a partial recovery mid-window is announced as what it actually is")
    func partialRecoveryMidWindow() async {
        // full → off → split, with the window still open when the split
        // arrives. Close must report full → split, not the stale full → off
        // first seen when the window opened.
        let spy = SpyNotifier()
        let model = self.model(notifier: spy, delay: .milliseconds(50))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .split))

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .split)])
    }

    @Test("a toggle switched off mid-window suppresses its notification")
    func toggleOffMidWindowSuppressesNotification() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy, delay: .milliseconds(50))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        model.preferencesForTesting.notifyOnVPNWeakened = false

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await spy.changes.isEmpty)
    }
}
