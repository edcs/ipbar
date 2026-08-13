import Darwin
import Foundation

/// A parsed IPv4/IPv6 address or CIDR block, used to match a live address
/// against a user-defined label.
///
/// Accepts a bare address (`203.0.113.42`, `2001:db8::1`) — treated as a
/// full-length prefix — or CIDR notation (`192.168.1.0/24`, `2001:db8::/32`).
/// An IPv6 zone suffix (`fe80::1%en0`) is stripped before parsing.
struct IPPrefix: Hashable, Sendable {
    let family: Int32
    let bytes: [UInt8]
    let prefixLength: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var host = parts[0].trimmingCharacters(in: .whitespaces)
        if let zone = host.firstIndex(of: "%") { host = String(host[host.startIndex..<zone]) }
        guard !host.isEmpty else { return nil }

        if host.contains(":") {
            var addr = in6_addr()
            guard inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
            family = AF_INET6
            bytes = withUnsafeBytes(of: addr) { Array($0) }
        } else {
            var addr = in_addr()
            guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
            family = AF_INET
            bytes = withUnsafeBytes(of: addr) { Array($0) }
        }

        let maxLength = bytes.count * 8
        if parts.count == 2 {
            let suffix = parts[1].trimmingCharacters(in: .whitespaces)
            guard let length = Int(suffix), (0...maxLength).contains(length) else { return nil }
            prefixLength = length
        } else {
            prefixLength = maxLength
        }
    }

    var isSingleAddress: Bool { prefixLength == bytes.count * 8 }

    func contains(_ address: String) -> Bool {
        guard let other = IPPrefix(address), other.family == family else { return false }

        let fullBytes = prefixLength / 8
        let remainingBits = prefixLength % 8

        if fullBytes > 0, bytes[0..<fullBytes] != other.bytes[0..<fullBytes] { return false }
        if remainingBits > 0 {
            // Shift within UInt8 so the overflowing high bits are discarded;
            // `UInt8(0xFF << n)` would trap because 0xFF is inferred as Int.
            let mask: UInt8 = 0xFF << UInt8(8 - remainingBits)
            return (bytes[fullBytes] & mask) == (other.bytes[fullBytes] & mask)
        }
        return true
    }
}
