# Say when something changes

**Date:** 2026-09-13
**Status:** Approved, ready for an implementation plan
**Roadmap entry:** "Next — say when something changes"

## The problem

`NetworkModel` computes three facts on every refresh and throws two of them away. It knows
the previous `publicIPv4` and overwrites it. It knows the previous `VPNState` and replaces
it. The changes are the interesting part, and both currently pass in silence.

Two changes are worth saying out loud:

- **Your public IP changed.** Matters to anyone behind an allowlist, running something at
  home, or maintaining a dynamic-DNS record.
- **Your VPN stopped covering your traffic.** The highest-stakes fact this app computes, and
  today the only way to learn it is to look at the menu bar at the right moment.

## Decisions

Settled during design. Not open for reinterpretation during implementation.

### 1. Both notify, under separate toggles, off by default

Two Settings toggles — one per change — both off. The first one enabled triggers the single
system permission prompt; the second costs nothing more.

The roadmap weighed whether the IP change justified the prompt on its own. It does not have
to: the permission is paid once, so once the VPN toggle has bought it, the marginal cost of
the IP change is zero. Separate toggles because the two facts have genuinely different
audiences — a safety warning and an informational one.

Off by default means nobody who does not want this is ever asked for anything, which
preserves the README's claim that IPBar asks you for nothing.

### 2. The VPN rule is "protection decreased", not "dropped"

| Fires | Silent |
| --- | --- |
| `full → off` | `off → full` |
| `full → split` | `off → split` |
| `split → off` | `split → full` |

The rule is that the tunnel now covers less than it did.

`full → split` is the case that motivates the rule and the one a naive implementation misses.
You are on a full tunnel with a mesh VPN also up; the full tunnel dies; `VPNState` becomes
`.split`. Your general traffic has just started leaving in the clear, while the panel still
reads "some traffic through a VPN" and a drop-only rule stays silent. That is the most
dangerous state this app can observe, so it is the one that must speak.

Connecting a VPN is never announced. You did that; you know.

### 3. A change is confirmed before it is announced

On spotting a degrade, hold it for **10 seconds**, re-check, and notify only if it is still
degraded.

VPN clients reconnect — on wake, on network change, on server hiccup — and `NWPathMonitor`
fires on each, so IPBar sees `full → off → full` within seconds. Announcing that blip cries
wolf. Three false alarms and the user switches the feature off, which is precisely when it
stops protecting them, so a false alarm costs more than ten seconds of delay.

**The pending item holds the baseline — the state before the change — not the change
itself.** At confirmation, the change is recomputed from baseline to current. This falls out
correctly for the awkward cases:

- `full → off → full` re-evaluates as `full → full`, which is not a degrade. Silent.
- `full → off → split` re-evaluates as `full → split`, and notifies with the *current* fact
  rather than the stale one.

At confirmation the local state is re-scanned (`InterfaceScanner.scan` then
`VPNState.detect`) rather than trusting model state that may be ten seconds old. Both are
synchronous and cheap, and neither touches the network.

**There is one confirmation window, not one per change.** It opens when the first
unconfirmed change appears and covers whatever else arrives before it closes. A change
spotted halfway through therefore gets less than the full ten seconds. This is a deliberate
simplification: two facts do not justify two timers, and the cost is that a second change is
confirmed slightly sooner than the first, never later.

When the window closes, every change from baseline to current is posted and the baseline is
reset to current.

### 4. A `nil` public address is not a change

Losing the internet is not an IP change — the struck-through globe already says it. So a
`nil` reading never becomes a baseline and never fires anything.

| Sequence | Result |
| --- | --- |
| `X → Y` | notify |
| `X → nil → Y` | notify — you went away and came back on a different address |
| `X → nil → X` | silent |
| first reading of all | silent |

The baseline survives the `nil` gap rather than being cleared by it, which is what makes the
second row work.

This also settles what happens when a confirmation window closes on a `nil`. Recomputing
baseline `X` against current `nil` yields no change, so nothing is posted — and because a
`nil` never becomes a baseline, the baseline stays `X` rather than resetting. A later `Y` is
then correctly spotted as `X → Y`. **The baseline must not be cleared or reset to `nil` at
confirmation**; doing so would lose the address that the eventual notification has to name.

### 5. The baseline does not persist across launches

IPBar notifies about changes observed *while running*. Quitting and relaunching a week later
does not announce that your address differs from last Tuesday.

Persisting would let a dynamic-DNS user learn about a change that happened while the app was
closed, but the claim is much weaker — "this differs from whenever you last ran me" is not
the same statement as "this just changed", and the notification would be phrased as the
latter. Saying something true is worth more here than saying something more often.

### 6. A toggle must never lie about whether it works

Enable a toggle, deny the system prompt, and a naive implementation leaves the toggle **on**
while nothing ever fires. That is the same failure this app already has an entire feature
about: falling back to a local address and looking like a working connection when the
internet is gone.

So:

- Denial **reverts the toggle** and Settings says permission is needed, with a button opening
  System Settings.
- Settings re-reads the authorization status each time it opens, so permission revoked later
  in System Settings surfaces as the same message rather than as a toggle that silently does
  nothing.

## Verified findings

A throwaway spike on macOS 26.6.2 settled the mechanics. All three are confirmed facts.

### `UNUserNotificationCenter` cannot be called without a bundle

| Context | `Bundle.main.bundleIdentifier` | `UNUserNotificationCenter.current()` |
| --- | --- | --- |
| Bare binary (`swift run IPBar`) | `nil` | **crashes** — SIGABRT, exit 134 |
| Unsigned `.app` (`make app`) | set | works, status `notDetermined` |
| Under `swift test` | `nil` | would crash |

The failure is **not** graceful and **cannot be caught**. `current()` raises
`NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil"), an Objective-C
exception with no Swift `catch`. There is no defensive wrapper; the only defence is not
making the call.

**Therefore `Bundle.main.bundleIdentifier != nil` is not a nicety — it is the entire safety
mechanism**, and every path reaching the notification centre must sit behind it. Without a
bundle the notifier no-ops silently, so a mistake degrades to silence rather than aborting
the process.

### Signing is not required, only a bundle

An unsigned `.app` worked. `make app` is sufficient to exercise this feature by hand; a
notarised build is not needed to develop or test it.

### The crash is reachable from the test suite

`swift test` runs with a `nil` bundle identifier. This makes the injected notifier protocol a
**hard requirement** rather than a testability preference: a test that forgot the spy would
not prompt the user, it would abort the run.

## Architecture

The repo already separates pure decision logic from the system layer — `GatewaySelection`
(pure, exhaustively tested) beside `GatewayScanner` (system, verified by `--diagnose`). This
follows that shape.

### `NetworkChange.swift` — pure, no system calls

```swift
/// The facts a notification can be derived from, captured at one moment.
struct NetworkSnapshot: Hashable, Sendable {
    let publicIP: String?
    let vpn: VPNState.Mode
}

enum NetworkChange: Hashable, Sendable {
    case vpnWeakened(from: VPNState.Mode, to: VPNState.Mode)
    case publicIPChanged(from: String, to: String)
}

enum ChangeDetector {
    /// Changes worth announcing, going from `baseline` to `current`.
    ///
    /// Returns an empty array for everything else, including a VPN that
    /// strengthened, a public address that went away, and a first observation
    /// with no baseline to compare against.
    static func changes(from baseline: NetworkSnapshot,
                        to current: NetworkSnapshot) -> [NetworkChange]
}
```

`VPNState.Mode` gains an explicit coverage ordering so "covers less than it did" is expressed
once: `off` < `split` < `full`, and a weakening is any move down that scale. This ordering is
written out deliberately — the enum currently declares its cases as `off, full, split`, so
declaration order means the opposite of coverage order and must never be relied on.

`Mode` also gains `CaseIterable`, so the test covering all nine mode pairs enumerates them
rather than hand-listing a set that could drift if a fourth mode were ever added.

### `Notifier.swift` — the system layer, behind a protocol

```swift
protocol Notifier: Sendable {
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> NotifierAuthorization
    func post(_ change: NetworkChange, naming: @Sendable (String) -> String?) async
}
```

`naming` lets the IP notification use a name when the new address has one, without
`Notifier` depending on `Preferences`.

The real implementation, `SystemNotifier`, checks `Bundle.main.bundleIdentifier != nil` before
touching `UNUserNotificationCenter` and no-ops when it is absent. Tests inject a spy.

### `NetworkModel` — baseline and confirmation

Holds `notificationBaseline: NetworkSnapshot?` and a single `confirmationTask`. After each
refresh it compares the current snapshot with the baseline; a change starts or continues the
confirmation window, and the window's expiry re-scans and decides.

The confirmation delay is injectable so tests run at zero rather than waiting ten seconds.

## Wording

Because `full → split` notifies, "dropped" is not always the right word.

| Transition | Title | Body |
| --- | --- | --- |
| `full → off` | VPN disconnected | All traffic is now in the clear |
| `full → split` | VPN no longer carrying all traffic | Some traffic is now in the clear |
| `split → off` | VPN disconnected | No tunnel is up |
| IP changed | Public IP changed | `203.0.113.41` → `Home (203.0.113.42)` |

The IP body uses the name when the new address has one, which is where this feature meets the
one shipped in `9497665`. With no name it is the bare address.

Notifications carry no click action. There is nothing useful to open — `MenuBarExtra` cannot
be opened programmatically, and Settings is not where you would want to land.

## Testing

`swift test` continues to need no network, and now also no notification permission.

**Pure, no seam required:**

- All nine `VPNState.Mode` pairs against the "protection decreased" rule.
- Each row of the `nil`-handling table in decision 4.
- A first observation with no baseline yields nothing.
- Confirmation recomputes from the baseline: `full → off → full` is silent,
  `full → off → split` notifies as `full → split`.

**Behind seams:** the notifier protocol with a spy recording posts; the confirmation delay
injected at zero.

**Not unit-tested:** `SystemNotifier` itself, which needs a bundle the test runner does not
have. `--diagnose` prints the authorization status as its check.

## Files

| File | Change |
| --- | --- |
| `NetworkChange.swift` | **New.** `NetworkSnapshot`, `NetworkChange`, `ChangeDetector`, mode ordering. |
| `Notifier.swift` | **New.** Protocol, `SystemNotifier` with the bundle guard, authorization handling. |
| `NetworkModel.swift` | Baseline, confirmation task, notifier call after each refresh. |
| `Preferences.swift` | `notifyOnVPNWeakened`, `notifyOnPublicIPChange`, both defaulting false. |
| `SettingsView.swift` | Two toggles, permission prompt on first enable, denial message with a System Settings button, status re-read on open. |
| `Diagnostics.swift` | Print authorization status and both toggle states. |
| `Tests/` | As above. |
| `README.md` | A section on what gets announced and what does not, including the `full → split` rule. |
| `ROADMAP.md` | Tick the entry, promote the next. |

## Out of scope

- Notifying that the internet went away. The struck-through globe already says it, and a
  notification per tunnel-in-a-lift would be intolerable.
- Notifying on VPN *connect*, or on a network name being recognised.
- A history of past changes. That is a separate roadmap entry.
- Any notification action, sound, or badge.
- Persisting anything about notifications across launches.
