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

    private static let ipv4: [Endpoint] = [
        Endpoint(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!, isTrace: true),
        Endpoint(url: URL(string: "https://api.ipify.org")!, isTrace: false)
    ]

    private static let ipv6: [Endpoint] = [
        Endpoint(url: URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace")!, isTrace: true),
        Endpoint(url: URL(string: "https://api6.ipify.org")!, isTrace: false)
    ]

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func fetch(_ family: NetworkInterface.Family) async -> Result? {
        for endpoint in family == .ipv4 ? Self.ipv4 : Self.ipv6 {
            if let result = try? await query(endpoint), IPPrefix(result.address) != nil {
                return result
            }
        }
        return nil
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
