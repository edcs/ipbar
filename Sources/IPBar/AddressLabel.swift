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
    /// Names one exact address, as the panel does when you rename in place.
    ///
    /// An existing label for the same address and scope is updated rather than
    /// duplicated, and clearing the name removes it entirely, so repeated
    /// renaming cannot silently pile up dead entries.
    mutating func setName(_ name: String, for address: String, scope: AddressLabel.Scope) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = firstIndex(where: { $0.pattern == address && $0.scope == scope }) {
            if trimmed.isEmpty {
                remove(at: index)
            } else {
                self[index].name = trimmed
            }
        } else if !trimmed.isEmpty {
            append(AddressLabel(pattern: address, name: trimmed, scope: scope))
        }
    }

    /// Whether this exact address carries its own label. A name inherited from
    /// a wider block belongs to that block, not to this address.
    func hasOwnLabel(for address: String, scope: AddressLabel.Scope) -> Bool {
        contains { $0.pattern == address && $0.scope == scope }
    }

    mutating func removeLabel(for address: String, scope: AddressLabel.Scope) {
        removeAll { $0.pattern == address && $0.scope == scope }
    }

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
