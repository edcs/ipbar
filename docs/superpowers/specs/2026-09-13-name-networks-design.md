# Name networks, not addresses

**Date:** 2026-09-13
**Status:** Approved, ready for an implementation plan
**Roadmap entry:** "Next — name networks, not addresses"

## The problem

The README opens with *"If you have a static IP"*, and `AddressLabel` can only match an
address or a CIDR block. If your ISP rotates your address, every name you set decays into a
lie: you are "Home" one week and bare digits the next, with a stale `/32` in Settings
matching nothing and no sign of why.

This widens what a label can match, so a name can attach to *the network you are on* rather
than to the number it happened to hand out.

It is the entry that changes who the app is for.

## What a network is

A network is identified by the **MAC address of its gateway** — the LAN-side interface of
the router you are attached to.

This was chosen over the alternatives:

| Candidate | Rejected because |
| --- | --- |
| SSID | Since macOS 14 `CWInterface.ssid` returns `nil` without Location Services authorisation. IPBar currently asks the user for nothing, and that is worth more than saving one typed name. |
| BSSID | Changes as you move between mesh satellites, so "Home" would stop matching in the back bedroom. |
| Local subnet (`192.168.1.0/24`) | Not distinctive. Half the cafés in the world are `192.168.1.0/24`. |
| Public address | The thing we are trying to stop depending on. |

A gateway MAC is stable across a mesh, distinctive between networks, needs no permission,
and is reachable from APIs the app already calls.

## Decisions

These were settled during design and are not open for reinterpretation during
implementation.

### 1. A network name replaces whichever address the menu bar would show

Not only the local one. The name describes *where you are*, so it stands in for the address
whether the menu bar is set to Public IP or Local IP.

The stated cost is accepted: with a network named, "Public IP" no longer always renders
something public. The name is what the user asked to see.

### 2. Most specific still wins

The existing rule is preserved, with the network key slotted into a defined rung:

| Wins over | Kind | Example |
| --- | --- | --- |
| everything | exact address | `203.0.113.42` |
| every block | **network key** | gateway `74:24:9f:ab:0e:ab` |
| narrower blocks only | block, by descending prefix length | `203.0.113.0/24`, then `/16` |

A network key matches every address on that LAN, so by address-space specificity it belongs
with the blocks — but it names one physical router, so it outranks them. An exact address is
a deliberate statement by the user and still beats it.

"Most specific prefix wins" stays true, and Settings keeps printing it.

### 3. Network labels are created in place, never hand-typed

A gateway MAC for a network you have never visited is not knowable, so the `+` button in
Settings cannot create one. A network label is only ever created while standing on the
network it names.

To keep such a label readable and verifiable, a **descriptor** is captured at naming time
and stored alongside the key:

```
key:        74:24:9f:ab:0e:ab
descriptor: "Wi-Fi · router 172.16.132.1"
```

Settings shows the descriptor. The raw MAC appears only in `--diagnose`.

The descriptor is a display artefact captured once. It is never used for matching and is
never refreshed — if you rename your router's IP scheme, the descriptor goes stale while the
key keeps working. This is the correct trade: the key must be stable, and the descriptor
only has to be recognisable.

### 4. The panel gains a context row, hidden until a network is named

Once a network has a name, that name sits at the top of the panel, above the Public section,
with its descriptor beside it. It reads as the panel's title, mirroring what the menu bar
shows, so a user seeing `Home` in the bar finds the word immediately rather than hunting for
its source.

Before any network is named, the row is not rendered at all. Someone who only ever wanted
their IP address never sees it.

### 5. Naming is reachable by hover and by right-click

Because the row is hidden until used, the action lives in two places — exactly mirroring how
naming an address already works (`MenuContent.swift:240` for the hover button, `:253` for
the context menu):

- **Primary:** hovering the **This Mac** section header reveals a `Name network` button.
- **Secondary:** right-clicking any local address row offers `Name This Network…`.

Making a network behave unlike an address here would be a difference no user could
articulate a reason for.

### 6. Network labels have no scope

`AddressLabel.Scope` (Anywhere / Public only / Local only) exists to say which address a name
describes. A network name describes neither — it describes the network — and decision 1
already settled that it applies regardless of what the menu bar is showing.

Settings renders the **Applies to** cell as `—`, not editable, for network rows.

## Verified findings

A throwaway spike on macOS 26.6.2 settled the three mechanical unknowns. All three are
confirmed facts, not assumptions.

### Gateway MAC is reachable without shelling out or asking permission

`sysctl` with `CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO` returns the ARP
table — the same call `arp -a` makes. On macOS 26.6.2 it returned 7,188 bytes and 38
resolved entries, and the gateway's entry was present.

Entries with `sdl_alen != 6` are incomplete and must be skipped; the spike confirmed these
are exactly the rows `arp -a` prints as `(incomplete)`. No fallback to `NET_RT_DUMP` is
needed.

### The default route is the wrong source, and fails hard under a VPN

The roadmap proposed reading `Router` from `State:/Network/Global/IPv4`. The spike proved
this breaks, reproduced with a real VPN connected:

```
BEFORE VPN   default route → en0    router 172.16.132.1   mac 74:24:9f:ab:0e:ab
AFTER  VPN   default route → utun6  router 10.8.0.2       mac ** NOT IN ARP TABLE **
             physical path → en0    router 172.16.132.1   mac 74:24:9f:ab:0e:ab   (unchanged)
```

A point-to-point tunnel has no link layer, so the tunnel's gateway has no ARP entry at all.
Reading the default route would return **nothing** the instant a VPN connects, and the
network name would silently disappear with no indication why.

It fails closed rather than wrong — the user loses the name rather than inheriting someone
else's — but it is broken either way, for a large share of the people IPBar already serves.

**The key must therefore come from the primary physical interface, never the default route.**
The physical path returned a byte-identical key before and after the VPN came up.

### Multiple physical interfaces need a deterministic tie-break

With both Wi-Fi and Ethernet up, two physical interfaces carry routers. `Setup:/Network/Global/IPv4`
exposes `ServiceOrder` — the user's own priority list from Network settings — which resolves
this without inventing a rule.

## Gateway discovery

A new `Gateway.swift` owns the whole mechanism and exposes one value.

```swift
/// Identifies the network this Mac is attached to, by the link-layer address
/// of its gateway.
struct NetworkKey: Hashable, Sendable {
    let gateway: String      // "74:24:9f:ab:0e:ab", lowercase, zero-padded
    let descriptor: String   // "Wi-Fi · router 172.16.132.1"
}
```

Resolution order:

1. Enumerate `State:/Network/Service/[^/]+/IPv4`, keeping entries that carry both
   `InterfaceName` and `Router`.
2. Discard any whose interface is not physical. Reuse the existing
   `NetworkInterface.Kind.isPhysical`, which already draws this line for the VPN inference.
3. If more than one survives, order by `ServiceOrder` from `Setup:/Network/Global/IPv4` and
   take the first.
4. Read the ARP table and look up that router's MAC. Skip entries with `sdl_alen != 6`.
5. Build the descriptor from the interface's `friendlyName` and the router's address.

Any step failing yields `nil`, which means no network match and no context row. Failure is
always silent and total — there is no partial or guessed key.

**Ordering within a refresh.** The ARP entry for the gateway exists once the Mac has spoken
to it. `NetworkModel.refresh()` already performs a public IP lookup that routes through the
gateway, so the key is read **after** that fetch completes. The spike found the entry
populated in normal operation, but the ordering makes it robust on a cold interface rather
than relying on it.

**Cost.** One `sysctl` pair and a handful of `SCDynamicStore` reads per refresh, on a model
that refreshes on path change, wake and a user-set timer. No polling is introduced.

## Data model

`AddressLabel` gains a key that can be one of two things. Because IPBar is not yet
distributed to anyone but its author, there are no stored labels in the wild and **no
migration path is required** — the honest representation is chosen over the compatible one.

```swift
struct AddressLabel: Codable, Identifiable, Hashable, Sendable {
    enum Key: Codable, Hashable, Sendable {
        case prefix(String)                              // address or CIDR text
        case network(gateway: String, descriptor: String)
    }

    var id = UUID()
    var key: Key
    var name: String
    var scope: Scope = .any    // ignored when key is .network — see decision 6
}
```

Swift synthesises `Codable` for enums with associated values, so this costs no hand-written
coding. It makes the illegal states unrepresentable: no network label without a gateway, no
address label carrying a stray descriptor.

**A gateway key is unique across the label list.** Naming a network that already has a name
updates that label rather than appending a second one, mirroring how `setName` already
refuses to let repeated renaming pile up dead entries for addresses. The existing array
extensions — `setName(_:for:scope:)`, `hasOwnLabel(for:scope:)` and `removeLabel(for:scope:)`
— currently identify a label by its `pattern` string and must be re-expressed in terms of
`Key` so they work for both cases.

`SettingsView` binds a `TextField` to the pattern text today. It gains a computed bridge:

```swift
/// Binding shim for the Settings table. Writes are ignored for network labels,
/// whose key is captured rather than typed.
var patternText: String {
    get { if case .prefix(let text) = key { return text }; return "" }
    set { if case .prefix = key { key = .prefix(newValue) } }
}
```

Network rows render the descriptor as static text rather than an editable field.

`isValid` becomes kind-aware. Today a `nil` prefix paints the row red; a network label has no
prefix and must not be flagged as broken.

## Matching and ranking

Matching becomes a pure function over `(labels, address, scope, networkKey)`, returning the
most specific name.

```swift
/// Specificity as a sortable tuple — the largest wins, so a /32 beats a /24.
/// Tier 2 exact address, tier 1 network key, tier 0 block. Returns nil when
/// the label does not match at all.
private func specificity(of label: AddressLabel,
                         matching address: String,
                         scope: AddressLabel.Scope,
                         networkKey: NetworkKey?) -> (tier: Int, length: Int)?
```

`name(for:scope:)` gains a `networkKey:` parameter and takes the maximum of the tuple. The
existing longest-prefix behaviour is unchanged for address labels — a network key simply
joins the comparison at its own rung.

### The `.both` display mode

`DisplaySource.both` renders `local · public`. With a network named, both halves resolve to
the same string and the menu bar would read `Home · Home`.

**Rule:** when both halves produce an identical string, show it once.

### Interaction with `NameDisplay`

No special cases. A network name behaves as any name does:

| Setting | Menu bar |
| --- | --- |
| Name | `Home` |
| Name and address | `Home (203.0.113.42)` |
| Address | `203.0.113.42` — names suppressed, network names included |

### The menu bar qualifier

`menuBarQualifier` does not change. It is driven by `displaySource` and the offline state,
not by the text being rendered, so a name replaces the *text* and leaves the flag, the LAN
glyph and the struck-through globe exactly as they are.

At home behind a German VPN the bar reads `🇩🇪 Home VPN`: you are at home, your traffic
leaves Germany, the VPN carries all of it. Every part is true.

With no internet but a named network, the bar reads `Home` with the struck-through globe —
which is more useful than the address it replaces, not less.

## The panel

### Context row

Rendered above the Public section, only when the current `NetworkKey` matches a stored
network label.

```
┌────────────────────────────────┐
│  Home        router 172.16.132.1│   ← name, with captured descriptor
│  PUBLIC                         │
│  203.0.113.42              GB   │
│  THIS MAC                       │
│  192.168.1.77            Wi-Fi  │
└────────────────────────────────┘
```

Right-clicking it offers `Rename…` and `Remove Name`, consistent with address rows.

### Naming flow

Both entry points open the same inline editor the panel already uses for addresses
(`MenuContent.swift:283` — Return saves, Escape cancels), pre-focused. On save, the current
`NetworkKey` is captured into a new label with its descriptor. The user never types or reads
a MAC address.

### When naming is unavailable

If no `NetworkKey` resolves — no network, or a cellular/tethered link with no ARP — the
hover button and the context menu item are **not shown**. An affordance that appears and
then fails is worse than one that is absent.

## Limitations, stated plainly

These are consequences of the design, to be documented in the README rather than worked
around.

- **Cellular and tethering.** A WWAN link is point-to-point with no ARP table, so there is
  no gateway MAC and network naming is unavailable. The affordance is hidden there.
- **A network you are not on cannot be named.** Consequence of decision 3.
- **A label whose network you never revisit never matches.** It stays visible in Settings
  with its descriptor, so it is findable and deletable. No stale-handling, no expiry, no
  greying out.
- **A spoofed or randomised gateway MAC breaks the key.** Rare, and out of scope.

## Testing

The current promise is 75 tests and `swift test` needing no network. That is preserved.

**Pure, no seam required:**

- Tier ordering: exact address beats network beats `/24` beats `/16`.
- A network label is ignored when no key is supplied.
- Scope filtering still applies to address labels and is ignored for network labels.
- `.both` collapses two identical names to one.
- Each `NameDisplay` case against a network name.
- `Codable` round-trip for both `Key` cases.

**Behind a seam:** gateway discovery is system state, so `NetworkModel` takes the lookup as
an injectable closure or protocol, defaulting to the real implementation. Tests supply a
fixed `NetworkKey`.

**Not unit-tested:** the `sysctl` ARP walk itself, which is pointer arithmetic over live
kernel state. It is covered by the spike, and `--diagnose` is the ongoing check.

## Files

| File | Change |
| --- | --- |
| `Gateway.swift` | **New.** `NetworkKey`, ARP walk, physical-router resolution, `ServiceOrder` tie-break. |
| `AddressLabel.swift` | `Key` enum, kind-aware `isValid`, `patternText` bridge, tiered ranking. |
| `NetworkModel.swift` | Hold the current `NetworkKey`, read it after the public IP fetch, thread it through `display`/`menuBarText`, collapse `.both` duplicates. |
| `MenuContent.swift` | Context row, hover button on the This Mac header, context menu item, naming flow, hide affordances when no key. |
| `SettingsView.swift` | Render network rows as static descriptors, `—` for Applies to, kind-aware validity. |
| `Diagnostics.swift` | Print physical interface, router address, gateway MAC, and whether a label matched. First thing any bug report needs. |
| `Tests/` | As above. |
| `README.md` | Naming section, and the limitations above. |
| `ROADMAP.md` | Tick the entry. |

## Out of scope

Named explicitly so they are not drifted into:

- IPv6 neighbour-discovery keys. The IPv4 gateway is sufficient; a network with no IPv4
  gateway is vanishingly rare and can be revisited if it ever shows up.
- Auto-suggesting a name on arriving at an unknown network.
- Syncing labels between Macs.
- Any change to VPN detection, flags, or the offline state beyond threading the key through.
