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

    /// The network this Mac is on. Read both before and after the public-IP
    /// fetch: before, so a warm ARP cache names it immediately rather than
    /// waiting on the fetch; after, because the fetch's own traffic is what
    /// populates the gateway's ARP entry when the interface was cold.
    private(set) var networkKey: NetworkKey?

    private let preferences: Preferences
    private let publicIP = PublicIPService()
    private let monitor = NWPathMonitor()
    private let gateway: @Sendable ([NetworkInterface]) -> NetworkKey?
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    private let notifier: Notifier
    private let confirmationDelay: Duration
    /// The state a pending change is measured against.
    ///
    /// Frozen while a confirmation window is open — advancing it mid-window
    /// would compare the change against itself and always come out silent.
    private var notificationBaseline: NetworkSnapshot?
    /// The most recent snapshot `noteChanges` was given, updated on every call
    /// regardless of whether a window is open.
    ///
    /// `confirm(rescan: false)` reads this at close rather than whatever was
    /// current when the window *opened* — mirroring `rescan: true`, which
    /// always re-measures at close. Tests drive this by calling
    /// `noteChangesForTesting` again mid-window instead of a live rescan.
    private var latestObserved: NetworkSnapshot?
    private var confirmationTask: Task<Void, Never>?

    init(preferences: Preferences,
         gateway: @escaping @Sendable ([NetworkInterface]) -> NetworkKey? = GatewayScanner.current,
         notifier: Notifier = SystemNotifier(),
         confirmationDelay: Duration = .seconds(10)) {
        self.preferences = preferences
        self.gateway = gateway
        self.notifier = notifier
        self.confirmationDelay = confirmationDelay
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
        preferences.labels.name(for: address, scope: scope, networkKey: networkKey)
    }

    /// The name of the network currently attached, for the panel's context row.
    var networkName: String? {
        guard let networkKey else { return nil }
        let match = preferences.labels.first {
            if case .network(let gateway, _) = $0.key { return gateway == networkKey.gateway }
            return false
        }
        let trimmed = match?.name.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Applies a matching label, however the menu bar has been asked to show
    /// named addresses. An address with no name is always just the address.
    func display(_ address: String?, scope: AddressLabel.Scope) -> String? {
        guard let address else { return nil }
        guard preferences.nameDisplay != .address,
              let name = name(for: address, scope: scope) else { return address }

        switch preferences.nameDisplay {
        case .name: return name
        case .nameAndAddress: return "\(name) (\(address))"
        case .address: return address
        }
    }

    var menuBarText: String {
        let local = display(primaryLocal?.address, scope: .localAddress)
        let remote = display(primaryPublic, scope: .publicAddress)

        switch preferences.displaySource {
        case .publicAddress: return remote ?? local ?? "No network"
        case .localAddress: return local ?? "No network"
        case .both:
            let parts = [local, remote].compactMap { $0 }
            // A network name resolves for both halves, which would otherwise
            // read "Home · Home".
            if parts.count == 2, parts[0] == parts[1] { return parts[0] }
            return parts.isEmpty ? "No network" : parts.joined(separator: " · ")
        }
    }

    /// Trails the flag as an outlined badge rather than a padlock. A lock beside a
    /// flag is a lot of iconography for one fact, and the word says it outright.
    var menuBarVPNLabel: String? {
        guard preferences.showVPNIndicator, vpn.isActive else { return nil }
        return "VPN"
    }

    /// On a network, but the internet is out of reach.
    ///
    /// Only true once a lookup has actually finished and failed. While one is
    /// in flight the previous answer still stands, so a slow check never
    /// flickers into looking like an outage.
    var isOffline: Bool {
        lastUpdated != nil && publicIPv4 == nil && publicIPv6 == nil
    }

    /// What trails the address in the menu bar.
    ///
    /// A flag describes where the *public* address is, so showing one beside a
    /// local address states something untrue about it. A local address gets the
    /// interface it belongs to instead, which is the equivalent fact about it.
    var menuBarQualifier: MenuBarGlyph.Qualifier {
        // Checked before the flag setting, and deliberately: this is a status
        // rather than decoration. With no public address the menu bar falls
        // back to showing a local one, which looks like a working connection
        // unless something says otherwise.
        if preferences.displaySource != .localAddress, isOffline, primaryLocal != nil {
            return .offline
        }
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

    /// Fills the model with the addresses reserved for documentation, so the
    /// screenshots in the README show what the app looks like without
    /// publishing whoever generated them.
    ///
    /// 203.0.113.0/24 is RFC 5737's documentation range and 2001:db8::/32 is
    /// RFC 3849's. Neither routes anywhere.
    func loadSampleData() {
        interfaces = [
            NetworkInterface(bsdName: "en0", address: "192.168.1.77", family: .ipv4,
                             kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi"),
            NetworkInterface(bsdName: "en0", address: "2001:db8:1738:0:1cc1:3c0c:9659:e927",
                             family: .ipv6, kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi"),
            NetworkInterface(bsdName: "en0", address: "2001:db8:1738:0:870:ca09:920c:ef6c",
                             family: .ipv6, kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi")
        ]
        publicIPv4 = "203.0.113.42"
        publicIPv6 = "2001:db8:1738:0:870:ca09:920c:ef6c"
        country = "GB"
        vpn = VPNState()
        lastUpdated = Date()
        isRefreshing = false
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

        // Before the fetch too: on a named LAN with no internet the fetch
        // below has to time out before it reads again, and a warm ARP cache
        // already has everything this needs — read it now so the name isn't
        // held back up to 8s waiting on a lookup it doesn't depend on.
        networkKey = await currentNetworkKey(for: scanned)

        async let v4 = publicIP.fetch(.ipv4)
        async let v6 = publicIP.fetch(.ipv6)
        let (fetchedV4, fetchedV6) = await (v4, v6)
        guard !Task.isCancelled else { return }

        publicIPv4 = fetchedV4?.address
        publicIPv6 = fetchedV6?.address
        country = fetchedV4?.country ?? fetchedV6?.country
        lastUpdated = Date()

        // After the fetch too, deliberately: on a cold interface the lookup's
        // own traffic is what populates the gateway's ARP entry, so this read
        // can find a key the one above missed. Keep both — removing either
        // reopens the gap the other exists to close.
        networkKey = await currentNetworkKey(for: scanned)

        await noteChanges(current: NetworkSnapshot(publicIP: primaryPublic, vpn: vpn.mode),
                          rescan: true)
    }

    /// Reads the gateway off the main actor.
    ///
    /// The closure fans out to two `SCDynamicStoreCreate` calls, a regex key
    /// list, N `CopyValue` calls and two `sysctl`s — cheap individually, but
    /// enough to stall the menu bar on IPC if run inline here, especially
    /// right after wake while configd is still settling.
    private func currentNetworkKey(for scanned: [NetworkInterface]) async -> NetworkKey? {
        let gateway = self.gateway
        return await Task.detached { gateway(scanned) }.value
    }

    /// Sets the state the menu bar is derived from, without touching the
    /// network. Used by tests only.
    func applyForTesting(publicIPv4: String?, local: String?, key: NetworkKey?) {
        interfaces = local.map {
            [NetworkInterface(bsdName: "en0", address: $0, family: .ipv4,
                              kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi")]
        } ?? []
        self.publicIPv4 = publicIPv4
        self.publicIPv6 = nil
        self.networkKey = key
        self.lastUpdated = Date()
    }

    /// Drives change detection with a supplied snapshot, skipping the network.
    /// Used by tests only.
    func noteChangesForTesting(snapshot: NetworkSnapshot) async {
        await noteChanges(current: snapshot, rescan: false)
    }

    /// Used by tests only, to install labels the notification wording reads.
    var preferencesForTesting: Preferences { preferences }

    // MARK: - Change notifications

    /// Compares the current state with the baseline and, if anything is worth
    /// announcing, opens a confirmation window.
    ///
    /// One window covers every change, not one window per change: two facts do
    /// not justify two timers. A change arriving mid-window is confirmed by the
    /// existing deadline, so it gets less than the full delay — sooner than the
    /// first, never later.
    private func noteChanges(current: NetworkSnapshot, rescan: Bool) async {
        latestObserved = current

        guard let baseline = notificationBaseline else {
            notificationBaseline = current
            return
        }

        // A window is already open; it will pick this state up when it closes.
        guard confirmationTask == nil else { return }

        let pending = enabled(ChangeDetector.changes(from: baseline, to: current))
        guard !pending.isEmpty else {
            advanceBaseline(to: current)
            return
        }

        guard confirmationDelay > .zero else {
            await confirm(rescan: rescan)
            return
        }

        confirmationTask = Task { [weak self] in
            // Cleared here, in the task body, rather than in a `defer` inside
            // `confirm`: every exit from this task — including the cancelled
            // path below, which never reaches `confirm` — must clear the
            // handle. Otherwise `noteChanges`'s `guard confirmationTask == nil`
            // stays blocked forever.
            defer { self?.confirmationTask = nil }
            try? await Task.sleep(for: self?.confirmationDelay ?? .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.confirm(rescan: rescan)
        }
    }

    /// Re-measures against the frozen baseline and posts whatever still holds.
    ///
    /// A VPN that dropped and came back re-evaluates as no change at all; one
    /// that dropped and half-recovered re-evaluates as the weakening it
    /// actually is, rather than the stale one first seen.
    private func confirm(rescan: Bool) async {
        guard let baseline = notificationBaseline else { return }

        // Re-scan rather than trust state that may be ten seconds old. Both calls
        // are synchronous, cheap, and touch no network. Tests pass rescan: false,
        // where `latestObserved` — whatever `noteChangesForTesting` was last
        // given, including a call made mid-window — stands in for the live
        // rescan, so they never read the developer's own VPN state.
        let current: NetworkSnapshot
        if rescan {
            let mode = VPNState.detect(interfaces: InterfaceScanner.scan()).mode
            current = NetworkSnapshot(publicIP: primaryPublic, vpn: mode)
        } else {
            current = latestObserved ?? baseline
        }

        for change in enabled(ChangeDetector.changes(from: baseline, to: current)) {
            let name: String?
            if case .publicIPChanged(_, let to) = change {
                name = preferences.labels.name(for: to, scope: .publicAddress,
                                               networkKey: networkKey)
            } else {
                name = nil
            }
            await notifier.post(change, newAddressName: name)
        }

        advanceBaseline(to: current)
    }

    /// A nil address never becomes a baseline: losing the internet is not an
    /// address changing, and clearing it would lose the "from" that a later
    /// notification has to name.
    private func advanceBaseline(to current: NetworkSnapshot) {
        notificationBaseline = NetworkSnapshot(
            publicIP: current.publicIP ?? notificationBaseline?.publicIP,
            vpn: current.vpn)
    }

    /// Drops changes whose toggle is off. Applied when deciding to open a
    /// window and again when it closes, so a toggle switched off midway is
    /// honoured rather than racing the deadline.
    private func enabled(_ changes: [NetworkChange]) -> [NetworkChange] {
        changes.filter {
            switch $0 {
            case .vpnWeakened: return preferences.notifyOnVPNWeakened
            case .publicIPChanged: return preferences.notifyOnPublicIPChange
            }
        }
    }
}
