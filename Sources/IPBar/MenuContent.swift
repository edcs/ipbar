import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: NetworkModel
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Public") {
                row(family: "IPv4", address: model.publicIPv4, scope: .publicAddress)
                row(family: "IPv6", address: model.publicIPv6, scope: .publicAddress)
            }

            Divider()

            section("Local") {
                if localInterfaces.isEmpty {
                    Text("No active interfaces").foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(localInterfaces) { interface in
                        row(family: "\(interface.label) · \(interface.family.rawValue)",
                            address: interface.address,
                            scope: .localAddress)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: model.vpn.isActive ? "lock.fill" : "lock.open")
                    .foregroundStyle(model.vpn.isActive ? Color.green : Color.secondary)
                Text(model.vpn.summary).font(.callout)
            }

            Divider()

            HStack {
                Button {
                    model.scheduleRefresh(debounce: .zero)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)

                Spacer()

                if let lastUpdated = model.lastUpdated {
                    Text(lastUpdated, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var localInterfaces: [NetworkInterface] {
        model.interfaces
            .filter { $0.kind != .loopback && $0.kind != .virtual && !$0.isLinkLocal }
            .sorted { ($0.bsdName, $0.family.rawValue) < ($1.bsdName, $1.family.rawValue) }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func row(family: String, address: String?, scope: AddressLabel.Scope) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(family)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            if let address {
                VStack(alignment: .leading, spacing: 1) {
                    if let name = model.name(for: address, scope: scope) {
                        Text(name).font(.callout.weight(.medium))
                    }
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(model.name(for: address, scope: scope) == nil ? .primary : .secondary)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(address)")
            } else {
                Text("—").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}
