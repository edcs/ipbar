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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    publicSection
                    localSection
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 460)

            Divider()
            vpnRow
            Divider()
            footer
        }
        .frame(width: 344)
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
                        if preferences.flagVisibility.showsInPanel {
                            // Sized against the 10pt header type beside it, not
                            // the larger body text elsewhere in the panel.
                            FlagImage(country: country, height: 9,
                                      muted: preferences.mutedFlag)
                        }
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

    /// A named address puts the name first and demotes the address, because
    /// naming is the point of the app. It is the only place colour appears.
    private func row(kind: String, address: String,
                     scope: AddressLabel.Scope, inUse: Bool = false) -> some View {
        let name = model.name(for: address, scope: scope)
        let justCopied = copied == address

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

                    if justCopied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    } else {
                        if name != nil {
                            Text(kind).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        if inUse { badge("in use") }
                    }
                }

                Text(address)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(name == nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.horizontal, 4)
        .help("Copy \(address)")
        .accessibilityLabel("\(name ?? kind), \(address). Click to copy.")
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
        VStack(alignment: .leading, spacing: 8) {
            // Refreshing and reporting when it last happened are the same idea,
            // so they are one control rather than a button beside a timestamp.
            Button {
                model.scheduleRefresh(debounce: .zero)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text(model.isRefreshing ? "Checking…" : lastUpdatedText)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshing)
            .help("Check again now")

            HStack {
                Button("Settings…") { openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 11)
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
