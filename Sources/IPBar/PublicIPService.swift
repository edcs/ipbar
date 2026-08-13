import Foundation

/// Fetches the public address as seen from outside the machine.
///
/// The v4 and v6 endpoints are deliberately separate hosts pinned to a single
/// family — asking one dual-stack host lets Happy Eyeballs decide for you and
/// you never learn which stack actually egresses.
actor PublicIPService {
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

    func fetch(_ family: NetworkInterface.Family) async -> String? {
        for endpoint in family == .ipv4 ? Self.ipv4 : Self.ipv6 {
            if let address = try? await query(endpoint), IPPrefix(address) != nil {
                return address
            }
        }
        return nil
    }

    private func query(_ endpoint: Endpoint) async throws -> String? {
        let (data, response) = try await session.data(from: endpoint.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else { return nil }

        guard endpoint.isTrace else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
            .split(separator: "\n")
            .first { $0.hasPrefix("ip=") }
            .map { String($0.dropFirst(3)) }
    }
}
