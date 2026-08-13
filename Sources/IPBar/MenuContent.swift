import AppKit
import SwiftUI

/// The panel that opens from the menu bar.
///
/// Addresses are the content, so each row leads with the address set in
/// monospace at full width, with a quiet caption above it. The previous
/// fixed-width label column pushed addresses into the middle of the panel and
/// forced IPv6 to truncate; giving the row two lines lets a full IPv6 address
/// sit on one line and removes the column of repeated copy buttons, since the
/// whole row is now the copy target.
struct MenuContent: View {
    @Bindable var model: NetworkModel
    @Bindable var preferences: Preferences
    @Environment(\.openWindow) private var openWindow

    @State private var copied: String?
    @State private var resetTask: Task<Void, Never>?
    @State private var hovered: String?
    @State private var editing: String?
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                publicSection
                localSection
            }
            .padding(.vertical, 10)

            Divider()
            vpnRow
            Divider()
            footer
        }
        // Wide enough for a full IPv6 plus the "in use" badge on one line:
        // the address measures 278pt at this size, and truncating it would
        // defeat the point of giving the row two lines.
        .frame(width: 358)
    }

    // MARK: - Sections

    private var publicSection: some View {
        Group {
            sectionHeader("Public") {
                if let country = model.country {
                    // Flag last here too, so it lands in the same right-hand
                    // column as the badges and the VPN symbol below.
                    HStack(spacing: 4) {
                        Text(country)
                            .font(.system(size: 10, weight: .semibold))
                            .monospaced()
                            .foregroundStyle(.secondary)
                        // Always shown here: the panel is where you come to
                        // read the addresses, so the flag belongs with them.
                        FlagImage(country: country, height: 9,
                                  muted: preferences.mutedFlag)
                    }
                    .help(Locale.current.localizedString(forRegionCode: country)
                          .map { "Your public address is in \($0)" } ?? "Country of your public address")
                }
            }

            if model.publicIPv4 == nil && model.publicIPv6 == nil {
                placeholder(model.isRefreshing
                            ? "Looking up your public address…"
                            : "Can't reach the internet right now.")
            } else {
                if let address = model.publicIPv4 {
                    row(kind: "IPv4", address: address, scope: .publicAddress)
                }
                if let address = model.publicIPv6 {
                    row(kind: "IPv6", address: address, scope: .publicAddress)
                }
            }
        }
    }

    private var localSection: some View {
        Group {
            sectionHeader("This Mac") { EmptyView() }

            if model.localGroups.isEmpty {
                placeholder("No active network interfaces.")
            } else {
                ForEach(model.localGroups) { group in
                    Text(group.id)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 1)

                    ForEach(group.addresses) { interface in
                        row(kind: interface.family.rawValue,
                            address: interface.address,
                            scope: .localAddress,
                            inUse: model.isEgress(interface.address))
                    }
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    // MARK: - Address row

    private func row(kind: String, address: String,
                     scope: AddressLabel.Scope, inUse: Bool = false) -> some View {
        Group {
            if editing == address {
                nameEditor(address: address, scope: scope)
            } else {
                addressRow(kind: kind, address: address, scope: scope, inUse: inUse)
            }
        }
        .padding(.horizontal, 4)
    }

    /// A named address puts the name first and demotes the address, because
    /// naming is the point of the app. It is the only place colour appears.
    private func addressRow(kind: String, address: String,
                            scope: AddressLabel.Scope, inUse: Bool) -> some View {
        let name = model.name(for: address, scope: scope)
        let justCopied = copied == address
        let isHovered = hovered == address

        return Button {
            copy(address)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let name {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                    } else {
                        Text(kind)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    // Hidden while hovering, where the naming button sits.
                    if name != nil, !isHovered {
                        Text(kind).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }

                // "in use" and the copy confirmation both describe the address,
                // so they sit on its line rather than up beside the label.
                HStack(spacing: 6) {
                    Text(address)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(name == nil ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if justCopied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    } else if inUse {
                        badge("in use")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        // Sits above the row rather than inside it: a control nested in a
        // Button's label never receives the click.
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(name == nil ? "Name" : "Rename") {
                    beginNaming(address, existing: name)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.accent)
                .padding(.trailing, 10)
                .padding(.top, 6)
            }
        }
        .onHover { inside in
            if inside { hovered = address } else if hovered == address { hovered = nil }
        }
        .contextMenu {
            Button("Copy Address") { copy(address) }
            Button(name == nil ? "Name This Address…" : "Rename…") {
                beginNaming(address, existing: name)
            }
            if hasOwnLabel(address, scope: scope) {
                Divider()
                Button("Remove Name") { removeName(address, scope: scope) }
            }
        }
        .help("Copy \(address)")
        .accessibilityLabel("\(name ?? kind), \(address). Click to copy.")
    }

    /// Renaming in place, so the address never has to be typed out. The whole
    /// point of a name is not having to remember the number behind it.
    private func nameEditor(address: String, scope: AddressLabel.Scope) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                // Left at the default colour: amber marks a name that is set,
                // and a field being typed into is not one yet.
                TextField("Name this address", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($nameFieldFocused)
                    .onSubmit { commitName(address: address, scope: scope) }
                    .onExitCommand { cancelNaming() }

                Text("↩ save · esc cancel")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            Text(address)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        // Asking once is unreliable: on the first open the field is not yet in
        // the responder chain and the request is dropped, which is why a second
        // open appeared to work when the first did not. Keep asking briefly and
        // stop as soon as it takes.
        .task(id: address) {
            for _ in 0..<12 {
                if nameFieldFocused { return }
                nameFieldFocused = true
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            .help("The address the outside world sees traffic coming from")
    }

    // MARK: - VPN

    private var vpnRow: some View {
        // The symbol trails rather than leads: a leading icon column indented
        // this text 25pt further than every other row in the panel.
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.vpn.headline).font(.system(size: 12))
                if let detail = model.vpn.detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: model.vpn.symbol)
                .font(.system(size: 13))
                .foregroundStyle(model.vpn.isActive ? Palette.secure : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Refreshing and saying when it last happened are the same idea, so
            // the timestamp is the control rather than a label beside one.
            actionRow(model.isRefreshing ? "Checking…" : lastUpdatedText,
                      trailing: "arrow.clockwise", muted: true) {
                model.scheduleRefresh(debounce: .zero)
            }
            .disabled(model.isRefreshing)
            .help("Check again now")

            actionRow("Settings…") { openSettings() }
            actionRow("Quit IPBar") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 6)
    }

    /// One action per row, full width.
    ///
    /// Side by side they were two small targets with a stretch of dead panel
    /// between them; a row is the width of the panel and reads as a menu item.
    /// Left edges land at 14pt like every other row, and the icon trails like
    /// the VPN symbol above.
    private func actionRow(_ title: String, trailing: String? = nil, muted: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: muted ? 11 : 12))
                    .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 4)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.horizontal, 4)
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = model.lastUpdated else { return "Not checked yet" }
        let seconds = Int(Date().timeIntervalSince(lastUpdated))
        switch seconds {
        case ..<10: return "Updated just now"
        case ..<120: return "Updated \(seconds)s ago"
        case ..<7200: return "Updated \(seconds / 60)m ago"
        default: return "Updated \(seconds / 3600)h ago"
        }
    }

    // MARK: - Actions

    private func beginNaming(_ address: String, existing: String?) {
        draftName = existing ?? ""
        editing = address
    }

    private func cancelNaming() {
        editing = nil
        draftName = ""
    }

    private func commitName(address: String, scope: AddressLabel.Scope) {
        preferences.labels.setName(draftName, for: address, scope: scope)
        cancelNaming()
    }

    private func hasOwnLabel(_ address: String, scope: AddressLabel.Scope) -> Bool {
        preferences.labels.hasOwnLabel(for: address, scope: scope)
    }

    private func removeName(_ address: String, scope: AddressLabel.Scope) {
        preferences.labels.removeLabel(for: address, scope: scope)
    }

    private func copy(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)

        resetTask?.cancel()
        copied = address
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            copied = nil
        }
    }

    /// `SettingsLink` opens the window behind everything for an accessory app,
    /// which reads as the button doing nothing. Opening the window explicitly
    /// and activating lets it come to the front.
    private func openSettings() {
        openWindow(id: IPBarApp.settingsWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: - Style

enum Palette {
    /// Resolved per appearance: the icon's amber is legible on dark but fails
    /// contrast on a light panel, so light mode gets a darker shade.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.96, green: 0.71, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.39, blue: 0.02, alpha: 1)
    })

    static let secure = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.83, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.03, green: 0.42, blue: 0.60, alpha: 1)
    })
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                          ? AnyShapeStyle(.quaternary)
                          : (hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)))
            )
            .onHover { hovering = $0 }
    }
}
