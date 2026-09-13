# Change Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell the user when their VPN stops covering their traffic, and when their public IP changes — held for ten seconds first, so a reconnecting VPN never cries wolf.

**Architecture:** A pure `ChangeDetector` decides which transitions are worth announcing, mirroring how `GatewaySelection` sits beside `GatewayScanner`. A `Notifier` protocol wraps `UNUserNotificationCenter` behind a mandatory bundle-identifier guard. `NetworkModel` holds a baseline snapshot and a single confirmation window, and posts only what survives it.

**Tech Stack:** Swift 6 (language mode v6), SwiftUI, SwiftPM, Swift Testing (`@Suite`/`@Test`/`#expect`), UserNotifications, SystemConfiguration.

**Spec:** `docs/superpowers/specs/2026-09-13-change-notifications-design.md`

## Global Constraints

- **Platform floor:** macOS 14 (`Package.swift` declares `.macOS(.v14)`, `Info.plist` declares `LSMinimumSystemVersion 14.0`). Do not raise it.
- **Swift language mode v6** on both targets. All shared types must be `Sendable`; `NetworkModel` and `Preferences` are `@MainActor`.
- **`swift test` must need no network and no notification permission.** A test run must never produce a system prompt.
- **No new dependencies.** `Package.swift` has zero and gains none. `UserNotifications` is a system framework.
- **`Bundle.main.bundleIdentifier != nil` is the only defence against a crash.** `UNUserNotificationCenter.current()` raises `NSInternalInconsistencyException` without a bundle — an Objective-C exception Swift **cannot catch**. `swift run` and `swift test` both have a nil bundle identifier. Every path reaching the notification centre must sit behind this check.
- **Both toggles default to `false`.** The permission prompt fires only when a user turns one on.
- **Coverage ordering is `off` < `split` < `full`.** The enum declares its cases as `off, full, split`, so declaration order is the *opposite* of coverage order and must never be relied on.
- **No polling.** Refresh stays driven by `NWPathMonitor`, wake, and the user's timer. The confirmation window is a one-shot task, not a loop.
- **Conventional Commits**, enforced by `.githooks/commit-msg`. Types: `feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert`. **Header max 72 characters.**
- **Run `swift build` before `swift test`** — a compile error in `Sources/` surfaces faster than through the test target.

## One deliberate deviation from the spec

The spec sketches `func post(_ change: NetworkChange, naming: @Sendable (String) -> String?) async`, so that `Notifier` can resolve a name without depending on `Preferences`.

**That signature does not survive Swift 6.** The closure would have to capture `Preferences` and `NetworkModel.networkKey`, both `@MainActor`-isolated, inside a `@Sendable` closure crossing an actor boundary.

This plan resolves the name on the MainActor *before* calling `post`, and passes the result:

```swift
func post(_ change: NetworkChange, newAddressName: String?) async
```

The spec's intent is preserved exactly — `Notifier` still knows nothing about `Preferences` — and the concurrency problem disappears. Use this signature throughout.

---

### Task 1: Deciding what is worth announcing

**Files:**
- Create: `Sources/IPBar/NetworkChange.swift`
- Modify: `Sources/IPBar/VPNState.swift:18-20`
- Test: `Tests/IPBarTests/ChangeDetectorTests.swift` (create)

**Interfaces:**
- Consumes: `VPNState.Mode` (cases `off`, `full`, `split`).
- Produces: `NetworkSnapshot(publicIP: String?, vpn: VPNState.Mode)`; `NetworkChange` with cases `.vpnWeakened(from: VPNState.Mode, to: VPNState.Mode)` and `.publicIPChanged(from: String, to: String)`; `ChangeDetector.changes(from:to:) -> [NetworkChange]`; `VPNState.Mode.coverage: Int` and `VPNState.Mode: CaseIterable`.

This is the whole of the feature's judgement, and it is pure — no system calls, no timing, no permissions. Test it exhaustively.

- [ ] **Step 1: Write the failing test**

Create `Tests/IPBarTests/ChangeDetectorTests.swift`:

```swift
import Testing
@testable import IPBar

@Suite("Which changes are worth announcing")
struct ChangeDetectorTests {
    private func snap(_ ip: String?, _ vpn: VPNState.Mode) -> NetworkSnapshot {
        NetworkSnapshot(publicIP: ip, vpn: vpn)
    }

    // MARK: VPN

    @Test("a weakening tunnel is announced", arguments: [
        (VPNState.Mode.full, VPNState.Mode.off),
        (.full, .split),
        (.split, .off)
    ])
    func weakening(_ pair: (VPNState.Mode, VPNState.Mode)) {
        let changes = ChangeDetector.changes(from: snap("203.0.113.42", pair.0),
                                             to: snap("203.0.113.42", pair.1))
        #expect(changes == [.vpnWeakened(from: pair.0, to: pair.1)])
    }

    @Test("a strengthening or unchanged tunnel is silent", arguments: [
        (VPNState.Mode.off, VPNState.Mode.full),
        (.off, .split),
        (.split, .full),
        (.off, .off),
        (.full, .full),
        (.split, .split)
    ])
    func notWeakening(_ pair: (VPNState.Mode, VPNState.Mode)) {
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", pair.0),
                                       to: snap("203.0.113.42", pair.1)).isEmpty)
    }

    @Test("every mode pair is accounted for")
    func allPairsCovered() {
        // Guards against a fourth mode being added and silently falling
        // through whichever branch happens to catch it.
        var weakening = 0
        for from in VPNState.Mode.allCases {
            for to in VPNState.Mode.allCases {
                let changes = ChangeDetector.changes(from: snap("1.1.1.1", from),
                                                     to: snap("1.1.1.1", to))
                if !changes.isEmpty { weakening += 1 }
            }
        }
        #expect(VPNState.Mode.allCases.count == 3)
        #expect(weakening == 3)
    }

    @Test("coverage ordering is explicit, not declaration order")
    func coverageOrdering() {
        // The enum declares `off, full, split`, so declaration order says the
        // opposite of what coverage means.
        #expect(VPNState.Mode.off.coverage < VPNState.Mode.split.coverage)
        #expect(VPNState.Mode.split.coverage < VPNState.Mode.full.coverage)
    }

    // MARK: Public IP

    @Test("a different address is announced")
    func addressChanged() {
        let changes = ChangeDetector.changes(from: snap("203.0.113.41", .off),
                                             to: snap("203.0.113.42", .off))
        #expect(changes == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("the same address is silent")
    func addressUnchanged() {
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", .off),
                                       to: snap("203.0.113.42", .off)).isEmpty)
    }

    @Test("losing the address is not a change")
    func addressLost() {
        // The struck-through globe already says the internet is unreachable.
        #expect(ChangeDetector.changes(from: snap("203.0.113.42", .off),
                                       to: snap(nil, .off)).isEmpty)
    }

    @Test("a first address with no baseline is not a change")
    func firstAddress() {
        #expect(ChangeDetector.changes(from: snap(nil, .off),
                                       to: snap("203.0.113.42", .off)).isEmpty)
    }

    // MARK: Both at once

    @Test("both changing yields both, VPN first")
    func bothChanged() {
        let changes = ChangeDetector.changes(from: snap("203.0.113.41", .full),
                                             to: snap("203.0.113.42", .off))
        #expect(changes == [.vpnWeakened(from: .full, to: .off),
                            .publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ChangeDetectorTests`
Expected: FAIL to compile — `NetworkSnapshot`, `NetworkChange`, `ChangeDetector` and `Mode.coverage` are undefined, and `Mode` is not `CaseIterable`.

- [ ] **Step 3: Make `Mode` orderable and enumerable**

In `Sources/IPBar/VPNState.swift`, replace the `Mode` enum declaration (lines 18-20) with:

```swift
    enum Mode: String, CaseIterable, Sendable {
        case off, full, split

        /// How much of your traffic this mode covers, lowest first.
        ///
        /// Written out rather than derived: the cases above are declared
        /// `off, full, split`, so declaration order says the opposite of
        /// coverage and relying on it would invert the whole rule.
        var coverage: Int {
            switch self {
            case .off: return 0
            case .split: return 1
            case .full: return 2
            }
        }
    }
```

- [ ] **Step 4: Write the detector**

Create `Sources/IPBar/NetworkChange.swift`:

```swift
import Foundation

/// The facts a notification can be derived from, captured at one moment.
struct NetworkSnapshot: Hashable, Sendable {
    let publicIP: String?
    let vpn: VPNState.Mode
}

/// Something worth interrupting the user about.
enum NetworkChange: Hashable, Sendable {
    case vpnWeakened(from: VPNState.Mode, to: VPNState.Mode)
    case publicIPChanged(from: String, to: String)
}

enum ChangeDetector {
    /// The changes worth announcing, going from `baseline` to `current`.
    ///
    /// The VPN rule is that the tunnel now covers less than it did, not that
    /// it disappeared. `full → split` is the case that motivates it: a full
    /// tunnel dies while a mesh VPN stays up, so general traffic starts
    /// leaving in the clear while the panel still reads "some traffic through
    /// a VPN". A drop-only rule says nothing about the most dangerous state
    /// this app can observe.
    ///
    /// A missing public address is never a change. Losing the internet is not
    /// an address changing, and the struck-through globe already says it —
    /// which also means a first observation, with no address to compare
    /// against, announces nothing.
    static func changes(from baseline: NetworkSnapshot,
                        to current: NetworkSnapshot) -> [NetworkChange] {
        var changes: [NetworkChange] = []

        if current.vpn.coverage < baseline.vpn.coverage {
            changes.append(.vpnWeakened(from: baseline.vpn, to: current.vpn))
        }

        if let was = baseline.publicIP, let now = current.publicIP, was != now {
            changes.append(.publicIPChanged(from: was, to: now))
        }

        return changes
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift build && swift test --filter ChangeDetectorTests`
Expected: all PASS.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all pre-existing tests still PASS. `Mode` gaining `CaseIterable` and a computed property changes no existing behaviour.

- [ ] **Step 7: Commit**

```bash
git add Sources/IPBar/NetworkChange.swift Sources/IPBar/VPNState.swift Tests/IPBarTests/ChangeDetectorTests.swift
git commit -m "feat(notify): detect changes worth announcing"
```

---

### Task 2: The notifier, behind a bundle guard

**Files:**
- Create: `Sources/IPBar/Notifier.swift`
- Test: `Tests/IPBarTests/NotifierTests.swift` (create)

**Interfaces:**
- Consumes: `NetworkChange` from Task 1.
- Produces: `NotifierAuthorization` (`.unavailable`, `.notDetermined`, `.authorized`, `.denied`); `protocol Notifier` with `requestAuthorization() async -> Bool`, `authorizationStatus() async -> NotifierAuthorization`, `post(_ change: NetworkChange, newAddressName: String?) async`; `SystemNotifier`; `NetworkChange.notificationTitle` and `.notificationBody(newAddressName:)`.

**Read the Global Constraints on the bundle guard before writing a line of this.** Getting it wrong does not fail a test — it aborts the whole test run.

- [ ] **Step 1: Write the failing test**

Create `Tests/IPBarTests/NotifierTests.swift`:

```swift
import Foundation
import Testing
@testable import IPBar

@Suite("What a notification says")
struct NotificationWordingTests {
    @Test("a tunnel that vanished says so plainly")
    func disconnected() {
        let change = NetworkChange.vpnWeakened(from: .full, to: .off)
        #expect(change.notificationTitle == "VPN disconnected")
        #expect(change.notificationBody(newAddressName: nil)
                == "All traffic is now in the clear")
    }

    @Test("a full tunnel degrading to split does not say dropped")
    func degraded() {
        // The tunnel is still up, so "dropped" would be untrue — but general
        // traffic is now unprotected, which is the point of saying anything.
        let change = NetworkChange.vpnWeakened(from: .full, to: .split)
        #expect(change.notificationTitle == "VPN no longer carrying all traffic")
        #expect(change.notificationBody(newAddressName: nil)
                == "Some traffic is now in the clear")
    }

    @Test("a split tunnel vanishing says no tunnel is up")
    func splitGone() {
        let change = NetworkChange.vpnWeakened(from: .split, to: .off)
        #expect(change.notificationTitle == "VPN disconnected")
        #expect(change.notificationBody(newAddressName: nil) == "No tunnel is up")
    }

    @Test("an address change shows both addresses")
    func addressChange() {
        let change = NetworkChange.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")
        #expect(change.notificationTitle == "Public IP changed")
        #expect(change.notificationBody(newAddressName: nil)
                == "203.0.113.41 → 203.0.113.42")
    }

    @Test("a named new address is named")
    func namedAddressChange() {
        let change = NetworkChange.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")
        #expect(change.notificationBody(newAddressName: "Home")
                == "203.0.113.41 → Home (203.0.113.42)")
    }

    @Test("a name is ignored for a VPN change")
    func nameIrrelevantToVPN() {
        let change = NetworkChange.vpnWeakened(from: .full, to: .off)
        #expect(change.notificationBody(newAddressName: "Home")
                == "All traffic is now in the clear")
    }
}

@Suite("The system notifier without a bundle")
struct SystemNotifierTests {
    @Test("swift test really does run without a bundle identifier")
    func noBundleUnderTest() {
        // The premise the next test rests on. If this ever becomes non-nil,
        // the test below stops proving anything and a real prompt becomes
        // possible during a test run.
        #expect(Bundle.main.bundleIdentifier == nil)
    }

    @Test("it is inert rather than fatal when there is no bundle")
    func inertWithoutBundle() async {
        // UNUserNotificationCenter.current() raises an Objective-C exception
        // without a bundle, which Swift cannot catch — so a missing guard
        // would not fail this test, it would abort the entire run.
        let notifier = SystemNotifier()
        await notifier.post(.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42"),
                            newAddressName: nil)
        #expect(await notifier.authorizationStatus() == .unavailable)
        #expect(await notifier.requestAuthorization() == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "NotificationWordingTests,SystemNotifierTests"`
Expected: FAIL to compile — `SystemNotifier`, `NotifierAuthorization` and the wording properties are undefined.

- [ ] **Step 3: Write the notifier**

Create `Sources/IPBar/Notifier.swift`:

```swift
import Foundation
import UserNotifications

/// Whether this app can notify, and whether it has been allowed to.
enum NotifierAuthorization: Sendable {
    /// No bundle, so the notification centre cannot be reached at all.
    case unavailable
    case notDetermined
    case authorized
    case denied
}

protocol Notifier: Sendable {
    /// Asks the user. Returns whether notifications may now be posted.
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotifierAuthorization
    func post(_ change: NetworkChange, newAddressName: String?) async
}

extension NetworkChange {
    var notificationTitle: String {
        switch self {
        case .vpnWeakened(_, let to):
            return to == .off ? "VPN disconnected" : "VPN no longer carrying all traffic"
        case .publicIPChanged:
            return "Public IP changed"
        }
    }

    /// `newAddressName` is resolved by the caller, so nothing here needs to
    /// know about stored labels. It is ignored for VPN changes, which describe
    /// the tunnel rather than an address.
    func notificationBody(newAddressName: String?) -> String {
        switch self {
        case .vpnWeakened(let from, let to):
            switch (from, to) {
            case (.full, .off): return "All traffic is now in the clear"
            case (.full, .split): return "Some traffic is now in the clear"
            default: return "No tunnel is up"
            }
        case .publicIPChanged(let from, let to):
            let arrival = newAddressName.map { "\($0) (\(to))" } ?? to
            return "\(from) → \(arrival)"
        }
    }
}

/// The real thing, guarded.
///
/// `UNUserNotificationCenter.current()` raises `NSInternalInconsistencyException`
/// when the process has no bundle identifier — an Objective-C exception with no
/// Swift `catch`, so the process aborts. `swift run` and `swift test` both run
/// without a bundle, which makes checking first the only available defence
/// rather than a courtesy. Without a bundle this type does nothing at all.
struct SystemNotifier: Notifier {
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let granted = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])
        return granted ?? false
    }

    func authorizationStatus() async -> NotifierAuthorization {
        guard isAvailable else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func post(_ change: NetworkChange, newAddressName: String?) async {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = change.notificationTitle
        content.body = change.notificationBody(newAddressName: newAddressName)

        // No sound, no badge, no action. There is nothing useful to open —
        // MenuBarExtra cannot be opened programmatically, and Settings is not
        // where anyone would want to land.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift build && swift test --filter "NotificationWordingTests,SystemNotifierTests"`
Expected: all PASS. If the run **aborts** rather than failing, the bundle guard is missing or wrong — fix it before going further.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS, and the run completes rather than aborting.

- [ ] **Step 6: Commit**

```bash
git add Sources/IPBar/Notifier.swift Tests/IPBarTests/NotifierTests.swift
git commit -m "feat(notify): add the notifier behind a bundle guard"
```

---

### Task 3: The two toggles

**Files:**
- Modify: `Sources/IPBar/Preferences.swift:35-41` (stored properties), `:65-68` (`Key` enum), `:71-85` (`init`)
- Test: `Tests/IPBarTests/PreferencesTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `Preferences.notifyOnVPNWeakened: Bool` and `Preferences.notifyOnPublicIPChange: Bool`, both defaulting to `false`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IPBarTests/PreferencesTests.swift`:

```swift
@Suite("Notification toggles")
@MainActor
struct NotificationPreferenceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("both toggles are off until asked for")
    func defaultsOff() {
        // Off by default is what keeps the promise that IPBar asks the user
        // for nothing: the permission prompt only ever follows a deliberate
        // switch being turned on.
        let preferences = Preferences(defaults: freshDefaults())
        #expect(preferences.notifyOnVPNWeakened == false)
        #expect(preferences.notifyOnPublicIPChange == false)
    }

    @Test("both toggles persist")
    func persists() {
        let defaults = freshDefaults()
        let first = Preferences(defaults: defaults)
        first.notifyOnVPNWeakened = true
        first.notifyOnPublicIPChange = true

        let second = Preferences(defaults: defaults)
        #expect(second.notifyOnVPNWeakened)
        #expect(second.notifyOnPublicIPChange)
    }

    @Test("turning one off again persists as off")
    func persistsOff() {
        let defaults = freshDefaults()
        let first = Preferences(defaults: defaults)
        first.notifyOnVPNWeakened = true
        first.notifyOnVPNWeakened = false

        #expect(Preferences(defaults: defaults).notifyOnVPNWeakened == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter NotificationPreferenceTests`
Expected: FAIL to compile — `Preferences` has no `notifyOnVPNWeakened` or `notifyOnPublicIPChange`.

- [ ] **Step 3: Add the stored properties**

In `Sources/IPBar/Preferences.swift`, after the `refreshMinutes` property, add:

```swift
    var notifyOnVPNWeakened: Bool { didSet { write(notifyOnVPNWeakened, .notifyOnVPNWeakened) } }
    var notifyOnPublicIPChange: Bool { didSet { write(notifyOnPublicIPChange, .notifyOnPublicIPChange) } }
```

In the `Key` enum, add the two cases:

```swift
        case notifyOnVPNWeakened, notifyOnPublicIPChange
```

In `init`, after the `refreshMinutes` assignment, add:

```swift
        // Default false, deliberately: turning one on is what triggers the
        // only permission prompt this app has ever shown.
        notifyOnVPNWeakened = defaults.bool(forKey: Key.notifyOnVPNWeakened.rawValue)
        notifyOnPublicIPChange = defaults.bool(forKey: Key.notifyOnPublicIPChange.rawValue)
```

`UserDefaults.bool(forKey:)` returns `false` for a missing key, which is the wanted default — unlike the `object(forKey:) as? Bool ?? true` pattern used by the properties that default on.

- [ ] **Step 4: Run the tests**

Run: `swift build && swift test --filter NotificationPreferenceTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/IPBar/Preferences.swift Tests/IPBarTests/PreferencesTests.swift
git commit -m "feat(notify): add the two notification toggles"
```

---

### Task 4: Baseline and confirmation

**Files:**
- Modify: `Sources/IPBar/NetworkModel.swift` — properties and `init` (around lines 8-32), `refresh()` (around lines 250-280)
- Test: `Tests/IPBarTests/ConfirmationTests.swift` (create)

**Interfaces:**
- Consumes: `ChangeDetector.changes(from:to:)`, `NetworkSnapshot`, `NetworkChange` from Task 1; `Notifier`, `NotifierAuthorization` from Task 2; `Preferences.notifyOnVPNWeakened` / `.notifyOnPublicIPChange` from Task 3.
- Produces: `NetworkModel.init(preferences:gateway:notifier:confirmationDelay:)` with defaults for the last three; `NetworkModel.noteChangesForTesting(snapshot:) async` as the test seam.

This is the task that carries the ten-second window. Read the spec's decisions 3, 4 and 5 before starting — the baseline rules are subtle and each exists to fix a specific wrong behaviour.

- [ ] **Step 1: Write the failing test**

Create `Tests/IPBarTests/ConfirmationTests.swift`:

```swift
import Foundation
import Testing
@testable import IPBar

/// Records what would have been shown, so nothing reaches the real
/// notification centre — which, with no bundle under `swift test`, would
/// abort the run rather than fail a test.
actor SpyNotifier: Notifier {
    private(set) var posted: [(change: NetworkChange, name: String?)] = []
    private let granted: Bool

    init(granted: Bool = true) { self.granted = granted }

    func requestAuthorization() async -> Bool { granted }
    func authorizationStatus() async -> NotifierAuthorization {
        granted ? .authorized : .denied
    }
    func post(_ change: NetworkChange, newAddressName: String?) async {
        posted.append((change, newAddressName))
    }
    var changes: [NetworkChange] { posted.map(\.change) }
}

@Suite("Confirming a change before announcing it")
@MainActor
struct ConfirmationTests {
    private func model(vpn: Bool = true, ip: Bool = true,
                       notifier: SpyNotifier) -> NetworkModel {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let preferences = Preferences(defaults: defaults)
        preferences.notifyOnVPNWeakened = vpn
        preferences.notifyOnPublicIPChange = ip

        return NetworkModel(preferences: preferences,
                            gateway: { _ in nil },
                            notifier: notifier,
                            confirmationDelay: .zero)
    }

    private func snap(_ ip: String?, _ vpn: VPNState.Mode) -> NetworkSnapshot {
        NetworkSnapshot(publicIP: ip, vpn: vpn)
    }

    @Test("the first observation announces nothing")
    func firstObservation() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a real drop is announced")
    func realDrop() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .off)])
    }

    @Test("a blip that heals is never announced")
    func blipHeals() async {
        // full → off → full re-evaluates against the baseline as full → full,
        // which is not a weakening at all.
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a partial recovery is announced as what it actually is")
    func partialRecovery() async {
        // full → off → split must announce full → split, not the stale full → off.
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .split))
        #expect(await spy.changes == [.vpnWeakened(from: .full, to: .split)])
    }

    @Test("an address change survives a gap with no internet")
    func addressChangeAcrossGap() async {
        // X → nil → Y is a change. The baseline must survive the nil rather
        // than being cleared by it, or the notification has no "from".
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap(nil, .off))
        #expect(await spy.changes.isEmpty)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes
                == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("coming back on the same address announces nothing")
    func sameAddressAcrossGap() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap(nil, .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a disabled toggle silences its own change only")
    func togglesGateIndependently() async {
        let spy = SpyNotifier()
        let model = self.model(vpn: false, ip: true, notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes
                == [.publicIPChanged(from: "203.0.113.41", to: "203.0.113.42")])
    }

    @Test("both toggles off means nothing is ever posted")
    func bothOff() async {
        let spy = SpyNotifier()
        let model = self.model(vpn: false, ip: false, notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.changes.isEmpty)
    }

    @Test("a named new address is named in the notification")
    func namedAddress() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        model.preferencesForTesting.labels = [
            AddressLabel(pattern: "203.0.113.42", name: "Home", scope: .publicAddress)
        ]
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.42", .off))
        #expect(await spy.posted.first?.name == "Home")
    }

    @Test("successive changes each get announced once")
    func successiveChanges() async {
        let spy = SpyNotifier()
        let model = self.model(notifier: spy)
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .full))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        await model.noteChangesForTesting(snapshot: snap("203.0.113.41", .off))
        // The baseline advances after posting, so a state that has already
        // been announced is not announced again on every later refresh.
        #expect(await spy.changes.count == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ConfirmationTests`
Expected: FAIL to compile — `NetworkModel` has no `notifier:` or `confirmationDelay:` parameter, no `noteChangesForTesting`, and no `preferencesForTesting`.

- [ ] **Step 3: Add the stored state and the seams**

In `Sources/IPBar/NetworkModel.swift`, add to the stored properties:

```swift
    private let notifier: Notifier
    private let confirmationDelay: Duration
    /// The state a pending change is measured against.
    ///
    /// Frozen while a confirmation window is open — advancing it mid-window
    /// would compare the change against itself and always come out silent.
    private var notificationBaseline: NetworkSnapshot?
    private var confirmationTask: Task<Void, Never>?
```

Change `init` to:

```swift
    init(preferences: Preferences,
         gateway: @escaping @Sendable ([NetworkInterface]) -> NetworkKey? = GatewayScanner.current,
         notifier: Notifier = SystemNotifier(),
         confirmationDelay: Duration = .seconds(10)) {
        self.preferences = preferences
        self.gateway = gateway
        self.notifier = notifier
        self.confirmationDelay = confirmationDelay
    }
```

Add the test seams beside `applyForTesting`:

```swift
    /// Drives change detection with a supplied snapshot, skipping the network.
    /// Used by tests only.
    func noteChangesForTesting(snapshot: NetworkSnapshot) async {
        await noteChanges(current: snapshot, rescan: false)
    }

    /// Used by tests only, to install labels the notification wording reads.
    var preferencesForTesting: Preferences { preferences }
```

- [ ] **Step 4: Write the baseline and confirmation logic**

Add to `NetworkModel`:

```swift
    /// Compares the current state with the baseline and, if anything is worth
    /// announcing, opens a confirmation window.
    ///
    /// One window covers every change, not one window per change: two facts do
    /// not justify two timers. A change arriving mid-window is confirmed by the
    /// existing deadline, so it gets less than the full delay — sooner than the
    /// first, never later.
    private func noteChanges(current: NetworkSnapshot, rescan: Bool) async {
        guard let baseline = notificationBaseline else {
            notificationBaseline = current
            return
        }

        // A window is already open; it will pick this state up when it closes.
        guard confirmationTask == nil else { return }

        let pending = enabled(ChangeDetector.changes(from: baseline, to: current))
        guard !pending.isEmpty else {
            advanceBaseline(to: current)
            return
        }

        guard confirmationDelay > .zero else {
            await confirm(rescan: rescan)
            return
        }

        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: self?.confirmationDelay ?? .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.confirm(rescan: rescan)
        }
    }

    /// Re-measures against the frozen baseline and posts whatever still holds.
    ///
    /// A VPN that dropped and came back re-evaluates as no change at all; one
    /// that dropped and half-recovered re-evaluates as the weakening it
    /// actually is, rather than the stale one first seen.
    private func confirm(rescan: Bool) async {
        defer { confirmationTask = nil }
        guard let baseline = notificationBaseline else { return }

        // Re-scan rather than trust state that may be ten seconds old. Both
        // calls are synchronous, cheap, and touch no network.
        let mode: VPNState.Mode
        if rescan {
            mode = VPNState.detect(interfaces: InterfaceScanner.scan()).mode
        } else {
            mode = vpn.mode
        }
        let current = NetworkSnapshot(publicIP: primaryPublic, vpn: mode)

        for change in enabled(ChangeDetector.changes(from: baseline, to: current)) {
            let name: String?
            if case .publicIPChanged(_, let to) = change {
                name = preferences.labels.name(for: to, scope: .publicAddress,
                                               networkKey: networkKey)
            } else {
                name = nil
            }
            await notifier.post(change, newAddressName: name)
        }

        advanceBaseline(to: current)
    }

    /// A nil address never becomes a baseline: losing the internet is not an
    /// address changing, and clearing it would lose the "from" that a later
    /// notification has to name.
    private func advanceBaseline(to current: NetworkSnapshot) {
        notificationBaseline = NetworkSnapshot(
            publicIP: current.publicIP ?? notificationBaseline?.publicIP,
            vpn: current.vpn)
    }

    /// Drops changes whose toggle is off. Applied when deciding to open a
    /// window and again when it closes, so a toggle switched off midway is
    /// honoured rather than racing the deadline.
    private func enabled(_ changes: [NetworkChange]) -> [NetworkChange] {
        changes.filter {
            switch $0 {
            case .vpnWeakened: return preferences.notifyOnVPNWeakened
            case .publicIPChanged: return preferences.notifyOnPublicIPChange
            }
        }
    }
```

- [ ] **Step 5: Call it from `refresh()`**

At the very end of `refresh()`, after the second `networkKey` assignment, add:

```swift
        await noteChanges(current: NetworkSnapshot(publicIP: primaryPublic, vpn: vpn.mode),
                          rescan: true)
```

- [ ] **Step 6: Run the tests**

Run: `swift build && swift test --filter ConfirmationTests`
Expected: 10 tests PASS.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: all PASS, and the run completes rather than aborting. Existing `NetworkModel(preferences:)` and `NetworkModel(preferences:gateway:)` call sites still compile because the two new parameters have defaults.

- [ ] **Step 8: Commit**

```bash
git add Sources/IPBar/NetworkModel.swift Tests/IPBarTests/ConfirmationTests.swift
git commit -m "feat(notify): confirm a change before announcing it"
```

---

### Task 5: Settings that cannot lie

**Files:**
- Modify: `Sources/IPBar/SettingsView.swift:15-38` (the `general` form)
- Test: manual — SwiftUI views have no test coverage in this repo.

**Interfaces:**
- Consumes: `Preferences.notifyOnVPNWeakened` / `.notifyOnPublicIPChange` from Task 3; `NotifierAuthorization` and `SystemNotifier` from Task 2.
- Produces: nothing consumed by later tasks.

The point of this task is decision 6: a toggle that is on while notifications are denied is the same lie as showing a local address as though the internet were fine.

- [ ] **Step 1: Add the state and the permission handling**

In `Sources/IPBar/SettingsView.swift`, add to `SettingsView`:

```swift
    @State private var authorization: NotifierAuthorization = .notDetermined
    private let notifier: Notifier = SystemNotifier()
```

Add the handler:

```swift
    /// Turning a toggle on is the only thing that ever asks for permission.
    ///
    /// A denial puts the toggle back rather than leaving it on and silent —
    /// a switch that claims to be doing something it cannot do is the same
    /// fault as a menu bar that shows a local address as though the internet
    /// were fine.
    private func requestPermissionIfNeeded(turnedOn: Bool,
                                           revert: @escaping @MainActor () -> Void) {
        guard turnedOn else { return }
        Task { @MainActor in
            let status = await notifier.authorizationStatus()
            guard status != .authorized else {
                authorization = status
                return
            }
            let granted = await notifier.requestAuthorization()
            authorization = await notifier.authorizationStatus()
            if !granted { revert() }
        }
    }
```

- [ ] **Step 2: Add the toggles and the denial message**

In the `general` form, after the `Picker("Refresh every", …)` block and before the existing `Divider()`, add:

```swift
            Divider()
            Toggle("Notify me when my VPN drops", isOn: $preferences.notifyOnVPNWeakened)
                .help("Also when a full tunnel degrades to a partial one, which leaves some traffic in the clear without disconnecting")
                .onChange(of: preferences.notifyOnVPNWeakened) { _, new in
                    requestPermissionIfNeeded(turnedOn: new) {
                        preferences.notifyOnVPNWeakened = false
                    }
                }
            Toggle("Notify me when my public IP changes", isOn: $preferences.notifyOnPublicIPChange)
                .onChange(of: preferences.notifyOnPublicIPChange) { _, new in
                    requestPermissionIfNeeded(turnedOn: new) {
                        preferences.notifyOnPublicIPChange = false
                    }
                }

            if authorization == .denied {
                HStack {
                    Text("Notifications are turned off for IPBar in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") {
                        guard let url = URL(string:
                            "x-apple.systempreferences:com.apple.preference.notifications")
                        else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
```

- [ ] **Step 3: Re-read the status whenever Settings opens**

Add to the `TabView` in `body`:

```swift
        .task {
            // Read on every open, so permission revoked in System Settings
            // since last time shows up here rather than leaving a toggle
            // quietly doing nothing.
            authorization = await notifier.authorizationStatus()
        }
```

Add `import AppKit` at the top of the file if it is not already present — `NSWorkspace` needs it.

- [ ] **Step 4: Build and check by eye**

Run: `swift build && make app && open dist/IPBar.app`

**Use `make app`, not `swift run`.** The bare binary has no bundle identifier, so `SystemNotifier` is inert there and no prompt can ever appear — you would be testing nothing.

Open Settings → General and confirm:

1. Two new toggles below a divider, both **off**.
2. Turning one on shows the system permission prompt (once — the first time only).
3. Allowing it leaves the toggle on.
4. Turning the other on shows **no** second prompt.
5. Deny it instead (or pre-deny IPBar in System Settings → Notifications) and confirm the toggle **springs back off** and the "turned off in System Settings" row with its **Open** button appears.
6. The **Open** button lands on the Notifications pane.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all PASS. No prompt appears during the test run.

- [ ] **Step 6: Commit**

```bash
git add Sources/IPBar/SettingsView.swift
git commit -m "feat(settings): ask for permission when a toggle goes on"
```

---

### Task 6: Telling `--diagnose`

**Files:**
- Modify: `Sources/IPBar/Diagnostics.swift` — after the `Network` line added by the previous feature

**Interfaces:**
- Consumes: `SystemNotifier`, `NotifierAuthorization` from Task 2; the two preferences from Task 3.
- Produces: nothing.

`--diagnose` is the first thing any bug report about a missing notification will need, and the only check `SystemNotifier` has.

- [ ] **Step 1: Print the authorization status and both toggles**

In `Sources/IPBar/Diagnostics.swift`, after the `Network` lines, add:

```swift
        let preferences = MainActor.assumeIsolated { Preferences() }
        let semaphore2 = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var authorization: NotifierAuthorization = .unavailable
        Task {
            authorization = await SystemNotifier().authorizationStatus()
            semaphore2.signal()
        }
        _ = semaphore2.wait(timeout: .now() + 5)

        print("Notifications      permission: \(authorization)")
        print("                   VPN weakened: \(preferences.notifyOnVPNWeakened)")
        print("                   IP changed:   \(preferences.notifyOnPublicIPChange)")
```

Make `NotifierAuthorization` printable by adding `: String` to its declaration in `Notifier.swift`:

```swift
enum NotifierAuthorization: String, Sendable {
```

The existing `Labels` section already builds its own `Preferences`; reuse the local `preferences` constant there rather than constructing a second one.

- [ ] **Step 2: Build and run it**

Run: `swift build && swift run IPBar --diagnose`

Expected: a `Notifications` block. Because `swift run` has no bundle, permission reads **unavailable** — that is correct and is itself the proof the guard works.

Then run it inside a bundle:

Run: `make app && ./dist/IPBar.app/Contents/MacOS/IPBar --diagnose`

Expected: permission reads `notDetermined`, `authorized` or `denied` rather than `unavailable`.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/IPBar/Diagnostics.swift Sources/IPBar/Notifier.swift
git commit -m "feat(diagnose): print notification permission and toggles"
```

---

### Task 7: Document it

**Files:**
- Modify: `README.md` — a new section after "How VPN detection works"; the Layout table
- Modify: `ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add the section**

In `README.md`, after the "How VPN detection works" section and before "When the internet can't be reached", insert:

```markdown
## Being told when something changes

Two things can interrupt you, and both are off until you turn them on in Settings. Turning
the first one on is the only time IPBar has ever asked you for anything.

**Your VPN stopped covering your traffic.** Not only when it disconnects. If you are on a
full tunnel with a mesh VPN also up and the full tunnel dies, IPBar still sees a tunnel and
still says "some traffic through a VPN" — while your general traffic has started leaving in
the clear. That is the most dangerous state it can observe, so it is the one worth saying
out loud. The rule is that the tunnel now covers less than it did:

| Announced | Silent |
| --- | --- |
| all traffic → none | none → any |
| all traffic → some | some → all |
| some traffic → none | no change |

Connecting a VPN is never announced. You did that.

**Your public IP changed.** Useful behind an allowlist, or with a dynamic-DNS record. If the
new address has a name, the notification uses it.

Losing the internet is not an address changing, so it is not announced — the struck-through
globe already says it. Coming back on a *different* address is, though, so leaving the house
and reconnecting elsewhere tells you.

### Why it waits ten seconds

VPN clients reconnect: on wake, on a network change, on a server hiccup. IPBar sees the
tunnel vanish and return within seconds, and announcing that blip would be crying wolf.
Three false alarms and you would turn the feature off, which is exactly when it stops
protecting you.

So a change is held for ten seconds and measured again before it is announced. A blip that
heals itself never reaches you. A tunnel that drops and half-recovers is announced as what it
actually is rather than what it first looked like.

### If you say no

Deny the permission and the toggle goes back off, and Settings says notifications are turned
off for IPBar with a button to open System Settings. It will not sit there switched on while
quietly doing nothing — that would be the same fault as a menu bar showing a local address as
though the internet were fine.

`IPBar --diagnose` prints the permission state and both toggles.
```

- [ ] **Step 2: Add the new files to the Layout table**

In `README.md`, in the Layout table, after the `VPNState.swift` row, add:

```markdown
| `NetworkChange.swift` | which transitions are worth announcing |
| `Notifier.swift` | notifications, behind a bundle-identifier guard |
```

- [ ] **Step 3: Tick the roadmap entry**

In `ROADMAP.md`, change the heading `## Next — say when something changes` to
`## Done — say when something changes`, and replace its body with:

```markdown
Shipped. Two toggles, both off until asked for, so the permission prompt only ever follows a
deliberate choice.

The VPN rule turned out to be "protection decreased" rather than "dropped": a full tunnel
degrading to a partial one leaves traffic in the clear without disconnecting, and a drop-only
rule would have stayed silent through it.

A change is held for ten seconds and re-measured before it is announced, because VPN clients
reconnect on wake and on every network change, and a feature that cries wolf gets switched
off.

Design decisions and the spike that settled the mechanics are in
[the design doc](docs/superpowers/specs/2026-09-13-change-notifications-design.md).
```

Then promote the following section from `## Then —` to `## Next —`, and the one after it from `## Later —` to `## Then —`.

- [ ] **Step 4: Check the documentation is true**

Run: `make app && ./dist/IPBar.app/Contents/MacOS/IPBar --diagnose`

Read the section you just wrote against what the binary prints and against the code in
`NetworkChange.swift`. Every claim about which transitions are announced must match
`ChangeDetector.changes(from:to:)` exactly.

- [ ] **Step 5: Commit**

```bash
git add README.md ROADMAP.md
git commit -m "docs: explain what gets announced"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Decision 1 — both notify, separate toggles, off by default | 3 (`defaultsOff`), 5 (the two toggles) |
| Decision 2 — "protection decreased", not "dropped" | 1 (`weakening`, `notWeakening`, `allPairsCovered`) |
| Decision 3 — confirmed before announced, baseline not the change | 4 (`blipHeals`, `partialRecovery`) |
| Decision 3 — one window, not one per change | 4 (`noteChanges` early-returns while a window is open) |
| Decision 4 — a nil address is not a change | 1 (`addressLost`, `firstAddress`), 4 (`addressChangeAcrossGap`, `sameAddressAcrossGap`) |
| Decision 4 — baseline must not be cleared at confirmation | 4 (`advanceBaseline`, proved by `addressChangeAcrossGap`) |
| Decision 5 — no persistence across launches | 4 — `notificationBaseline` is a plain stored property, never written to `UserDefaults`. No task adds persistence. |
| Decision 6 — a toggle must never lie | 5 (denial reverts, status re-read on open) |
| Spike — bundle guard is the only defence | 2 (`inertWithoutBundle`, `noBundleUnderTest`) |
| Spike — crash reachable from the test suite | 2 (the spy in Task 4 exists for this reason) |
| Architecture — `NetworkChange.swift` | 1 |
| Architecture — `Notifier.swift` | 2 |
| Architecture — `NetworkModel` baseline and confirmation | 4 |
| Wording table | 2 (`NotificationWordingTests`, all four rows) |
| No click action, sound or badge | 2 (`post` sets neither; comment records why) |
| Testing — injectable delay | 4 (`confirmationDelay: .zero`) |
| Testing — notifier spy | 4 (`SpyNotifier`) |
| Files table | all |
| Out of scope — no offline notification, no connect notification, no history | no task adds any |

No gaps.

**Placeholder scan:** no TBD, TODO, "handle edge cases", or "similar to Task N". Every code step carries its code.

**Type consistency:** `NetworkSnapshot(publicIP:vpn:)` is defined in Task 1 and constructed identically in Tasks 1 and 4. `NetworkChange` cases keep their labels throughout. `Notifier.post(_:newAddressName:)` is defined in Task 2, implemented by `SpyNotifier` in Task 4, and called in Task 4 — all three match. `NotifierAuthorization` gains `: String` in Task 6, which is additive and breaks nothing in Tasks 2 or 5. `VPNState.Mode.coverage` is defined in Task 1 and used only there.

**One thing to flag to the executor:** Task 4's `noteChanges` takes a `rescan` flag purely so the test seam can skip the live `InterfaceScanner.scan()`. Production always passes `true`; `noteChangesForTesting` always passes `false`. It is not dead code and must not be "simplified" away — without it, every confirmation test would read the developer's real VPN state.
