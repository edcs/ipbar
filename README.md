# IPBar

A macOS menu bar app that shows your IP address, and lets you give addresses names.

If you have a static IP, `203.0.113.42` isn't information. It's a lookup you do in your
head every time. Tell IPBar it's called "Office" and the menu bar says `Office`.

- **Named addresses.** Map an address or CIDR block to a name. The most specific prefix
  wins, so a `/32` for your static IP beats the `/24` it sits in.
- **VPN state.** See whether your traffic is going through a tunnel, and whether that
  tunnel is full or split.
- Public IPv4 and IPv6, plus every local interface. Click any of them to copy.
- Updates when the network changes and when your Mac wakes. It doesn't poll.
- No dock icon. No analytics. No network calls except the public IP lookup.

## Install

```sh
brew install --cask edcs/tap/ipbar   # once published
```

Or build it yourself:

```sh
make run
```

## Naming an address

Go to Settings → **Names** and click `+`. The pattern field accepts:

| Pattern | Matches |
| --- | --- |
| `203.0.113.42` | exactly that address |
| `192.168.1.0/24` | the whole block |
| `2001:db8::/32` | IPv6 blocks work the same way |

Use **Applies to** if you want a label to fire only for your public address, or only for
local ones. When several labels match, the longest prefix wins. A `/32` always beats a
`/24`.

Want to see both? Turn off *Show name instead of address* in General and you'll get
`Office (203.0.113.42)`.

## How VPN detection works

macOS has no public API for "is a VPN up". `NEVPNManager` only reports configurations
your own app created. So IPBar works it out from the routing table instead.

1. Find tunnel interfaces (`utun*`, `ipsec*`, `ppp*`) that hold a **routable** address.
   macOS keeps several `utun` interfaces up permanently for Continuity and iCloud Private
   Relay, but those only ever carry link-local addresses. Requiring a routable one removes
   the false positives.
2. Check whether the default route points at one of them. If it does, all your traffic is
   going through the VPN (**full**). If a tunnel is up but doesn't hold the default route,
   only some of it is (**split**). Tailscale and similar mesh VPNs look like this.

This works for WireGuard, Tailscale, corporate IPSec and anything else that creates a real
tunnel interface. Nothing is special-cased.

To see everything the menu bar is derived from, run `IPBar --diagnose`. It's useful in bug
reports, and you can compare it against `scutil --nwi`.

## Development

```sh
make hooks           # enable the commit-message hook, once per clone
swift build          # compile
swift test           # 20 tests, no network needed
make app             # universal .app in dist/
make run             # build and launch
```

There's no `.xcodeproj`. SwiftPM builds the binary and the `Makefile` assembles the bundle
around it, so a clean checkout needs nothing but Xcode.

Commits follow [Conventional Commits](https://www.conventionalcommits.org). A shell hook
checks them locally and CI runs the same script. See [CONTRIBUTING.md](CONTRIBUTING.md).

### Layout

| File | Role |
| --- | --- |
| `IPPrefix.swift` | address/CIDR parsing and prefix matching |
| `AddressLabel.swift` | the name to address mapping, and how a match is chosen |
| `NetworkInterface.swift` | `getifaddrs` scan, decorated via SystemConfiguration |
| `VPNState.swift` | tunnel inference described above |
| `PublicIPService.swift` | family-pinned public IP lookup with fallbacks |
| `NetworkModel.swift` | observable state, refreshed by `NWPathMonitor` |
| `Diagnostics.swift` | `--diagnose` output |
| `Tools/GenerateIcon.swift` | draws the app icon |
| `Tools/setup-signing.sh` | one-time certificate and notarization setup |
| `Tools/check-commits.sh` | runs the commit-msg hook over a range, used by CI |
| `.githooks/commit-msg` | the Conventional Commits rule, shared by hook and CI |

## The icon

`Tools/GenerateIcon.swift` draws the icon with CoreGraphics and writes every size in the
iconset. `make icon` runs it and compiles the `.icns`. The rendered output is gitignored,
so the script stays the source of truth and icon changes show up as readable diffs instead
of binary blobs.

The mark is a globe seen from low orbit at sunrise, wrapped in a network mesh. The mesh is
a real geodesic rather than a decorative grid: points are spread over a sphere with a
Fibonacci lattice, projected orthographically, and only the front-facing ones are drawn, so
density falls away toward the limb the way it actually would. One node is amber instead of
cyan, which is your named address among all the others.

Below 128px the mesh and the sun's rays drop out, leaving the limb, the atmosphere and the
sunrise, which still read at 32px where fine linework would only turn to noise.

## Releasing

You need to sign and notarize the app. Without that, Gatekeeper blocks it for everyone but
you. You'll need an Apple Developer Program membership.

Start here:

```sh
./Tools/setup-signing.sh
```

It checks for a Developer ID Application certificate, stores notarization credentials in
your keychain, and can upload the six secrets the release workflow needs via `gh`. Run it
as often as you like. Every step detects what's already there.

Then release locally or through CI:

```sh
make release VERSION=0.1.0 SIGN_ID="Developer ID Application: … (TEAMID)"   # local
git tag v0.1.0 && git push --tags                                          # CI
```

Both produce a signed, notarized, stapled `IPBar-0.1.0.zip` and print its SHA-256 for the
Homebrew cask in `Casks/ipbar.rb`.

### Why not fastlane

`gym` builds through `xcodebuild` and needs an Xcode project, which this repo doesn't have.
`notarize` wraps `notarytool`, which the Makefile already calls. `match` solves certificate
sharing across a team. That's real value at team scale, but it means adding Ruby and a
second private repo to manage a single certificate you touch once every five years.
Everything that runs per release is already automated without it.

## Licence

MIT. © 2026 ECS Software Consulting Ltd.
