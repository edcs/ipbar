import Foundation
import Testing
@testable import IPBar

@Suite("IPPrefix parsing")
struct IPPrefixParsingTests {
    @Test("bare addresses parse as full-length prefixes")
    func bareAddresses() {
        #expect(IPPrefix("203.0.113.42")?.prefixLength == 32)
        #expect(IPPrefix("2001:db8::1")?.prefixLength == 128)
        #expect(IPPrefix("203.0.113.42")?.isSingleAddress == true)
    }

    @Test("CIDR suffixes parse")
    func cidr() {
        #expect(IPPrefix("192.168.1.0/24")?.prefixLength == 24)
        #expect(IPPrefix("2001:db8::/32")?.prefixLength == 32)
        #expect(IPPrefix("0.0.0.0/0")?.prefixLength == 0)
    }

    @Test("IPv6 zone suffixes are stripped")
    func zoneSuffix() {
        #expect(IPPrefix("fe80::1%en0") != nil)
        #expect(IPPrefix("fe80::1%en0")?.contains("fe80::1") == true)
    }

    @Test("malformed input is rejected", arguments: [
        "", "not-an-ip", "203.0.113.256", "192.168.1.0/33", "2001:db8::/129",
        "192.168.1.0/-1", "192.168.1.0/abc", "/24"
    ])
    func rejectsGarbage(_ input: String) {
        #expect(IPPrefix(input) == nil)
    }
}

@Suite("Prefix containment")
struct ContainmentTests {
    @Test("exact IPv4 match")
    func exactV4() {
        let prefix = IPPrefix("203.0.113.42")!
        #expect(prefix.contains("203.0.113.42"))
        #expect(!prefix.contains("203.0.113.43"))
    }

    @Test("byte-aligned IPv4 block")
    func alignedV4() {
        let prefix = IPPrefix("192.168.1.0/24")!
        #expect(prefix.contains("192.168.1.1"))
        #expect(prefix.contains("192.168.1.255"))
        #expect(!prefix.contains("192.168.2.1"))
    }

    @Test("non-byte-aligned IPv4 block")
    func unalignedV4() {
        let prefix = IPPrefix("10.0.0.0/12")!
        #expect(prefix.contains("10.0.0.1"))
        #expect(prefix.contains("10.15.255.254"))
        #expect(!prefix.contains("10.16.0.1"))
    }

    @Test("/0 matches everything in its family")
    func defaultRoute() {
        #expect(IPPrefix("0.0.0.0/0")!.contains("8.8.8.8"))
        #expect(!IPPrefix("0.0.0.0/0")!.contains("2001:db8::1"))
    }

    @Test("IPv6 blocks and normalisation")
    func ipv6() {
        let prefix = IPPrefix("2001:db8::/32")!
        #expect(prefix.contains("2001:db8::1"))
        #expect(prefix.contains("2001:0db8:0000::dead:beef"))
        #expect(!prefix.contains("2001:db9::1"))
    }

    @Test("families never cross-match")
    func familyIsolation() {
        #expect(!IPPrefix("192.168.1.0/24")!.contains("2001:db8::1"))
        #expect(!IPPrefix("2001:db8::/32")!.contains("192.168.1.1"))
    }
}

@Suite("Label resolution")
struct LabelResolutionTests {
    @Test("most specific prefix wins")
    func specificity() {
        let labels = [
            AddressLabel(pattern: "203.0.113.0/24", name: "Office network"),
            AddressLabel(pattern: "203.0.113.42", name: "Office static IP"),
            AddressLabel(pattern: "0.0.0.0/0", name: "Somewhere")
        ]
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Office static IP")
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress) == "Office network")
        #expect(labels.name(for: "8.8.8.8", scope: .publicAddress) == "Somewhere")
    }

    @Test("scope is honoured")
    func scoping() {
        let labels = [
            AddressLabel(pattern: "10.0.0.5", name: "LAN box", scope: .localAddress),
            AddressLabel(pattern: "203.0.113.42", name: "Static", scope: .publicAddress)
        ]
        #expect(labels.name(for: "10.0.0.5", scope: .localAddress) == "LAN box")
        #expect(labels.name(for: "10.0.0.5", scope: .publicAddress) == nil)
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == "Static")
        #expect(labels.name(for: "203.0.113.42", scope: .localAddress) == nil)
    }

    @Test("blank names and bad patterns are ignored")
    func ignoresUnusable() {
        let labels = [
            AddressLabel(pattern: "203.0.113.42", name: "   "),
            AddressLabel(pattern: "garbage", name: "Nope")
        ]
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress) == nil)
        #expect(labels.name(for: "1.2.3.4", scope: .publicAddress) == nil)
    }

    @Test("no labels means no name")
    func empty() {
        #expect([AddressLabel]().name(for: "203.0.113.42", scope: .publicAddress) == nil)
    }
}

@Suite("VPN detection")
struct VPNDetectionTests {
    private func interface(_ name: String, _ address: String, _ kind: NetworkInterface.Kind,
                           linkLocal: Bool = false) -> NetworkInterface {
        NetworkInterface(bsdName: name, address: address, family: .ipv4,
                         kind: kind, isLinkLocal: linkLocal, friendlyName: nil)
    }

    @Test("link-local-only tunnels are not a VPN")
    func continuityTunnelsIgnored() {
        // macOS keeps utun0-5 up for Continuity/Private Relay with link-local
        // addresses only. These must not register as a VPN.
        let interfaces = (0..<6).map {
            interface("utun\($0)", "fe80::\($0)", .tunnel, linkLocal: true)
        } + [interface("en0", "192.168.1.10", .wifi)]

        #expect(VPNState.detect(interfaces: interfaces).mode == .off)
    }

    @Test("a routable tunnel that is not primary is a split tunnel")
    func splitTunnel() {
        let interfaces = [
            interface("en0", "192.168.1.10", .wifi),
            interface("utun7", "100.64.0.3", .tunnel)
        ]
        let state = VPNState.detect(interfaces: interfaces)
        // en0 holds the default route on the test host, so this is split.
        #expect(state.tunnels == ["utun7"])
        #expect(state.isActive)
    }

    @Test("no interfaces at all is not a VPN")
    func noInterfaces() {
        #expect(VPNState.detect(interfaces: []).mode == .off)
    }
}

@Suite("Label kinds")
struct LabelKindTests {
    @Test("the pattern initialiser still builds an address label")
    func patternInit() {
        let label = AddressLabel(pattern: "203.0.113.42", name: "Office")
        #expect(label.key == .prefix("203.0.113.42"))
        #expect(label.isNetwork == false)
        #expect(label.patternText == "203.0.113.42")
        #expect(label.descriptor == nil)
        #expect(label.prefix?.prefixLength == 32)
    }

    @Test("a network label carries a gateway and a descriptor")
    func networkLabel() {
        let label = AddressLabel(key: .network(gateway: "74:24:9f:ab:0e:ab",
                                               descriptor: "Wi-Fi · router 172.16.132.1"),
                                 name: "Home")
        #expect(label.isNetwork)
        #expect(label.descriptor == "Wi-Fi · router 172.16.132.1")
        #expect(label.prefix == nil)
        #expect(label.patternText == "")
    }

    @Test("a network label is valid despite having no prefix")
    func networkIsValid() {
        // A nil prefix paints an address row red in Settings. A network label
        // has no prefix by construction and must not be flagged as broken.
        let label = AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                               descriptor: "Wi-Fi · router 10.0.0.1"),
                                 name: "Home")
        #expect(label.isValid)
    }

    @Test("validity still rejects bad patterns and blank names")
    func validityRules() {
        #expect(AddressLabel(pattern: "203.0.113.42", name: "Office").isValid)
        #expect(!AddressLabel(pattern: "garbage", name: "Office").isValid)
        #expect(!AddressLabel(pattern: "203.0.113.42", name: "   ").isValid)
        #expect(!AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                            descriptor: "x"), name: " ").isValid)
    }

    @Test("writing patternText edits an address label and ignores a network one")
    func patternTextBinding() {
        var address = AddressLabel(pattern: "10.0.0.1", name: "Box")
        address.patternText = "10.0.0.2"
        #expect(address.key == .prefix("10.0.0.2"))

        var network = AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                                 descriptor: "Wi-Fi · router 10.0.0.1"),
                                   name: "Home")
        network.patternText = "nonsense"
        #expect(network.key == .network(gateway: "aa:bb:cc:dd:ee:ff",
                                        descriptor: "Wi-Fi · router 10.0.0.1"))
    }

    @Test("identity keys an address by pattern and scope, a network by gateway alone")
    func identity() {
        // Network labels have no scope, so scope must not enter their identity.
        let a = AddressLabel(pattern: "10.0.0.1", name: "A", scope: .localAddress)
        let b = AddressLabel(pattern: "10.0.0.1", name: "B", scope: .publicAddress)
        #expect(a.identity != b.identity)

        let key = AddressLabel.Key.network(gateway: "aa:bb:cc:dd:ee:ff", descriptor: "one")
        let other = AddressLabel.Key.network(gateway: "aa:bb:cc:dd:ee:ff", descriptor: "two")
        let c = AddressLabel(key: key, name: "Home", scope: .any)
        let d = AddressLabel(key: other, name: "Home", scope: .localAddress)
        #expect(c.identity == d.identity)
    }

    @Test("both kinds survive a Codable round trip")
    func codableRoundTrip() throws {
        let labels = [
            AddressLabel(pattern: "192.168.1.0/24", name: "LAN", scope: .localAddress),
            AddressLabel(key: .network(gateway: "74:24:9f:ab:0e:ab",
                                       descriptor: "Wi-Fi · router 172.16.132.1"),
                         name: "Home")
        ]
        let data = try JSONEncoder().encode(labels)
        let decoded = try JSONDecoder().decode([AddressLabel].self, from: data)
        #expect(decoded == labels)
    }
}
