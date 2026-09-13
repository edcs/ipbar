import Foundation

/// Fetches the public address as seen from outside the machine.
///
/// The v4 and v6 endpoints are deliberately separate hosts pinned to a single
/// family — asking one dual-stack host lets Happy Eyeballs decide for you and
/// you never learn which stack actually egresses.
actor PublicIPService {
    /// Cloudflare's trace response already carries `loc=GB`, so the country
    /// costs no extra request and introduces no further third party. The ipify
    /// fallback returns a bare address, hence the optional.
    struct Result: Sendable {
        let address: String
        let country: String?
    }

    struct Endpoint: Sendable {
        let url: URL
        /// Cloudflare's trace endpoint returns `key=value` lines; ipify returns
        /// a bare address.
        let isTrace: Bool
    }

    /// The literal IP stays first: it pins the stack with no DNS in the way.
    /// It is also the address networks most like to intercept — in Doha the
    /// handshake to 1.1.1.1 succeeded but the exchange never completed — so the
    /// same service by hostname follows it. Only then ipify, which reports an
    /// address and no country: reaching it means the flag is already lost.
    private static let ipv4: [Endpoint] = [
        Endpoint(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!, isTrace: true),
        Endpoint(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!, isTrace: true),
        Endpoint(url: URL(string: "https://api.ipify.org")!, isTrace: false)
    ]

    private static let ipv6: [Endpoint] = [
        Endpoint(url: URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace")!, isTrace: true),
        Endpoint(url: URL(string: "https://api6.ipify.org")!, isTrace: false)
    ]

    private let session: URLSession

    /// How the app talks to these endpoints. Separated from `init` so a test
    /// can substitute a configuration carrying a stub `URLProtocol`, and
    /// exercise the real fallback order against the real endpoint list without
    /// depending on the network it happens to be running on.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return configuration
    }

    init(configuration: URLSessionConfiguration = PublicIPService.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    func fetch(_ family: NetworkInterface.Family) async -> Result? {
        for endpoint in family == .ipv4 ? Self.ipv4 : Self.ipv6 {
            if let result = try? await query(endpoint), Self.address(result.address, is: family) {
                return result
            }
        }
        return nil
    }

    /// Whether an answer came back on the stack it was asked about.
    ///
    /// A literal-IP endpoint can only reply on its own stack, but a hostname
    /// resolves to both and Happy Eyeballs picks one, so the reply has to be
    /// checked rather than assumed. Without this an address reached over IPv6
    /// could be reported as the IPv4 one, which is the very confusion the
    /// separate endpoint lists exist to prevent.
    private static func address(_ text: String, is family: NetworkInterface.Family) -> Bool {
        guard let parsed = IPPrefix(text) else { return false }
        return parsed.family == (family == .ipv4 ? AF_INET : AF_INET6)
    }

    private func query(_ endpoint: Endpoint) async throws -> Result? {
        let (data, response) = try await session.data(from: endpoint.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else { return nil }

        guard endpoint.isTrace else {
            let address = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return address.isEmpty ? nil : Result(address: address, country: nil)
        }

        var fields: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let address = fields["ip"] else { return nil }

        // Cloudflare reports XX when it cannot place the address.
        let country = fields["loc"].flatMap { $0.count == 2 && $0 != "XX" ? $0.uppercased() : nil }
        return Result(address: address, country: country)
    }
}
