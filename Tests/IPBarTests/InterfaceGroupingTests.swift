import Foundation
import Testing
@testable import IPBar

@Suite("Grouping local addresses")
@MainActor
struct InterfaceGroupingTests {
    private func interface(_ name: String, _ address: String,
                           _ kind: NetworkInterface.Kind = .wifi,
                           family: NetworkInterface.Family = .ipv6,
                           linkLocal: Bool = false) -> NetworkInterface {
        NetworkInterface(bsdName: name, address: address, family: family,
                         kind: kind, isLinkLocal: linkLocal, friendlyName: name == "en0" ? "Wi-Fi" : nil)
    }

    @Test("an address that is also the public one is listed only once")
    func collapsesPublicAddress() {
        // IPv6 has no NAT, so this Mac's global address is the public address.
        let global = "2a06:61c2:1738:0:e98d:4bd1:6925:4e84"
        let temporary = "2a06:61c2:1738:0:1cc1:3c0c:9659:e927"
        let interfaces = [
            interface("en0", "192.168.1.77", family: .ipv4),
            interface("en0", global),
            interface("en0", temporary)
        ]

        let groups = NetworkModel.groups(from: interfaces, collapsing: [global])
        let addresses = groups.flatMap { $0.addresses.map(\.address) }

        #expect(!addresses.contains(global), "the public address belongs to the public section")
        #expect(addresses.contains(temporary))
        #expect(addresses.contains("192.168.1.77"))
    }

    @Test("nothing is collapsed when the public address is elsewhere")
    func natMeansNoOverlap() {
        // With IPv4 NAT the public address is not held by any interface.
        let interfaces = [interface("en0", "192.168.1.77", family: .ipv4)]
        let groups = NetworkModel.groups(from: interfaces, collapsing: ["83.151.201.105"])
        #expect(groups.flatMap { $0.addresses }.count == 1)
    }

    @Test("a group left with nothing is dropped rather than shown empty")
    func dropsEmptyGroups() {
        let only = "2a06:61c2:1738:0:e98d:4bd1:6925:4e84"
        let interfaces = [interface("en5", only, .ethernet)]

        #expect(NetworkModel.groups(from: interfaces, collapsing: []).count == 1)
        #expect(NetworkModel.groups(from: interfaces, collapsing: [only]).isEmpty)
    }

    @Test("loopback, virtual and link-local addresses stay out")
    func excludesNoise() {
        let interfaces = [
            interface("lo0", "127.0.0.1", .loopback, family: .ipv4),
            interface("bridge0", "192.168.64.1", .virtual, family: .ipv4),
            interface("en0", "fe80::1", linkLocal: true),
            interface("en0", "192.168.1.77", family: .ipv4)
        ]
        let addresses = NetworkModel.groups(from: interfaces, collapsing: [])
            .flatMap { $0.addresses.map(\.address) }

        #expect(addresses == ["192.168.1.77"])
    }

    @Test("addresses group under the interface's friendly name")
    func groupsByFriendlyName() {
        let interfaces = [
            interface("en0", "192.168.1.77", family: .ipv4),
            interface("en0", "2a06:61c2:1738:0:1cc1:3c0c:9659:e927")
        ]
        let groups = NetworkModel.groups(from: interfaces, collapsing: [])

        #expect(groups.count == 1)
        #expect(groups.first?.id == "Wi-Fi")
        #expect(groups.first?.addresses.count == 2)
    }

    @Test("collapsing both families at once is fine")
    func collapsesBothFamilies() {
        // A machine with a public IPv4 directly on the interface, no NAT.
        let v4 = "83.151.201.105"
        let v6 = "2a06:61c2:1738:0:e98d:4bd1:6925:4e84"
        let interfaces = [
            interface("en0", v4, family: .ipv4),
            interface("en0", v6)
        ]
        #expect(NetworkModel.groups(from: interfaces, collapsing: [v4, v6]).isEmpty)
    }
}
