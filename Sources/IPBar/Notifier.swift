import Foundation
import UserNotifications

/// Whether this app can notify, and whether it has been allowed to.
enum NotifierAuthorization: Sendable {
    /// No bundle, so the notification centre cannot be reached at all.
    case unavailable
    case notDetermined
    case authorized
    case denied
}

protocol Notifier: Sendable {
    /// Asks the user. Returns whether notifications may now be posted.
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotifierAuthorization
    func post(_ change: NetworkChange, newAddressName: String?) async
}

extension NetworkChange {
    var notificationTitle: String {
        switch self {
        case .vpnWeakened(_, let to):
            return to == .off ? "VPN disconnected" : "VPN no longer carrying all traffic"
        case .publicIPChanged:
            return "Public IP changed"
        }
    }

    /// `newAddressName` is resolved by the caller, so nothing here needs to
    /// know about stored labels. It is ignored for VPN changes, which describe
    /// the tunnel rather than an address.
    func notificationBody(newAddressName: String?) -> String {
        switch self {
        case .vpnWeakened(let from, let to):
            switch (from, to) {
            case (.full, .off): return "All traffic is now in the clear"
            case (.full, .split): return "Some traffic is now in the clear"
            default: return "No tunnel is up"
            }
        case .publicIPChanged(let from, let to):
            let arrival = newAddressName.map { "\($0) (\(to))" } ?? to
            return "\(from) → \(arrival)"
        }
    }
}

/// The real thing, guarded.
///
/// `UNUserNotificationCenter.current()` raises `NSInternalInconsistencyException`
/// when the process has no bundle identifier — an Objective-C exception with no
/// Swift `catch`, so the process aborts. `swift run` and `swift test` both run
/// without a bundle, which makes checking first the only available defence
/// rather than a courtesy. Without a bundle this type does nothing at all.
struct SystemNotifier: Notifier {
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])
        return granted ?? false
    }

    func authorizationStatus() async -> NotifierAuthorization {
        guard isAvailable else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func post(_ change: NetworkChange, newAddressName: String?) async {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = change.notificationTitle
        content.body = change.notificationBody(newAddressName: newAddressName)

        // No sound, no badge, no action. There is nothing useful to open —
        // MenuBarExtra cannot be opened programmatically, and Settings is not
        // where anyone would want to land.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
