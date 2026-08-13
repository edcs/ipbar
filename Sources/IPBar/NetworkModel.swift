import AppKit
import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkModel {
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var vpn = VPNState()
    private(set) var publicIPv4: String?
    private(set) var publicIPv6: String?
    private(set) var country: String?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    private let preferences: Preferences
    private let publicIP = PublicIPService()
    private let monitor = NWPathMonitor()
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Display

    /// The local address we consider "the" one: whatever holds the default
    /// route, falling back to the first physical interface.
    var primaryLocal: NetworkInterface? {
        let family: NetworkInterface.Family = preferences.preferIPv6 ? .ipv6 : .ipv4
        let candidates = interfaces.filter { $0.family == family && !$0.isLinkLocal && $0.kind != .loopback }
        if let primary = InterfaceScanner.primaryInterface(family: family),
           let match = candidates.first(where: { $0.bsdName == primary }) {
            return match
        }
        return candidates.first { $0.kind.isPhysical } ?? candidates.first
    }

    var primaryPublic: String? {
        preferences.preferIPv6 ? (publicIPv6 ?? publicIPv4) : (publicIPv4 ?? publicIPv6)
    }

    /// Local addresses grouped by interface, so "Wi-Fi" is stated once rather
    /// than repeated against every address it holds.
    struct InterfaceGroup: Identifiable {
        let id: String
        let addresses: [NetworkInterface]
    }

    var localGroups: [InterfaceGroup] {
        Self.groups(from: interfaces, collapsing: [publicIPv4, publicIPv6].compactMap { $0 })
    }

    /// Groups local addresses, leaving out any that are also the public
    /// address.
    ///
    /// IPv6 has no NAT, so this Mac's global address *is* the public one and
    /// would otherwise be listed twice. It is shown once, in the public
    /// section, badged with the interface holding it. A group left with nothing
    /// is dropped rather than shown empty.
    static func groups(from interfaces: [NetworkInterface],
                       collapsing publicAddresses: [String]) -> [InterfaceGroup] {
        let collapsed = Set(publicAddresses)
        let usable = interfaces.filter {
            $0.kind != .loopback && $0.kind != .virtual && !$0.isLinkLocal
                && !collapsed.contains($0.address)
        }

        return Dictionary(grouping: usable, by: \.label)
            .map { InterfaceGroup(id: $0.key,
                                  addresses: $0.value.sorted { $0.family.rawValue < $1.family.rawValue }) }
            .filter { !$0.addresses.isEmpty }
            .sorted { $0.id < $1.id }
    }

    /// The interface holding this address, when this Mac holds it directly.
    /// Lets a collapsed public address still say where it lives.
    func interfaceHolding(_ address: String) -> String? {
        interfaces.first { $0.address == address && $0.kind != .loopback }?.label
    }

    /// True when a local address is the one the outside world actually sees.
    ///
    /// macOS gives an interface both a stable and a temporary IPv6, which
    /// otherwise appear as two identical rows. Matching against the public
    /// address says which of them traffic is leaving from, which is more use
    /// than labelling one "temporary".
    func isEgress(_ address: String) -> Bool {
        address == publicIPv4 || address == publicIPv6
    }

    func name(for address: String, scope: AddressLabel.Scope) -> String? {
        preferences.labels.name(for: address, scope: scope)
    }

    /// Applies a matching label, either replacing the address or annotating it.
    func display(_ address: String?, scope: AddressLabel.Scope) -> String? {
        guard let address else { return nil }
        guard let name = name(for: address, scope: scope) else { return address }
        return preferences.namesReplaceAddresses ? name : "\(name) (\(address))"
    }

    var menuBarText: String {
        let local = display(primaryLocal?.address, scope: .localAddress)
        let remote = display(primaryPublic, scope: .publicAddress)

        switch preferences.displaySource {
        case .publicAddress: return remote ?? local ?? "No network"
        case .localAddress: return local ?? "No network"
        case .both:
            let parts = [local, remote].compactMap { $0 }
            return parts.isEmpty ? "No network" : parts.joined(separator: " · ")
        }
    }

    /// Trails the flag as plain text rather than a padlock. A lock beside a
    /// flag is a lot of iconography for one fact, and "(VPN)" says it outright.
    var menuBarVPNLabel: String? {
        guard preferences.showVPNIndicator, vpn.isActive else { return nil }
        return "(VPN)"
    }

    /// What trails the address in the menu bar.
    ///
    /// A flag describes where the *public* address is, so showing one beside a
    /// local address states something untrue about it. A local address gets the
    /// interface it belongs to instead, which is the equivalent fact about it.
    var menuBarQualifier: MenuBarGlyph.Qualifier {
        guard preferences.showFlagInMenuBar else { return .none }

        switch preferences.displaySource {
        case .localAddress:
            guard primaryLocal != nil else { return .none }
            return .interface(MenuBarGlyph.localNetworkSymbol)
        case .publicAddress, .both:
            // Falls back to the local address when the public one is unknown,
            // so the flag has to go with it.
            guard primaryPublic != nil, let country else { return .none }
            return .country(country)
        }
    }

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(debounce: .milliseconds(600)) }
        }
        monitor.start(queue: DispatchQueue(label: "com.ipbar.path"))

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(debounce: .seconds(2)) }
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.preferences.refreshMinutes ?? 10
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
                guard !Task.isCancelled else { return }
                self?.scheduleRefresh(debounce: .zero)
            }
        }

        scheduleRefresh(debounce: .zero)
    }

    func scheduleRefresh(debounce: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            await self?.refresh()
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Local state is cheap and synchronous — publish it before the network
        // round trip so the menu bar reacts immediately on a link change.
        let scanned = InterfaceScanner.scan()
        interfaces = scanned
        vpn = VPNState.detect(interfaces: scanned)

        async let v4 = publicIP.fetch(.ipv4)
        async let v6 = publicIP.fetch(.ipv6)
        let (fetchedV4, fetchedV6) = await (v4, v6)
        guard !Task.isCancelled else { return }

        publicIPv4 = fetchedV4?.address
        publicIPv6 = fetchedV6?.address
        country = fetchedV4?.country ?? fetchedV6?.country
        lastUpdated = Date()
    }
}
