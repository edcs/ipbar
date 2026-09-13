import Foundation
import Testing
@testable import IPBar

@Suite("What a notification says")
struct NotificationWordingTests {
    @Test("a tunnel that vanished says so plainly")
    func disconnected() {
        let change = NetworkChange.vpnWeakened(from: .full, to: .off)
        #expect(change.notificationTitle == "VPN disconnected")
        #expect(change.notificationBody(newAddressName: nil)
                == "All traffic is now in the clear")
    }

    @Test("a full tunnel degrading to split does not say dropped")
    func degraded() {
        // The tunnel is still up, so "dropped" would be untrue — but general
        // traffic is now unprotected, which is the point of saying anything.
        let change = NetworkChange.vpnWeakened(from: .full, to: .split)
        #expect(change.notificationTitle == "VPN no longer carrying all traffic")
        #expect(change.notificationBody(newAddressName: nil)
                == "Some traffic is now in the clear")
    }

    @Test("a split tunnel vanishing says no tunnel is up")
    func splitGone() {
        let change = NetworkChange.vpnWeakened(from: .split, to: .off)
        #expect(change.notificationTitle == "VPN disconnected")
        #expect(change.notificationBody(newAddressName: nil) == "No tunnel is up")
    }

    @Test("an address change shows both addresses")
    func addressChange() {
        let change = NetworkChange.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")
        #expect(change.notificationTitle == "Public IP changed")
        #expect(change.notificationBody(newAddressName: nil)
                == "203.0.113.41 → 203.0.113.42")
    }

    @Test("a named new address is named")
    func namedAddressChange() {
        let change = NetworkChange.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")
        #expect(change.notificationBody(newAddressName: "Home")
                == "203.0.113.41 → Home (203.0.113.42)")
    }

    @Test("a name is ignored for a VPN change")
    func nameIrrelevantToVPN() {
        let change = NetworkChange.vpnWeakened(from: .full, to: .off)
        #expect(change.notificationBody(newAddressName: "Home")
                == "All traffic is now in the clear")
    }
}

@Suite("The system notifier without a bundle")
struct SystemNotifierTests {
    @Test("swift test really does run without a bundle identifier")
    func noBundleUnderTest() {
        // The premise the next test rests on. If this ever becomes non-nil,
        // the test below stops proving anything and a real prompt becomes
        // possible during a test run.
        #expect(Bundle.main.bundleIdentifier == nil)
    }

    @Test("it is inert rather than fatal when there is no bundle")
    func inertWithoutBundle() async {
        // UNUserNotificationCenter.current() raises an Objective-C exception
        // without a bundle, which Swift cannot catch — so a missing guard
        // would not fail this test, it would abort the entire run.
        let notifier = SystemNotifier()
        await notifier.post(.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42"),
                            newAddressName: nil)
        #expect(await notifier.authorizationStatus() == .unavailable)
        #expect(await notifier.requestAuthorization() == false)
    }
}
