import SwiftUI

struct SettingsView: View {
    @Bindable var model: NetworkModel
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            names.tabItem { Label("Names", systemImage: "tag") }
        }
        .frame(width: 460, height: 380)
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
            Toggle("Show name instead of address", isOn: $preferences.namesReplaceAddresses)
            Picker("Refresh every", selection: $preferences.refreshMinutes) {
                ForEach([1, 5, 10, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
            }
            Divider()
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
        }
        .formStyle(.grouped)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give an address or range a name. IPBar shows the name in place of the address — useful for a static IP you recognise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(of: Binding<AddressLabel>.self) {
                TableColumn("Address or CIDR") { $label in
                    TextField("203.0.113.42", text: $label.pattern)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(label.prefix == nil ? Color.red : Color.primary)
                }
                TableColumn("Name") { $label in
                    TextField("Office", text: $label.name).textFieldStyle(.plain)
                }
                TableColumn("Applies to") { $label in
                    Picker("", selection: $label.scope) {
                        ForEach(AddressLabel.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
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
