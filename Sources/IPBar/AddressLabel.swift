import Foundation

/// A user-defined name for an address or block, e.g. `203.0.113.42` → "Office".
struct AddressLabel: Codable, Identifiable, Hashable, Sendable {
    enum Scope: String, Codable, CaseIterable, Sendable {
        case any, publicAddress, localAddress

        var title: String {
            switch self {
            case .any: return "Anywhere"
            case .publicAddress: return "Public only"
            case .localAddress: return "Local only"
            }
        }
    }

    var id = UUID()
    var pattern: String
    var name: String
    var scope: Scope = .any

    var prefix: IPPrefix? { IPPrefix(pattern) }
    var isValid: Bool { prefix != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension Array where Element == AddressLabel {
    /// Returns the name for `address`, preferring the most specific match so a
    /// `/32` entry always beats the `/24` it sits inside.
    func name(for address: String, scope: AddressLabel.Scope) -> String? {
        compactMap { label -> (Int, String)? in
            guard label.scope == .any || label.scope == scope else { return nil }
            guard let prefix = label.prefix, prefix.contains(address) else { return nil }
            let trimmed = label.name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (prefix.prefixLength, trimmed)
        }
        .max { $0.0 < $1.0 }?
        .1
    }
}
