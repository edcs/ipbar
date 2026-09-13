import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: NetworkModel
    @Bindable var preferences: Preferences

    @State private var authorization: NotifierAuthorization = .notDetermined
    private let notifier: Notifier = SystemNotifier()

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            names.tabItem { Label("Names", systemImage: "tag") }
        }
        .frame(width: 460, height: 380)
        .task {
            // Read on every open, so permission revoked in System Settings
            // since last time shows up here rather than leaving a toggle
            // quietly doing nothing.
            authorization = await notifier.authorizationStatus()
            // A toggle still reading "on" beside the warning row below is the
            // same fault as a menu bar that shows a local address as though
            // the internet were fine — the toggle is what asserts "this is
            // happening", and it cannot be, so it goes off with the
            // permission rather than next to a caption explaining it doesn't.
            if authorization == .denied {
                preferences.notifyOnVPNWeakened = false
                preferences.notifyOnPublicIPChange = false
            }
        }
    }

    /// Turning a toggle on is the only thing that ever asks for permission.
    ///
    /// A denial puts the toggle back rather than leaving it on and silent —
    /// a switch that claims to be doing something it cannot do is the same
    /// fault as a menu bar that shows a local address as though the internet
    /// were fine.
    private func requestPermissionIfNeeded(turnedOn: Bool,
                                           revert: @escaping @MainActor () -> Void) {
        guard turnedOn else { return }
        Task { @MainActor in
            let status = await notifier.authorizationStatus()
            guard status != .authorized else {
                authorization = status
                return
            }
            let granted = await notifier.requestAuthorization()
            authorization = await notifier.authorizationStatus()
            if !granted { revert() }
        }
    }

    private var general: some View {
        Form {
            Picker("Menu bar shows", selection: $preferences.displaySource) {
                ForEach(DisplaySource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Prefer IPv6", isOn: $preferences.preferIPv6)
            Toggle("Show VPN indicator", isOn: $preferences.showVPNIndicator)
            Toggle("Show flag in the menu bar", isOn: $preferences.showFlagInMenuBar)
                .help("A flag says where your public address is, so when the menu bar shows a local address it shows a local network icon instead")
            Toggle("Mute the flag", isOn: $preferences.mutedFlag)
                .help("Fades the flag so it reads as a label rather than the loudest thing on screen")
            Picker("Named addresses show", selection: $preferences.nameDisplay) {
                ForEach(NameDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("Only affects the menu bar. The panel always shows both.")
            Picker("Refresh every", selection: $preferences.refreshMinutes) {
                ForEach([1, 5, 10, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
            }
            Divider()
            Toggle("Notify me when my VPN drops", isOn: $preferences.notifyOnVPNWeakened)
                .help("Also when a full tunnel degrades to a partial one, which leaves some traffic in the clear without disconnecting")
                .onChange(of: preferences.notifyOnVPNWeakened) { _, new in
                    requestPermissionIfNeeded(turnedOn: new) {
                        preferences.notifyOnVPNWeakened = false
                    }
                }
            Toggle("Notify me when my public IP changes", isOn: $preferences.notifyOnPublicIPChange)
                .onChange(of: preferences.notifyOnPublicIPChange) { _, new in
                    requestPermissionIfNeeded(turnedOn: new) {
                        preferences.notifyOnPublicIPChange = false
                    }
                }

            if authorization == .denied {
                HStack {
                    Text("Notifications are turned off for IPBar in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") {
                        guard let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.notifications")
                        else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Divider()
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
        }
        .formStyle(.grouped)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("""
                 Give an address or range a name. IPBar shows the name in place of the \
                 address — useful for a static IP you recognise. Networks are named from \
                 the panel, since a gateway can only be read while you are on it.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(of: Binding<AddressLabel>.self) {
                TableColumn("Address, block or network") { $label in
                    if label.isNetwork {
                        // Captured when the network was named, not typed. A bare
                        // MAC is not something anyone can check, so the row shows
                        // where it was seen instead; --diagnose prints the key.
                        // A blank Name here leaves the network silently
                        // unlabelled everywhere it would otherwise show — the
                        // same signal an invalid address gets below.
                        Text(label.descriptor ?? "Network")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(label.isValid ? Color.secondary : Color.red)
                    } else {
                        TextField("203.0.113.42", text: $label.patternText)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(label.isValid || label.name.isEmpty
                                             ? Color.primary : Color.red)
                    }
                }
                TableColumn("Name") { $label in
                    TextField("Office", text: $label.name).textFieldStyle(.plain)
                }
                TableColumn("Applies to") { $label in
                    if label.isNetwork {
                        // A network name describes neither address, so it applies
                        // wherever and the choice would be a lie.
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $label.scope) {
                            ForEach(AddressLabel.Scope.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                }
            } rows: {
                ForEach($preferences.labels) { TableRow($0) }
            }

            HStack {
                Button {
                    preferences.labels.append(AddressLabel(pattern: suggestedPattern(), name: ""))
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if !preferences.labels.isEmpty { preferences.labels.removeLast() }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(preferences.labels.isEmpty)

                Spacer()
                Text("Most specific prefix wins.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// Pre-fill with the current public address — the common case is naming
    /// the network you're sitting on right now.
    private func suggestedPattern() -> String {
        model.primaryPublic ?? model.primaryLocal?.address ?? ""
    }
}
