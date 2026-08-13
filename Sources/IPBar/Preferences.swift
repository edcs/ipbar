import Foundation
import Observation
import ServiceManagement

/// What the menu bar makes of an address that has a name.
///
/// A toggle called "show name instead of address" hid the middle option in its
/// off state, so the choice is spelled out.
enum NameDisplay: String, CaseIterable, Codable, Sendable {
    case name, nameAndAddress, address

    var title: String {
        switch self {
        case .name: return "Name"
        case .nameAndAddress: return "Name and address"
        case .address: return "Address"
        }
    }
}

enum DisplaySource: String, CaseIterable, Codable, Sendable {
    case publicAddress, localAddress, both

    var title: String {
        switch self {
        case .publicAddress: return "Public IP"
        case .localAddress: return "Local IP"
        case .both: return "Local · Public"
        }
    }
}

@MainActor
@Observable
final class Preferences {
    var displaySource: DisplaySource { didSet { write(displaySource.rawValue, .displaySource) } }
    var preferIPv6: Bool { didSet { write(preferIPv6, .preferIPv6) } }
    var showVPNIndicator: Bool { didSet { write(showVPNIndicator, .showVPNIndicator) } }
    var showFlagInMenuBar: Bool { didSet { write(showFlagInMenuBar, .showFlagInMenuBar) } }
    var mutedFlag: Bool { didSet { write(mutedFlag, .mutedFlag) } }
    var nameDisplay: NameDisplay { didSet { write(nameDisplay.rawValue, .nameDisplay) } }
    var refreshMinutes: Int { didSet { write(refreshMinutes, .refreshMinutes) } }

    var labels: [AddressLabel] {
        didSet {
            guard let data = try? JSONEncoder().encode(labels) else { return }
            defaults.set(data, forKey: Key.labels.rawValue)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("IPBar: could not update login item — \(error.localizedDescription)")
            }
        }
    }

    private enum Key: String {
        case displaySource, preferIPv6, showVPNIndicator, nameDisplay, refreshMinutes, labels
        case showFlagInMenuBar, mutedFlag
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displaySource = (defaults.string(forKey: Key.displaySource.rawValue)
            .flatMap(DisplaySource.init(rawValue:))) ?? .publicAddress
        preferIPv6 = defaults.bool(forKey: Key.preferIPv6.rawValue)
        showVPNIndicator = defaults.object(forKey: Key.showVPNIndicator.rawValue) as? Bool ?? true
        showFlagInMenuBar = defaults.object(forKey: Key.showFlagInMenuBar.rawValue) as? Bool ?? true
        mutedFlag = defaults.object(forKey: Key.mutedFlag.rawValue) as? Bool ?? false
        nameDisplay = (defaults.string(forKey: Key.nameDisplay.rawValue)
            .flatMap(NameDisplay.init(rawValue:))) ?? .name
        refreshMinutes = defaults.object(forKey: Key.refreshMinutes.rawValue) as? Int ?? 10
        labels = (defaults.data(forKey: Key.labels.rawValue))
            .flatMap { try? JSONDecoder().decode([AddressLabel].self, from: $0) } ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func write(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
