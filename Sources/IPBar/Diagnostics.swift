import Foundation

/// `IPBar --diagnose` dumps everything the menu bar is derived from and exits.
/// Handy for bug reports, and for checking VPN detection against `scutil --nwi`
/// without having to squint at the menu bar.
enum Diagnostics {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--diagnose") else { return }

        let interfaces = InterfaceScanner.scan()
        let vpn = VPNState.detect(interfaces: interfaces)

        print("Primary interface  IPv4: \(InterfaceScanner.primaryInterface(family: .ipv4) ?? "none")")
        print("                   IPv6: \(InterfaceScanner.primaryInterface(family: .ipv6) ?? "none")")
        print("VPN                \(vpn.mode.rawValue) — \(vpn.summary)")
        print("")
        print("Interfaces")
        for interface in interfaces.sorted(by: { $0.bsdName < $1.bsdName }) {
            let flags = [
                interface.isLinkLocal ? "link-local" : nil,
                interface.kind == .tunnel ? "tunnel" : nil
            ].compactMap { $0 }.joined(separator: ",")
            print(String(format: "  %-10s %-6s %-42s %@",
                         (interface.bsdName as NSString).utf8String!,
                         (interface.family.rawValue as NSString).utf8String!,
                         (interface.address as NSString).utf8String!,
                         flags.isEmpty ? (interface.friendlyName ?? "") : flags))
        }

        let service = PublicIPService()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var v4: PublicIPService.Result?
        nonisolated(unsafe) var v6: PublicIPService.Result?
        Task {
            async let a = service.fetch(.ipv4)
            async let b = service.fetch(.ipv6)
            (v4, v6) = await (a, b)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)

        print("")
        print("Public             IPv4: \(v4?.address ?? "none")")
        print("                   IPv6: \(v6?.address ?? "none")")
        print("                Country: \(v4?.country ?? v6?.country ?? "unknown")")

        let labels = MainActor.assumeIsolated { Preferences().labels }
        print("")
        print("Labels (\(labels.count))")
        for label in labels {
            let valid = label.prefix == nil ? "  [invalid pattern]" : ""
            print("  \(label.pattern) → \(label.name) [\(label.scope.rawValue)]\(valid)")
        }
        for address in [v4?.address, v6?.address].compactMap({ $0 }) {
            let matched = labels.name(for: address, scope: .publicAddress) ?? "no match"
            print("  resolve \(address) → \(matched)")
        }

        exit(0)
    }
}
