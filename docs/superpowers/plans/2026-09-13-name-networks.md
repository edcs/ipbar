# Name Networks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a name attach to the network you are on — keyed by its gateway MAC — so names survive an ISP rotating your public address.

**Architecture:** `AddressLabel.pattern` becomes an `AddressLabel.Key` enum with two cases, `.prefix` and `.network`. Matching widens into a tiered ranking where an exact address beats a network key beats a CIDR block. A new `Gateway.swift` resolves the current network to a `NetworkKey` by reading the ARP table via `sysctl` and taking the router of the primary *physical* interface — never the default route, which a VPN displaces.

**Tech Stack:** Swift 6 (language mode v6), SwiftUI, SwiftPM, Swift Testing (`@Suite`/`@Test`/`#expect`), SystemConfiguration, Darwin `sysctl`.

**Spec:** `docs/superpowers/specs/2026-09-13-name-networks-design.md`

## Global Constraints

- **Platform floor:** macOS 14 (`Package.swift` declares `.macOS(.v14)`, `Info.plist` declares `LSMinimumSystemVersion 14.0`). Do not raise it.
- **Swift language mode v6** on both targets. All shared types must be `Sendable`; `NetworkModel` and `Preferences` are `@MainActor`.
- **`swift test` must need no network.** Anything touching live system or network state goes behind an injectable seam.
- **No new dependencies.** `Package.swift` has zero and gains none.
- **No new permissions.** No Location Services, no notifications, no entitlements. `Resources/Info.plist` gains no usage strings.
- **No polling.** Refresh stays driven by `NWPathMonitor`, wake, and the user's timer.
- **Conventional Commits**, enforced by `.githooks/commit-msg`. Types: `feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert`. **Header max 72 characters.**
- **Gateway MAC format:** lowercase, colon-separated, zero-padded — `74:24:9f:ab:0e:ab`. Never `74:24:9f:ab:e:ab`.
- **Network labels have no scope** (spec decision 6). Their `scope` field is never read.
- **Run `swift build` before `swift test`** — a compile error in `Sources/` surfaces faster than through the test target.

---

### Task 1: `AddressLabel.Key` — two kinds of label

**Files:**
- Modify: `Sources/IPBar/AddressLabel.swift:1-24`
- Test: `Tests/IPBarTests/MatchingTests.swift` (new suite appended)

**Interfaces:**
- Consumes: nothing.
- Produces: `AddressLabel.Key` (`.prefix(String)`, `.network(gateway: String, descriptor: String)`); `AddressLabel.init(pattern:name:scope:)`; computed `patternText: String`, `prefix: IPPrefix?`, `descriptor: String?`, `isNetwork: Bool`, `isValid: Bool`, `identity: String`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IPBarTests/MatchingTests.swift`:

```swift
@Suite("Label kinds")
struct LabelKindTests {
    @Test("the pattern initialiser still builds an address label")
    func patternInit() {
        let label = AddressLabel(pattern: "203.0.113.42", name: "Office")
        #expect(label.key == .prefix("203.0.113.42"))
        #expect(label.isNetwork == false)
        #expect(label.patternText == "203.0.113.42")
        #expect(label.descriptor == nil)
        #expect(label.prefix?.prefixLength == 32)
    }

    @Test("a network label carries a gateway and a descriptor")
    func networkLabel() {
        let label = AddressLabel(key: .network(gateway: "74:24:9f:ab:0e:ab",
                                               descriptor: "Wi-Fi · router 172.16.132.1"),
                                 name: "Home")
        #expect(label.isNetwork)
        #expect(label.descriptor == "Wi-Fi · router 172.16.132.1")
        #expect(label.prefix == nil)
        #expect(label.patternText == "")
    }

    @Test("a network label is valid despite having no prefix")
    func networkIsValid() {
        // A nil prefix paints an address row red in Settings. A network label
        // has no prefix by construction and must not be flagged as broken.
        let label = AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                               descriptor: "Wi-Fi · router 10.0.0.1"),
                                 name: "Home")
        #expect(label.isValid)
    }

    @Test("validity still rejects bad patterns and blank names")
    func validityRules() {
        #expect(AddressLabel(pattern: "203.0.113.42", name: "Office").isValid)
        #expect(!AddressLabel(pattern: "garbage", name: "Office").isValid)
        #expect(!AddressLabel(pattern: "203.0.113.42", name: "   ").isValid)
        #expect(!AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                            descriptor: "x"), name: " ").isValid)
    }

    @Test("writing patternText edits an address label and ignores a network one")
    func patternTextBinding() {
        var address = AddressLabel(pattern: "10.0.0.1", name: "Box")
        address.patternText = "10.0.0.2"
        #expect(address.key == .prefix("10.0.0.2"))

        var network = AddressLabel(key: .network(gateway: "aa:bb:cc:dd:ee:ff",
                                                 descriptor: "Wi-Fi · router 10.0.0.1"),
                                   name: "Home")
        network.patternText = "nonsense"
        #expect(network.key == .network(gateway: "aa:bb:cc:dd:ee:ff",
                                        descriptor: "Wi-Fi · router 10.0.0.1"))
    }

    @Test("identity keys an address by pattern and scope, a network by gateway alone")
    func identity() {
        // Network labels have no scope, so scope must not enter their identity.
        let a = AddressLabel(pattern: "10.0.0.1", name: "A", scope: .localAddress)
        let b = AddressLabel(pattern: "10.0.0.1", name: "B", scope: .publicAddress)
        #expect(a.identity != b.identity)

        let key = AddressLabel.Key.network(gateway: "aa:bb:cc:dd:ee:ff", descriptor: "one")
        let other = AddressLabel.Key.network(gateway: "aa:bb:cc:dd:ee:ff", descriptor: "two")
        let c = AddressLabel(key: key, name: "Home", scope: .any)
        let d = AddressLabel(key: other, name: "Home", scope: .localAddress)
        #expect(c.identity == d.identity)
    }

    @Test("both kinds survive a Codable round trip")
    func codableRoundTrip() throws {
        let labels = [
            AddressLabel(pattern: "192.168.1.0/24", name: "LAN", scope: .localAddress),
            AddressLabel(key: .network(gateway: "74:24:9f:ab:0e:ab",
                                       descriptor: "Wi-Fi · router 172.16.132.1"),
                         name: "Home")
        ]
        let data = try JSONEncoder().encode(labels)
        let decoded = try JSONDecoder().decode([AddressLabel].self, from: data)
        #expect(decoded == labels)
    }
}
```

Add `import Foundation` to the top of `MatchingTests.swift` (it currently imports only `Testing`); `JSONEncoder` needs it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter LabelKindTests`
Expected: FAIL to compile — `AddressLabel` has no member `key`, `isNetwork`, `patternText`, `descriptor` or `identity`.

- [ ] **Step 3: Write the implementation**

Replace `Sources/IPBar/AddressLabel.swift:1-24` (the struct, up to and including `isValid`) with:

```swift
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
```

Leave the `extension Array where Element == AddressLabel` block below it untouched for now — Task 2 and Task 3 rewrite it. It will not compile yet because it reads `$0.pattern`; that is expected and fixed in Task 2.

- [ ] **Step 4: Make the existing array extension compile**

In the same file, in the `extension Array where Element == AddressLabel` block, replace the three uses of `$0.pattern == address` / `label.pattern` so the file builds. Change:

- In `setName`: `firstIndex(where: { $0.pattern == address && $0.scope == scope })` → `firstIndex(where: { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity })`
- In `hasOwnLabel`: `contains { $0.pattern == address && $0.scope == scope }` → `contains { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity }`
- In `removeLabel`: `removeAll { $0.pattern == address && $0.scope == scope }` → `removeAll { $0.identity == AddressLabel(pattern: address, name: "", scope: scope).identity }`
- In `name(for:scope:)`: `guard let prefix = label.prefix, prefix.contains(address)` already uses the computed `prefix`, so it needs no change.

Task 3 replaces these with something tidier. This step only restores the build.

- [ ] **Step 5: Run build and tests**

Run: `swift build && swift test --filter LabelKindTests`
Expected: build succeeds, 7 tests PASS.

- [ ] **Step 6: Run the whole suite for regressions**

Run: `swift test`
Expected: all pre-existing tests still PASS. The convenience `init(pattern:name:scope:)` keeps all 13 existing call sites compiling.

- [ ] **Step 7: Commit**

```bash
git add Sources/IPBar/AddressLabel.swift Tests/IPBarTests/MatchingTests.swift
git commit -m "feat(names): give a label two kinds of key"
```

---

### Task 2: Tiered ranking

**Files:**
- Modify: `Sources/IPBar/AddressLabel.swift` (the `name(for:scope:)` function in the array extension)
- Create: `Sources/IPBar/Gateway.swift` (the `NetworkKey` type only)
- Test: `Tests/IPBarTests/MatchingTests.swift` (new suite appended)

**Interfaces:**
- Consumes: `AddressLabel.Key` from Task 1.
- Produces: `NetworkKey(gateway: String, descriptor: String)`; `[AddressLabel].name(for:scope:networkKey:)` with `networkKey` defaulting to `nil`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IPBarTests/MatchingTests.swift`:

```swift
@Suite("Network label ranking")
struct NetworkRankingTests {
    private let home = NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                  descriptor: "Wi-Fi · router 172.16.132.1")
    private let elsewhere = NetworkKey(gateway: "00:11:22:33:44:55",
                                       descriptor: "Wi-Fi · router 10.0.0.1")

    private func network(_ name: String) -> AddressLabel {
        AddressLabel(key: .network(gateway: "74:24:9f:ab:0e:ab",
                                   descriptor: "Wi-Fi · router 172.16.132.1"),
                     name: name)
    }

    @Test("an exact address beats a network")
    func exactAddressWins() {
        let labels = [network("Home"), AddressLabel(pattern: "203.0.113.42", name: "Static")]
        #expect(labels.name(for: "203.0.113.42", scope: .publicAddress,
                            networkKey: home) == "Static")
    }

    @Test("a network beats any block")
    func networkBeatsBlocks() {
        let labels = [
            AddressLabel(pattern: "203.0.113.0/24", name: "Block"),
            AddressLabel(pattern: "0.0.0.0/0", name: "Anywhere"),
            network("Home")
        ]
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress,
                            networkKey: home) == "Home")
    }

    @Test("a block still wins when no network key is supplied")
    func withoutKey() {
        let labels = [AddressLabel(pattern: "203.0.113.0/24", name: "Block"), network("Home")]
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress) == "Block")
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress,
                            networkKey: nil) == "Block")
    }

    @Test("a network label on a different gateway does not match")
    func wrongGateway() {
        let labels = [network("Home")]
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress,
                            networkKey: elsewhere) == nil)
    }

    @Test("a network name applies to both scopes")
    func ignoresScope() {
        // Decision 6: a network name describes neither address, so it applies
        // wherever — even when the stored scope says otherwise.
        var label = network("Home")
        label.scope = .localAddress
        #expect([label].name(for: "203.0.113.9", scope: .publicAddress,
                             networkKey: home) == "Home")
        #expect([label].name(for: "192.168.1.5", scope: .localAddress,
                             networkKey: home) == "Home")
    }

    @Test("a blank network name is ignored")
    func blankName() {
        #expect([network("   ")].name(for: "203.0.113.9", scope: .publicAddress,
                                      networkKey: home) == nil)
    }

    @Test("longest prefix still decides between blocks")
    func prefixOrderingUnchanged() {
        let labels = [
            AddressLabel(pattern: "203.0.113.0/24", name: "Narrow"),
            AddressLabel(pattern: "203.0.0.0/16", name: "Wide")
        ]
        #expect(labels.name(for: "203.0.113.9", scope: .publicAddress,
                            networkKey: home) == "Narrow")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NetworkRankingTests`
Expected: FAIL to compile — `NetworkKey` is undefined and `name(for:scope:)` has no `networkKey` parameter.

- [ ] **Step 3: Create the `NetworkKey` type**

Create `Sources/IPBar/Gateway.swift`:

```swift
import Foundation

/// Identifies the network this Mac is attached to, by the link-layer address
/// of its gateway.
///
/// A gateway MAC is stable while an ISP rotates the public address behind it,
/// is the same across every satellite of a mesh network, and needs no
/// permission to read — unlike an SSID, which has required Location Services
/// since macOS 14.
struct NetworkKey: Hashable, Sendable {
    /// Lowercase, colon-separated, zero-padded: `74:24:9f:ab:0e:ab`.
    let gateway: String
    /// Captured when the network is named, for display only: `Wi-Fi · router 172.16.132.1`.
    let descriptor: String
}
```

- [ ] **Step 4: Rewrite the ranking**

In `Sources/IPBar/AddressLabel.swift`, replace the whole `name(for:scope:)` function with:

```swift
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
```

- [ ] **Step 5: Run the tests**

Run: `swift build && swift test --filter NetworkRankingTests`
Expected: 7 tests PASS.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all PASS. `LabelResolutionTests` in particular must still pass — the `networkKey` parameter defaults to `nil`, so existing call sites are unaffected.

- [ ] **Step 7: Commit**

```bash
git add Sources/IPBar/AddressLabel.swift Sources/IPBar/Gateway.swift Tests/IPBarTests/MatchingTests.swift
git commit -m "feat(names): rank a network key between addresses and blocks"
```

---

### Task 3: Naming a network updates rather than appends

**Files:**
- Modify: `Sources/IPBar/AddressLabel.swift` (array extension: `setName`, `hasOwnLabel`, `removeLabel`)
- Test: `Tests/IPBarTests/InlineNamingTests.swift` (new suite appended)

**Interfaces:**
- Consumes: `AddressLabel.identity` from Task 1, `NetworkKey` from Task 2.
- Produces: `[AddressLabel].setName(_:forKey:scope:)`, `.hasOwnLabel(forKey:scope:)`, `.removeLabel(forKey:scope:)`, and `.setNetworkName(_:for:)` taking a `NetworkKey`. The existing address-based overloads keep their signatures.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IPBarTests/InlineNamingTests.swift`:

```swift
@Suite("Naming a network")
struct NetworkNamingTests {
    private let home = NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                  descriptor: "Wi-Fi · router 172.16.132.1")

    @Test("naming a network appends one label carrying its descriptor")
    func names() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)

        #expect(labels.count == 1)
        #expect(labels[0].name == "Home")
        #expect(labels[0].key == .network(gateway: "74:24:9f:ab:0e:ab",
                                          descriptor: "Wi-Fi · router 172.16.132.1"))
    }

    @Test("renaming the same network updates in place")
    func renames() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("House", for: home)

        #expect(labels.count == 1)
        #expect(labels[0].name == "House")
    }

    @Test("a descriptor that has drifted does not create a second label")
    func descriptorDriftDoesNotDuplicate() {
        // The gateway alone is the identity. If the router's address changes,
        // the descriptor goes stale but the label must stay one label.
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("Home", for: NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                                      descriptor: "Wi-Fi · router 10.9.9.1"))
        #expect(labels.count == 1)
    }

    @Test("clearing the name removes the label")
    func clearing() {
        var labels: [AddressLabel] = []
        labels.setNetworkName("Home", for: home)
        labels.setNetworkName("   ", for: home)
        #expect(labels.isEmpty)
    }

    @Test("a network label does not collide with an address label")
    func noCollisionWithAddresses() {
        var labels = [AddressLabel(pattern: "203.0.113.42", name: "Office")]
        labels.setNetworkName("Home", for: home)
        #expect(labels.count == 2)
    }

    @Test("removing a network name leaves address labels alone")
    func removal() {
        var labels = [AddressLabel(pattern: "203.0.113.42", name: "Office")]
        labels.setNetworkName("Home", for: home)
        labels.removeLabel(forKey: .network(gateway: home.gateway, descriptor: home.descriptor),
                           scope: .any)
        #expect(labels.count == 1)
        #expect(labels[0].name == "Office")
    }

    @Test("hasOwnLabel finds a named network")
    func ownership() {
        var labels: [AddressLabel] = []
        #expect(!labels.hasOwnLabel(forKey: .network(gateway: home.gateway,
                                                     descriptor: home.descriptor), scope: .any))
        labels.setNetworkName("Home", for: home)
        #expect(labels.hasOwnLabel(forKey: .network(gateway: home.gateway,
                                                    descriptor: home.descriptor), scope: .any))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NetworkNamingTests`
Expected: FAIL to compile — no `setNetworkName`, `removeLabel(forKey:scope:)` or `hasOwnLabel(forKey:scope:)`.

- [ ] **Step 3: Write the implementation**

In `Sources/IPBar/AddressLabel.swift`, replace `setName`, `hasOwnLabel` and `removeLabel` (leaving `name(for:scope:networkKey:)` from Task 2 as it is) with:

```swift
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
```

Also revert the three temporary `AddressLabel(pattern: address, name: "", scope: scope).identity` expressions written in Task 1 Step 4 — the code above replaces them entirely.

- [ ] **Step 4: Run the tests**

Run: `swift build && swift test --filter NetworkNamingTests`
Expected: 7 tests PASS.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS, including the existing `InlineNamingTests` which call the address-based overloads.

- [ ] **Step 6: Commit**

```bash
git add Sources/IPBar/AddressLabel.swift Tests/IPBarTests/InlineNamingTests.swift
git commit -m "feat(names): key label edits by identity, not pattern"
```

---

### Task 4: Choosing which router is the key

**Files:**
- Modify: `Sources/IPBar/Gateway.swift`
- Test: `Tests/IPBarTests/GatewayTests.swift` (create)

**Interfaces:**
- Consumes: `NetworkKey` from Task 2.
- Produces: `RouterCandidate(serviceID: String, interface: String, router: String)`; `GatewaySelection.choose(candidates:physicalInterfaces:serviceOrder:) -> RouterCandidate?`; `GatewaySelection.formatMAC(_ bytes: [UInt8]) -> String`.

This task is the whole reason the feature works under a VPN, and it is pure — no system calls — so it is tested exhaustively.

- [ ] **Step 1: Write the failing test**

Create `Tests/IPBarTests/GatewayTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter GatewaySelectionTests`
Expected: FAIL to compile — `RouterCandidate` and `GatewaySelection` are undefined.

- [ ] **Step 3: Write the implementation**

Append to `Sources/IPBar/Gateway.swift`:

```swift
/// One service's router, as SystemConfiguration reports it.
struct RouterCandidate: Hashable, Sendable {
    let serviceID: String
    let interface: String
    let router: String
}

enum GatewaySelection {
    /// Picks the router belonging to the primary physical interface.
    ///
    /// Deliberately not the default route. With a full-tunnel VPN up the
    /// default route points at the tunnel, and a point-to-point tunnel has no
    /// link layer — so its gateway has no ARP entry and the key would vanish
    /// the moment you connect. Filtering to physical interfaces gives a key
    /// that is byte-identical before and after a tunnel comes up.
    ///
    /// With both Wi-Fi and Ethernet up, `ServiceOrder` from
    /// `Setup:/Network/Global/IPv4` decides — that is the user's own priority
    /// from Network settings, rather than a rule we invented. Services missing
    /// from the order sort last, and ties fall back to the interface name so
    /// the same inputs always give the same key.
    static func choose(candidates: [RouterCandidate],
                       physicalInterfaces: Set<String>,
                       serviceOrder: [String]) -> RouterCandidate? {
        let physical = candidates.filter { physicalInterfaces.contains($0.interface) }
        guard physical.count > 1 else { return physical.first }

        return physical.min { lhs, rhs in
            let left = serviceOrder.firstIndex(of: lhs.serviceID) ?? Int.max
            let right = serviceOrder.firstIndex(of: rhs.serviceID) ?? Int.max
            if left != right { return left < right }
            return lhs.interface < rhs.interface
        }
    }

    /// Lowercase, colon-separated, zero-padded. `arp -a` prints a leading zero
    /// nibble truncated, which would let two networks collide on one key.
    static func formatMAC(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
```

Add `import Foundation` at the top of `Gateway.swift` if Task 2 did not already (it did — `String(format:)` needs it).

- [ ] **Step 4: Run the tests**

Run: `swift build && swift test --filter "GatewaySelectionTests,MACFormattingTests"`
Expected: 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/IPBar/Gateway.swift Tests/IPBarTests/GatewayTests.swift
git commit -m "feat(gateway): pick the physical router, never the default route"
```

---

### Task 5: Reading the real gateway

**Files:**
- Modify: `Sources/IPBar/Gateway.swift`
- Modify: `Sources/IPBar/Diagnostics.swift:12-20` and `:56-68`

**Interfaces:**
- Consumes: `NetworkKey`, `RouterCandidate`, `GatewaySelection` from Tasks 2 and 4.
- Produces: `GatewayScanner.current(interfaces: [NetworkInterface]) -> NetworkKey?`, and `GatewayScanner.arpTable() -> [String: String]` mapping IPv4 address to MAC.

The `sysctl` walk is pointer arithmetic over live kernel state and is not unit-testable. It was proven by spike on macOS 26.6.2 (7,188 bytes, 38 resolved entries, gateway present). Its ongoing check is `--diagnose`, which this task wires up — hence the two being one task: the code and the only way to verify it ship together.

- [ ] **Step 1: Write the implementation**

Append to `Sources/IPBar/Gateway.swift`:

```swift
import Darwin
import SystemConfiguration

enum GatewayScanner {
    /// The network this Mac is attached to, or nil when there isn't one.
    ///
    /// Failure is always total rather than partial: any step coming up empty
    /// yields nil, so a name is never guessed. Cellular and tethered links have
    /// no ARP table at all, so they resolve to nil by construction.
    static func current(interfaces: [NetworkInterface]) -> NetworkKey? {
        let physical = Set(interfaces.filter { $0.kind.isPhysical }.map(\.bsdName))
        guard let chosen = GatewaySelection.choose(candidates: routerCandidates(),
                                                   physicalInterfaces: physical,
                                                   serviceOrder: serviceOrder()) else { return nil }
        guard let mac = arpTable()[chosen.router] else { return nil }

        let friendly = interfaces.first { $0.bsdName == chosen.interface }?.label
            ?? chosen.interface
        return NetworkKey(gateway: mac,
                          descriptor: "\(friendly) · router \(chosen.router)")
    }

    /// Every service reporting both an interface and a router.
    static func routerCandidates() -> [RouterCandidate] {
        guard let store = SCDynamicStoreCreate(nil, "IPBar.routers" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(
                store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [] }

        return keys.compactMap { key in
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = dict["InterfaceName"] as? String,
                  let router = dict["Router"] as? String else { return nil }
            let parts = key.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return RouterCandidate(serviceID: String(parts[2]),
                                   interface: interface, router: router)
        }
    }

    /// The user's own service priority from Network settings.
    static func serviceOrder() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "IPBar.order" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(
                store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
              let order = dict["ServiceOrder"] as? [String] else { return [] }
        return order
    }

    /// The ARP table, via the same `sysctl` call `arp -a` makes.
    ///
    /// Entries with `sdl_alen != 6` are incomplete — exactly the rows `arp -a`
    /// prints as `(incomplete)` — and are skipped.
    static func arpTable() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [:] }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return [:] }

        var result: [String: String] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < needed {
                let header = base.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self)
                let length = Int(header.pointee.rtm_msglen)
                guard length > 0 else { break }
                defer { offset += length }

                // RTA_DST first (sockaddr_inarp, layout-compatible with
                // sockaddr_in for the fields we read), then RTA_GATEWAY
                // (sockaddr_dl carrying the MAC).
                let dstOffset = offset + MemoryLayout<rt_msghdr>.stride
                guard dstOffset + MemoryLayout<sockaddr_in>.size <= needed else { continue }
                let dst = base.advanced(by: dstOffset)
                    .assumingMemoryBound(to: sockaddr_in.self)
                guard dst.pointee.sin_family == sa_family_t(AF_INET) else { continue }

                var addr = dst.pointee.sin_addr
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil
                else { continue }

                let dlOffset = dstOffset + roundup(Int(dst.pointee.sin_len))
                guard dlOffset + MemoryLayout<sockaddr_dl>.size <= needed else { continue }
                let link = base.advanced(by: dlOffset)
                    .assumingMemoryBound(to: sockaddr_dl.self)
                let addressLength = Int(link.pointee.sdl_alen)
                guard addressLength == 6 else { continue }

                let nameLength = Int(link.pointee.sdl_nlen)
                let mac = withUnsafeBytes(of: link.pointee.sdl_data) { bytes in
                    GatewaySelection.formatMAC((0..<addressLength).map { bytes[nameLength + $0] })
                }
                result[String(cString: host)] = mac
            }
        }
        return result
    }

    /// Route message sockaddrs are padded to a 4-byte boundary.
    private static func roundup(_ length: Int) -> Int {
        length > 0
            ? (1 + ((length - 1) | (MemoryLayout<UInt32>.size - 1)))
            : MemoryLayout<UInt32>.size
    }
}
```

- [ ] **Step 2: Wire it into `--diagnose`**

In `Sources/IPBar/Diagnostics.swift`, after the `VPN` line (currently line 20), insert:

```swift
        let networkKey = GatewayScanner.current(interfaces: interfaces)
        print("Network            \(networkKey?.gateway ?? "none")")
        print("                   \(networkKey?.descriptor ?? "no gateway — cellular, tethered, or offline")")
```

Then in the labels block, replace the `for label in labels` loop and the resolve loop with:

```swift
        for label in labels {
            let valid = label.isValid ? "" : "  [invalid]"
            switch label.key {
            case .prefix(let text):
                print("  \(text) → \(label.name) [\(label.scope.rawValue)]\(valid)")
            case .network(let gateway, let descriptor):
                print("  network \(gateway) (\(descriptor)) → \(label.name)\(valid)")
            }
        }
        for address in [v4?.address, v6?.address].compactMap({ $0 }) {
            let matched = labels.name(for: address, scope: .publicAddress,
                                      networkKey: networkKey) ?? "no match"
            print("  resolve \(address) → \(matched)")
        }
```

- [ ] **Step 3: Build and verify against reality**

Run: `swift build && swift run IPBar --diagnose`

Expected: a `Network` line showing a lowercase, zero-padded MAC and a descriptor like `Wi-Fi · router 172.16.132.1`.

Confirm it against the system:

Run: `arp -n $(scutil <<< "show State:/Network/Global/IPv4" | awk '/Router/ {print $3}')`

Expected: the same MAC, allowing for `arp` printing leading-zero nibbles truncated (`0e` vs `e`).

- [ ] **Step 4: Verify the VPN case**

If a VPN is available, connect it and re-run `swift run IPBar --diagnose`.
Expected: the `Network` line is **unchanged** from Step 3. If it changes or empties, `choose` is being handed tunnel candidates — check `NetworkInterface.Kind.isPhysical` is classifying `utun*` as `.tunnel`.

If no VPN is available, note it and move on; Task 4's `tunnelIgnored` test covers the logic.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/IPBar/Gateway.swift Sources/IPBar/Diagnostics.swift
git commit -m "feat(gateway): read the gateway MAC from the ARP table"
```

---

### Task 6: Threading the key through the model

**Files:**
- Modify: `Sources/IPBar/NetworkModel.swift:8-25` (properties and init), `:92-122` (`name`, `display`, `menuBarText`), `:232-248` (`refresh`)
- Test: `Tests/IPBarTests/NameDisplayTests.swift` (new suite appended)

**Interfaces:**
- Consumes: `NetworkKey`, `GatewayScanner.current` from Task 5; `name(for:scope:networkKey:)` from Task 2.
- Produces: `NetworkModel.networkKey: NetworkKey?`, `NetworkModel.networkName: String?`, and `NetworkModel.init(preferences:gateway:)` where `gateway` is `@Sendable ([NetworkInterface]) -> NetworkKey?` defaulting to `GatewayScanner.current`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IPBarTests/NameDisplayTests.swift`:

```swift
@Suite("A named network in the menu bar")
@MainActor
struct NetworkNameDisplayTests {
    private let home = NetworkKey(gateway: "74:24:9f:ab:0e:ab",
                                  descriptor: "Wi-Fi · router 172.16.132.1")

    private func model(_ mode: NameDisplay = .name,
                       source: DisplaySource = .publicAddress,
                       named: Bool = true) -> NetworkModel {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let preferences = Preferences(defaults: defaults)
        preferences.nameDisplay = mode
        preferences.displaySource = source
        if named {
            preferences.labels = [AddressLabel(key: .network(gateway: home.gateway,
                                                             descriptor: home.descriptor),
                                               name: "Home")]
        }
        let key = home
        return NetworkModel(preferences: preferences, gateway: { _ in key })
    }

    @Test("a network name replaces the public address")
    func replacesPublic() {
        let model = self.model()
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("a network name replaces a local address too")
    func replacesLocal() {
        let model = self.model(source: .localAddress)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("both mode shows one name rather than repeating it")
    func bothCollapses() {
        let model = self.model(source: .both)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home")
    }

    @Test("both mode still joins two different names")
    func bothJoins() {
        let model = self.model(source: .both, named: false)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "192.168.1.77 · 203.0.113.42")
    }

    @Test("name and address shows both")
    func nameAndAddress() {
        let model = self.model(.nameAndAddress)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "Home (203.0.113.42)")
    }

    @Test("the address setting suppresses a network name too")
    func addressOnly() {
        let model = self.model(.address)
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.menuBarText == "203.0.113.42")
    }

    @Test("an unknown network leaves the address alone")
    func unknownNetwork() {
        let model = self.model()
        let elsewhere = NetworkKey(gateway: "00:11:22:33:44:55", descriptor: "Wi-Fi · router 10.0.0.1")
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: elsewhere)
        #expect(model.menuBarText == "203.0.113.42")
        #expect(model.networkName == nil)
    }

    @Test("networkName reports the current network's name for the panel")
    func panelName() {
        let model = self.model()
        model.applyForTesting(publicIPv4: "203.0.113.42", local: "192.168.1.77", key: home)
        #expect(model.networkName == "Home")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NetworkNameDisplayTests`
Expected: FAIL to compile — no `init(preferences:gateway:)`, `networkName` or `applyForTesting`.

- [ ] **Step 3: Add the stored key and the seam**

In `Sources/IPBar/NetworkModel.swift`, after `private(set) var isRefreshing = false` add:

```swift
    /// The network this Mac is on, read after the public IP fetch so the
    /// gateway's ARP entry is populated by the traffic that lookup generates.
    private(set) var networkKey: NetworkKey?
```

Change the stored dependencies and init to:

```swift
    private let preferences: Preferences
    private let publicIP = PublicIPService()
    private let monitor = NWPathMonitor()
    private let gateway: @Sendable ([NetworkInterface]) -> NetworkKey?
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init(preferences: Preferences,
         gateway: @escaping @Sendable ([NetworkInterface]) -> NetworkKey? = GatewayScanner.current) {
        self.preferences = preferences
        self.gateway = gateway
    }
```

- [ ] **Step 4: Thread the key through display and the menu bar**

Replace `name(for:scope:)` and `display(_:scope:)` with:

```swift
    func name(for address: String, scope: AddressLabel.Scope) -> String? {
        preferences.labels.name(for: address, scope: scope, networkKey: networkKey)
    }

    /// The name of the network currently attached, for the panel's context row.
    var networkName: String? {
        guard let networkKey else { return nil }
        let match = preferences.labels.first {
            if case .network(let gateway, _) = $0.key { return gateway == networkKey.gateway }
            return false
        }
        let trimmed = match?.name.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Applies a matching label, however the menu bar has been asked to show
    /// named addresses. An address with no name is always just the address.
    func display(_ address: String?, scope: AddressLabel.Scope) -> String? {
        guard let address else { return nil }
        guard preferences.nameDisplay != .address,
              let name = name(for: address, scope: scope) else { return address }

        switch preferences.nameDisplay {
        case .name: return name
        case .nameAndAddress: return "\(name) (\(address))"
        case .address: return address
        }
    }
```

In `menuBarText`, replace the `.both` case with:

```swift
        case .both:
            let parts = [local, remote].compactMap { $0 }
            // A network name resolves for both halves, which would otherwise
            // read "Home · Home".
            if parts.count == 2, parts[0] == parts[1] { return parts[0] }
            return parts.isEmpty ? "No network" : parts.joined(separator: " · ")
```

- [ ] **Step 5: Read the key during refresh**

In `refresh()`, after `lastUpdated = Date()`, add:

```swift
        // After the fetch, deliberately: the lookup routes through the gateway,
        // which populates its ARP entry on a cold interface.
        networkKey = gateway(scanned)
```

- [ ] **Step 6: Add the test seam**

At the end of `NetworkModel`, beside `loadSampleData()`, add:

```swift
    /// Sets the state the menu bar is derived from, without touching the
    /// network. Used by tests only.
    func applyForTesting(publicIPv4: String?, local: String?, key: NetworkKey?) {
        interfaces = local.map {
            [NetworkInterface(bsdName: "en0", address: $0, family: .ipv4,
                              kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi")]
        } ?? []
        publicIPv4 = publicIPv4
        publicIPv6 = nil
        networkKey = key
        lastUpdated = Date()
    }
```

Note: `publicIPv4 = publicIPv4` is a self-assignment bug. Name the parameter `publicIPv4` but assign via `self`:

```swift
    func applyForTesting(publicIPv4: String?, local: String?, key: NetworkKey?) {
        interfaces = local.map {
            [NetworkInterface(bsdName: "en0", address: $0, family: .ipv4,
                              kind: .wifi, isLinkLocal: false, friendlyName: "Wi-Fi")]
        } ?? []
        self.publicIPv4 = publicIPv4
        self.publicIPv6 = nil
        self.networkKey = key
        self.lastUpdated = Date()
    }
```

- [ ] **Step 7: Run the tests**

Run: `swift build && swift test --filter NetworkNameDisplayTests`
Expected: 8 tests PASS.

- [ ] **Step 8: Run the whole suite**

Run: `swift test`
Expected: all PASS. `NameDisplayTests` uses `NetworkModel(preferences:)`, which still compiles because `gateway` has a default.

- [ ] **Step 9: Commit**

```bash
git add Sources/IPBar/NetworkModel.swift Tests/IPBarTests/NameDisplayTests.swift
git commit -m "feat(names): let a network name stand in for the address"
```

---

### Task 7: Settings shows network labels honestly

**Files:**
- Modify: `Sources/IPBar/SettingsView.swift:50-80`
- Test: manual — SwiftUI views have no test coverage in this repo.

**Interfaces:**
- Consumes: `AddressLabel.isNetwork`, `.descriptor`, `.patternText`, `.isValid` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Render network rows as static descriptors**

In `Sources/IPBar/SettingsView.swift`, replace the three `TableColumn` bodies with:

```swift
                TableColumn("Address, block or network") { $label in
                    if label.isNetwork {
                        // Captured when the network was named, not typed. A bare
                        // MAC is not something anyone can check, so the row shows
                        // where it was seen instead; --diagnose prints the key.
                        Text(label.descriptor ?? "Network")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("203.0.113.42", text: $label.patternText)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(label.isValid || label.name.isEmpty
                                             ? Color.primary : Color.red)
                    }
                }
                TableColumn("Name") { $label in
                    TextField("Office", text: $label.name).textFieldStyle(.plain)
                }
                TableColumn("Applies to") { $label in
                    if label.isNetwork {
                        // A network name describes neither address, so it applies
                        // wherever and the choice would be a lie.
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: $label.scope) {
                            ForEach(AddressLabel.Scope.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                }
```

- [ ] **Step 2: Explain that networks are named from the panel**

Replace the explanatory `Text` at the top of the `names` view with:

```swift
            Text("""
                 Give an address or range a name. IPBar shows the name in place of the \
                 address — useful for a static IP you recognise. Networks are named from \
                 the panel, since a gateway can only be read while you are on it.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 3: Build and check by eye**

Run: `swift build && swift run IPBar`

Open Settings → Names. Expected: the table header reads "Address, block or network"; existing address rows are unchanged and editable; the explanatory text mentions naming networks from the panel.

There will be no network rows to look at yet — Task 8 adds the way to create one. Re-check this screen after Task 8.

- [ ] **Step 4: Commit**

```bash
git add Sources/IPBar/SettingsView.swift
git commit -m "feat(settings): show a network label by where it was seen"
```

---

### Task 8: Naming a network from the panel

**Files:**
- Modify: `Sources/IPBar/MenuContent.swift:34-55` (body), `:92-116` (`localSection`), `:117-145` (`sectionHeader`), `:253-265` (context menu), `:415-430` (helpers)
- Test: manual — SwiftUI views have no test coverage in this repo.

**Interfaces:**
- Consumes: `NetworkModel.networkKey`, `.networkName` from Task 6; `[AddressLabel].setNetworkName(_:for:)` from Task 3.
- Produces: nothing consumed by later tasks.

This is the task the whole feature is judged on, so read the spec's "The panel" section before starting.

- [ ] **Step 1: Add a row key for the network**

`RowKey` currently identifies a row by address and scope. Add a case for the network. Near the top of `MenuContent`, add:

```swift
    /// The network's own row, which has no address. Kept separate from RowKey
    /// so the inline editor can target it without inventing a fake address.
    @State private var editingNetwork = false
```

- [ ] **Step 2: Add the context row**

In `body`, immediately before the `publicSection`, add:

```swift
            if let networkName = model.networkName {
                networkRow(named: networkName)
            }
```

Then add the view itself, beside `publicSection`:

```swift
    /// The network's name, above everything else: once it replaces the address
    /// in the menu bar it stops being one fact among several and becomes the
    /// headline. A panel opening with "Public" while the bar says "Home" makes
    /// you hunt for where the word came from.
    ///
    /// Absent entirely until a network is named, so anyone who only wanted an
    /// IP address never sees it.
    private func networkRow(named name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if editingNetwork {
                TextField("Name this network", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($nameFieldFocused)
                    .onSubmit { commitNetworkName() }
                    .onExitCommand { editingNetwork = false }
                Text("↩ save · esc cancel")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                if let descriptor = model.networkKey?.descriptor {
                    Text(descriptor)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .contextMenu {
            Button("Rename…") { beginNetworkNaming(current: name) }
            Button("Remove Name") {
                guard let key = model.networkKey else { return }
                preferences.labels.setNetworkName("", for: key)
            }
        }
    }
```

- [ ] **Step 3: Add the hover button to the This Mac header**

`sectionHeader` takes a trailing view. Change the `localSection` call from:

```swift
            sectionHeader("This Mac") { EmptyView() }
```

to:

```swift
            sectionHeader("This Mac") {
                // Primary path, mirroring the hover Name button on an address
                // row. Hidden when no gateway resolves — cellular and tethered
                // links have no ARP table, and an affordance that appears then
                // fails is worse than one that is absent.
                if model.networkKey != nil, model.networkName == nil, hoveringLocalHeader {
                    Button("Name network") { beginNetworkNaming(current: "") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .onHover { hoveringLocalHeader = $0 }
```

Add the state near the other `@State` properties:

```swift
    @State private var hoveringLocalHeader = false
```

- [ ] **Step 4: Add the context menu entry**

In the address row's `.contextMenu`, after the existing `Button("Copy Address")`, add:

```swift
            // Secondary path, exactly as addresses get both a hover button and
            // a context-menu entry.
            if key.scope == .localAddress, model.networkKey != nil {
                Divider()
                Button(model.networkName == nil ? "Name This Network…" : "Rename Network…") {
                    beginNetworkNaming(current: model.networkName ?? "")
                }
            }
```

- [ ] **Step 5: Add the naming helpers**

Beside the existing naming helpers near `hasOwnLabel`, add:

```swift
    private func beginNetworkNaming(current: String) {
        draftName = current
        editing = nil
        editingNetwork = true
        // Asking once is unreliable: on the first open the field is not yet in
        // the hierarchy. The same two-step the address editor uses.
        nameFieldFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            nameFieldFocused = true
        }
    }

    private func commitNetworkName() {
        defer { editingNetwork = false }
        guard let key = model.networkKey else { return }
        preferences.labels.setNetworkName(draftName, for: key)
    }
```

If `editingNetwork` is true, the context row renders the editor even when `networkName` is nil, so change the `body` condition from Step 2 to:

```swift
            if let networkName = model.networkName {
                networkRow(named: networkName)
            } else if editingNetwork {
                networkRow(named: "")
            }
```

- [ ] **Step 6: Build and exercise it by hand**

Run: `swift build && swift run IPBar`

Walk through all of these:

1. Open the panel. Expected: **no** network row (nothing named yet).
2. Hover the **This Mac** header. Expected: a `Name network` button appears.
3. Click it, type `Home`, press Return. Expected: the row appears at the top reading `Home` with `Wi-Fi · router …` beside it, and the menu bar changes to `Home`.
4. Right-click the row → **Rename…**, change it, press Return. Expected: both row and menu bar update.
5. Open Settings → Names. Expected: a row whose first column reads `Wi-Fi · router …` in grey, non-editable, with `—` under Applies to.
6. Right-click the row → **Remove Name**. Expected: the row disappears and the menu bar returns to the address.
7. Right-click a **This Mac** address row. Expected: `Name This Network…` below a divider.
8. Press Escape mid-edit. Expected: the edit is abandoned and nothing is stored.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/IPBar/MenuContent.swift
git commit -m "feat(panel): name the network you are on"
```

---

### Task 9: Document it

**Files:**
- Modify: `README.md:47-77` (the "Naming an address" section), `README.md:196-214` (the Layout table)
- Modify: `ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Rewrite the naming section**

In `README.md`, after the paragraph beginning "Right-click also offers **Rename**", insert:

```markdown
## Naming a network

A name tied to an address only holds while the address does. If your ISP rotates yours,
every name you set decays into a stale entry matching nothing.

So a name can attach to the network instead. Hover the **This Mac** header in the panel and
click **Name network**, or right-click any local address and choose **Name This Network…**.
The name then follows you to that network whatever address it hands out.

A network is identified by the MAC address of its gateway. That stays put while the address
behind it rotates, and it is the same across every satellite of a mesh network, so "Home"
does not stop matching in the back bedroom. It also needs no permission to read — an SSID
has required Location Services since macOS 14, and IPBar asks you for nothing.

Naming is only available where there is a gateway to read. Cellular and tethered links are
point-to-point and have no ARP table, so the option does not appear there.

When a network name and an address label both match, the most specific still wins:

| Wins over | Kind |
| --- | --- |
| everything | an exact address, `203.0.113.42` |
| every block | the network you are on |
| narrower blocks only | a block, `203.0.113.0/24` |

Networks are named from the panel rather than Settings, because a gateway can only be read
while you are standing on it. Settings shows the network by where it was last seen —
`Wi-Fi · router 192.168.1.1` — since a bare MAC address is not something anyone can check.
`IPBar --diagnose` prints the key itself.
```

- [ ] **Step 2: Add the new file to the Layout table**

In the Layout table in `README.md`, after the `VPNState.swift` row, add:

```markdown
| `Gateway.swift` | the gateway MAC that identifies a network |
```

- [ ] **Step 3: Tick the roadmap entry**

In `ROADMAP.md`, change the heading `## Next — name networks, not addresses` to `## Done — name networks, not addresses`, and replace the body's three open design questions with:

```markdown
Shipped. The key is the gateway MAC of the primary **physical** interface — never the
default route, which a full-tunnel VPN displaces onto a tunnel whose gateway has no ARP
entry at all. `ServiceOrder` breaks the tie when Wi-Fi and Ethernet are both up.

Design decisions and the spike that settled the mechanics are in
[the design doc](docs/superpowers/specs/2026-09-13-name-networks-design.md).
```

Then promote the following section from `## Then —` to `## Next —`.

- [ ] **Step 4: Check the documentation is true**

Run: `swift run IPBar --diagnose`

Read the README section you just wrote against what the binary prints. Every claim about behaviour must match. In particular check the cellular claim is phrased as a limitation and not a promise you cannot verify on a Mac with no cellular modem.

- [ ] **Step 5: Commit**

```bash
git add README.md ROADMAP.md
git commit -m "docs: explain naming a network"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Decision 1 — name replaces either address | 6 (`replacesPublic`, `replacesLocal`) |
| Decision 2 — most specific wins, network in the middle | 2 |
| Decision 3 — created in place, descriptor captured | 3, 7, 8 |
| Decision 4 — context row, hidden until named | 8 |
| Decision 5 — hover and right-click | 8 |
| Decision 6 — network labels have no scope | 1 (`identity`), 2 (`ignoresScope`), 7 (`—` cell) |
| Gateway discovery, steps 1–5 | 4 (selection), 5 (plumbing) |
| Ordering within a refresh | 6 (Step 5) |
| Data model, `Key` enum | 1 |
| Uniqueness of a gateway key | 3 |
| Array extensions re-expressed by `Key` | 3 |
| Matching and ranking | 2 |
| `.both` collapse | 6 (`bothCollapses`, `bothJoins`) |
| `NameDisplay` interaction | 6 |
| Menu bar qualifier unchanged | no task — nothing to change, asserted by existing `MenuBarGlyphTests` |
| Panel context row and naming flow | 8 |
| Naming unavailable with no key | 8 (Step 3 condition) |
| Limitations documented | 9 |
| Testing plan | 1, 2, 3, 4, 6 |
| `--diagnose` output | 5 |
| Files table | all |

No gaps.

**Placeholder scan:** no TBD, TODO, "handle edge cases", or "similar to Task N". Every code step carries the code.

**Type consistency:** `NetworkKey(gateway:descriptor:)` is defined in Task 2 and used identically in 3, 4, 5, 6 and 8. `AddressLabel.Key.network(gateway:descriptor:)` keeps its labels throughout. `GatewaySelection.choose(candidates:physicalInterfaces:serviceOrder:)` and `.formatMAC(_:)` are defined in Task 4 and called in Task 5 with matching signatures. `setNetworkName(_:for:)` is defined in Task 3 and called in Task 8. `model.networkKey` and `model.networkName` are defined in Task 6 and read in Task 8.

One deliberate wrinkle worth flagging to the executor: **Task 1 Step 4 writes throwaway code** that Task 3 deletes. It exists only so the build is green at the end of Task 1 — without it, Task 1 cannot be committed independently, and every task must end with a passing build.
