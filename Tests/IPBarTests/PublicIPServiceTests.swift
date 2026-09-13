import Foundation
import Testing
@testable import IPBar

/// Answers the real endpoint list without touching the network, so the order
/// the endpoints are tried in can be checked on any machine rather than only on
/// one that happens to reproduce the fault.
///
/// Hosts in `blocked` fail the way an intercepted address does on a network
/// that hijacks it: the connection is accepted but the exchange never
/// completes, which surfaces as a timeout.
final class StubTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var blockedHosts: Set<String> = []
    private static let lock = NSLock()

    /// The address every endpoint agrees on, so a test that asserts on the
    /// country cannot pass or fail for the unrelated reason that a different
    /// endpoint answered with a different address.
    static let address = "212.77.220.109"

    nonisolated(unsafe) private static var addressOverrides: [String: String] = [:]

    static var blocked: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return blockedHosts }
        set { lock.lock(); defer { lock.unlock() }; blockedHosts = newValue }
    }

    /// Lets one host answer with a different address, standing in for a
    /// dual-stack hostname that happened to be reached over the other stack.
    static var addresses: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return addressOverrides }
        set { lock.lock(); defer { lock.unlock() }; addressOverrides = newValue }
    }

    static func reset() {
        blocked = []
        addresses = [:]
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = PublicIPService.defaultConfiguration()
        configuration.protocolClasses = [StubTransport.self]
        return configuration
    }

    /// A Cloudflare trace response carrying every field the real one returns,
    /// so parsing is exercised against the real shape rather than a two-line
    /// reduction of it.
    private static func traceBody(host: String) -> String {
        """
        fl=54f18
        h=\(host)
        ip=\(addresses[host] ?? address)
        ts=1789299900.000
        visit_scheme=https
        uag=IPBar
        colo=DOH
        sliver=none
        http=http/2
        loc=QA
        tls=TLSv1.3
        sni=plaintext
        warp=off
        gateway=off
        rbi=off
        kex=X25519
        """
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard !Self.blocked.contains(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        // ipify reports the address and nothing else; anything serving
        // /cdn-cgi/trace reports the country alongside it.
        let body = url.path.contains("/cdn-cgi/trace")
            ? Self.traceBody(host: host)
            : (Self.addresses[host] ?? Self.address)

        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Public address lookup", .serialized)
struct PublicIPServiceTests {
    private func service() -> PublicIPService {
        PublicIPService(configuration: StubTransport.configuration())
    }

    @Test("the country survives a network that intercepts the literal IP")
    func countrySurvivesInterceptedLiteralIP() async throws {
        // Observed in Doha: the TCP handshake to 1.1.1.1 succeeds but the HTTP
        // exchange never completes. Falling straight through to an endpoint
        // that reports only an address loses the country, and with it the flag.
        StubTransport.blocked = ["1.1.1.1"]
        defer { StubTransport.reset() }

        let result = try #require(await service().fetch(.ipv4))

        #expect(result.address == "212.77.220.109")
        #expect(result.country == "QA")
    }

    @Test("an endpoint reached over the other stack cannot fill this stack's slot")
    func rejectsAddressFromTheWrongStack() async throws {
        // The hostname endpoint is dual-stack, so on a machine with working
        // IPv6 it can answer over v6 while being asked for the v4 address.
        // 2001:db8::/32 is RFC 3849's documentation range.
        StubTransport.blocked = ["1.1.1.1"]
        StubTransport.addresses = ["www.cloudflare.com": "2001:db8:1738:0:870:ca09:920c:ef6c"]
        defer { StubTransport.reset() }

        let result = try #require(await service().fetch(.ipv4))

        #expect(result.address == "212.77.220.109")
    }

    @Test("the literal IP is still preferred when it is reachable")
    func literalIPGoesFirst() async throws {
        // The hostname is a fallback, not a replacement: the literal needs no
        // DNS and cannot be reached over the wrong stack, so it stays first.
        // Distinct addresses per host are how the test sees which answered.
        StubTransport.addresses = [
            "1.1.1.1": "203.0.113.1",
            "www.cloudflare.com": "203.0.113.2"
        ]
        defer { StubTransport.reset() }

        let result = try #require(await service().fetch(.ipv4))

        #expect(result.address == "203.0.113.1")
    }

    @Test("with every trace endpoint gone the address still arrives, without a country")
    func addressSurvivesWithoutCountry() async throws {
        // The flag is lost here, which is correct: nothing has said where the
        // address is. What must not be lost is the address itself.
        StubTransport.blocked = ["1.1.1.1", "www.cloudflare.com"]
        defer { StubTransport.reset() }

        let result = try #require(await service().fetch(.ipv4))

        #expect(result.address == "212.77.220.109")
        #expect(result.country == nil)
    }

    @Test("the IPv6 lookup still answers on its own stack")
    func ipv6UsesItsOwnStack() async throws {
        StubTransport.addresses = [
            "2606:4700:4700::1111": "2001:db8:1738:0:870:ca09:920c:ef6c"
        ]
        defer { StubTransport.reset() }

        let result = try #require(await service().fetch(.ipv6))

        #expect(result.address == "2001:db8:1738:0:870:ca09:920c:ef6c")
        #expect(result.country == "QA")
    }
}
