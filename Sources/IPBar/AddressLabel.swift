import Foundation

/// A user-defined name for an address, a block, or a network.
///
/// Two kinds of thing can carry a name. An address or CIDR block is matched by
/// prefix, as it always has been. A network is matched by the link-layer
/// address of its gateway, which stays put while an ISP rotates the public
/// address behind it.
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

    /// What a label matches against.
    ///
    /// `descriptor` is captured once, when the network is named, purely so the
    /// row is readable in Settings — a bare MAC is not something anyone can
    /// check. It is never matched on and never refreshed.
    enum Key: Codable, Hashable, Sendable {
        case prefix(String)
        case network(gateway: String, descriptor: String)
    }

    var id = UUID()
    var key: Key
    var name: String
    /// Ignored for network labels: a network name describes neither the public
    /// nor the local address, so it applies wherever.
    var scope: Scope = .any

    var isNetwork: Bool {
        if case .network = key { return true }
        return false
    }

    var prefix: IPPrefix? {
        if case .prefix(let text) = key { return IPPrefix(text) }
        return nil
    }

    var descriptor: String? {
        if case .network(_, let descriptor) = key { return descriptor }
        return nil
    }

    /// Backwards compatibility: forwards to `patternText`.
    var pattern: String {
        get { patternText }
        set { patternText = newValue }
    }

    /// Binding shim for the Settings table, which edits a plain `String`.
    /// Writes are dropped for network labels, whose key is captured rather
    /// than typed.
    var patternText: String {
        get {
            if case .prefix(let text) = key { return text }
            return ""
        }
        set {
            if case .prefix = key { key = .prefix(newValue) }
        }
    }

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch key {
        case .prefix: return prefix != nil
        case .network: return true
        }
    }

    /// What makes two labels the same entry, so renaming updates rather than
    /// appends. An address is keyed by its pattern and the scope it applies to;
    /// a network by its gateway alone, since it has no scope.
    var identity: String {
        switch key {
        case .prefix(let text): return "prefix|\(text)|\(scope.rawValue)"
        case .network(let gateway, _): return "network|\(gateway)"
        }
    }
}

extension AddressLabel {
    /// The common case: a label matching an address or CIDR block.
    init(pattern: String, name: String, scope: Scope = .any) {
        self.init(key: .prefix(pattern), name: name, scope: scope)
    }
}

extension Array where Element == AddressLabel {
    /// Names one exact address, as the panel does when you rename in place.
    ///
    /// An existing label for the same address and scope is updated rather than
    /// duplicated, and clearing the name removes it entirely, so repeated
    /// renaming cannot silently pile up dead entries.
    mutating func setName(_ name: String, for address: String, scope: AddressLabel.Scope) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = firstIndex(where: { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity }) {
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
        contains { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity }
    }

    mutating func removeLabel(for address: String, scope: AddressLabel.Scope) {
        removeAll { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity }
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
