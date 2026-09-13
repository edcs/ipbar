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
    /// Names one entry, as the panel does when you rename in place.
    ///
    /// An existing entry with the same identity is updated rather than
    /// duplicated, and clearing the name removes it, so repeated renaming
    /// cannot silently pile up dead labels.
    mutating func setName(_ name: String, forKey key: AddressLabel.Key,
                          scope: AddressLabel.Scope) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = AddressLabel(key: key, name: "", scope: scope)

        if let index = firstIndex(where: { $0.identity == probe.identity }) {
            if trimmed.isEmpty {
                remove(at: index)
            } else {
                self[index].name = trimmed
                // Refresh the captured descriptor so a renamed network shows
                // where it was last seen rather than where it was first named.
                self[index].key = key
            }
        } else if !trimmed.isEmpty {
            append(AddressLabel(key: key, name: trimmed, scope: scope))
        }
    }

    mutating func setName(_ name: String, for address: String, scope: AddressLabel.Scope) {
        setName(name, forKey: .prefix(address), scope: scope)
    }

    /// Names the network this Mac is currently attached to.
    mutating func setNetworkName(_ name: String, for key: NetworkKey) {
        setName(name, forKey: .network(gateway: key.gateway, descriptor: key.descriptor),
                scope: .any)
    }

    /// Whether this exact entry carries its own label. A name inherited from a
    /// wider block belongs to that block, not to this address.
    func hasOwnLabel(forKey key: AddressLabel.Key, scope: AddressLabel.Scope) -> Bool {
        let probe = AddressLabel(key: key, name: "", scope: scope)
        return contains { $0.identity == probe.identity }
    }

    func hasOwnLabel(for address: String, scope: AddressLabel.Scope) -> Bool {
        hasOwnLabel(forKey: .prefix(address), scope: scope)
    }

    mutating func removeLabel(forKey key: AddressLabel.Key, scope: AddressLabel.Scope) {
        let probe = AddressLabel(key: key, name: "", scope: scope)
        removeAll { $0.identity == probe.identity }
    }

    mutating func removeLabel(for address: String, scope: AddressLabel.Scope) {
        removeLabel(forKey: .prefix(address), scope: scope)
    }

    /// Returns the name for `address`, preferring the most specific match.
    ///
    /// Specificity is a sortable tuple and the largest wins. Tier 2 is an exact
    /// address, tier 1 a network key, tier 0 a block — so a `/32` beats a named
    /// network, which in turn beats the `/24` it sits inside. Within a tier the
    /// longer prefix wins, exactly as before.
    func name(for address: String, scope: AddressLabel.Scope,
              networkKey: NetworkKey? = nil) -> String? {
        compactMap { label -> (tier: Int, length: Int, name: String)? in
            let trimmed = label.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            switch label.key {
            case .prefix(let text):
                guard label.scope == .any || label.scope == scope else { return nil }
                guard let prefix = IPPrefix(text), prefix.contains(address) else { return nil }
                return (prefix.isSingleAddress ? 2 : 0, prefix.prefixLength, trimmed)

            case .network(let gateway, _):
                // Scope is deliberately not consulted: a network name describes
                // where you are, not which address you are using.
                guard let networkKey, networkKey.gateway == gateway else { return nil }
                return (1, 0, trimmed)
            }
        }
        .max { ($0.tier, $0.length) < ($1.tier, $1.length) }?
        .name
    }
}
