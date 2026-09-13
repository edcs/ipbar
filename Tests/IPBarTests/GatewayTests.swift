import Testing
@testable import IPBar

@Suite("Choosing the gateway")
struct GatewaySelectionTests {
    private let physical: Set<String> = ["en0", "en1"]

    private func candidate(_ service: String, _ interface: String,
                           _ router: String) -> RouterCandidate {
        RouterCandidate(serviceID: service, interface: interface, router: router)
    }

    @Test("the only physical router is chosen")
    func single() {
        let chosen = GatewaySelection.choose(
            candidates: [candidate("A", "en0", "172.16.132.1")],
            physicalInterfaces: physical,
            serviceOrder: ["A"])
        #expect(chosen?.router == "172.16.132.1")
    }

    @Test("a tunnel is never chosen, even when it holds the default route")
    func tunnelIgnored() {
        // Verified against a live VPN: the default route moves to utun6, whose
        // gateway is point-to-point and has no ARP entry at all. Reading the
        // default route would return nothing and the name would vanish.
        let chosen = GatewaySelection.choose(
            candidates: [candidate("V", "utun6", "10.8.0.2"),
                         candidate("A", "en0", "172.16.132.1")],
            physicalInterfaces: physical,
            serviceOrder: ["V", "A"])
        #expect(chosen?.interface == "en0")
        #expect(chosen?.router == "172.16.132.1")
    }

    @Test("with no physical router there is no key")
    func tunnelOnly() {
        let chosen = GatewaySelection.choose(
            candidates: [candidate("V", "utun6", "10.8.0.2")],
            physicalInterfaces: physical,
            serviceOrder: ["V"])
        #expect(chosen == nil)
    }

    @Test("no candidates at all means no key")
    func empty() {
        #expect(GatewaySelection.choose(candidates: [], physicalInterfaces: physical,
                                        serviceOrder: []) == nil)
    }

    @Test("service order breaks a Wi-Fi and Ethernet tie")
    func serviceOrderWins() {
        let candidates = [candidate("WIFI", "en1", "192.168.1.1"),
                          candidate("ETH", "en0", "172.16.132.1")]
        #expect(GatewaySelection.choose(candidates: candidates,
                                        physicalInterfaces: physical,
                                        serviceOrder: ["ETH", "WIFI"])?.interface == "en0")
        #expect(GatewaySelection.choose(candidates: candidates,
                                        physicalInterfaces: physical,
                                        serviceOrder: ["WIFI", "ETH"])?.interface == "en1")
    }

    @Test("an unordered service loses to an ordered one")
    func unorderedLast() {
        let candidates = [candidate("GHOST", "en1", "192.168.1.1"),
                          candidate("ETH", "en0", "172.16.132.1")]
        #expect(GatewaySelection.choose(candidates: candidates,
                                        physicalInterfaces: physical,
                                        serviceOrder: ["ETH"])?.interface == "en0")
    }

    @Test("two unordered services resolve deterministically")
    func deterministicFallback() {
        // Never arbitrary: the same inputs must always give the same key, or a
        // name would flicker between networks for no visible reason.
        let candidates = [candidate("B", "en1", "192.168.1.1"),
                          candidate("A", "en0", "172.16.132.1")]
        let first = GatewaySelection.choose(candidates: candidates,
                                            physicalInterfaces: physical, serviceOrder: [])
        let second = GatewaySelection.choose(candidates: candidates.reversed(),
                                             physicalInterfaces: physical, serviceOrder: [])
        #expect(first?.interface == "en0")
        #expect(first == second)
    }
}

@Suite("MAC formatting")
struct MACFormattingTests {
    @Test("bytes format lowercase, colon-separated and zero-padded")
    func formatting() {
        #expect(GatewaySelection.formatMAC([0x74, 0x24, 0x9f, 0xab, 0x0e, 0xab])
                == "74:24:9f:ab:0e:ab")
    }

    @Test("a leading zero nibble is kept")
    func zeroPadding() {
        // `arp -a` prints this as 0:1:2:3:4:5. Truncating would make two
        // different networks collide on one key.
        #expect(GatewaySelection.formatMAC([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
                == "00:01:02:03:04:05")
    }

    @Test("all-ff formats correctly")
    func broadcast() {
        #expect(GatewaySelection.formatMAC([0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
                == "ff:ff:ff:ff:ff:ff")
    }
}
