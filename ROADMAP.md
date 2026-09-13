# Roadmap

What IPBar might do next, and what it will not do.

Nothing here is a promise. It's a record of which ideas have survived thinking about,
written down so the reasoning doesn't have to be reconstructed each time.

Every entry has to pass the same test the app already applies to itself:

- **Does it say something true?** Not decorative, not approximate. The struck-through globe
  exists because falling back to a local address quietly was a lie.
- **Does it avoid repeating macOS?** The LAN glyph isn't the Wi-Fi symbol because the menu
  bar already has one of those.
- **Does it cost a permission, a dependency, or a third party?** Each of those is spent
  once and never refunded. The README's claim — no analytics, no network calls except the
  public IP lookup — is a feature, and features can be spent.
- **Does it stay event-driven?** IPBar reacts to path changes and wake. Anything that needs
  a poll loop needs a very good reason.

## Where it is now

v0.1.0 does the thing it set out to do. Named addresses, VPN state, public and local
addresses, country flag, an honest offline state, and a signed and notarised release
through a Homebrew tap. Around 2,200 lines and 75 tests.

The gaps below are not bugs. They're the next honest things to say.

---

## Next — name networks, not addresses

**The README's first sentence excludes most of its readers.** It opens with *"If you have a
static IP"*, and `AddressLabel` can only match on an address or a CIDR block. If your ISP
rotates your address, every name you set decays into a lie: you are "Home" one week and
bare digits the next, with a stale `/32` in Settings quietly matching nothing.

The fix is to widen what a label can match. Today `AddressLabel.pattern` is parsed by
`IPPrefix`; the type needs a second kind of key so a name can attach to *the network* rather
than to the number it happened to hand out.

The candidate key is the **default gateway's MAC address**. It is stable per network, it
distinguishes your home router from a café's, and — the part that matters —
`SCDynamicStoreCopyValue` on `State:/Network/Global/IPv4` is a call `InterfaceScanner`
already makes, and the dictionary it returns carries `Router` alongside the
`PrimaryInterface` we read today. From that address the link layer table gives the MAC. No
new framework, no new permission, no new third party.

**SSID is the obvious alternative and should be rejected.** It reads better in Settings, but
since macOS 14 `CWInterface.ssid` returns `nil` unless the app holds Location Services
authorisation. An app that advertises no analytics asking for your location, to save typing
a name once, is a bad trade. Gateway MAC gets most of the value at none of the cost.

Open design questions:

- How does a gateway-matched name interact with the longest-prefix rule? A network key has
  no prefix length. Probably it sits above every CIDR match, since it is more specific than
  any of them, but that needs stating rather than assuming.
- The Settings table has one **Address or CIDR** column. Does it gain a kind column, or does
  the pattern field learn a second syntax?
- Naming from the panel is the good path — you never read an address off screen and type it
  back. What does "name this network" look like as a row?

This is the entry that changes who the app is for. Everything below is smaller.

## Then — say when something changes

`NetworkModel` computes three facts and throws two of them away on every refresh. It knows
the previous `publicIPv4`, and it overwrites it. It knows the previous `VPNState`, and it
replaces it. The changes are the interesting part.

**Your public IP changed.** Matters to anyone sitting behind an allowlist, running something
at home, or maintaining a dynamic-DNS record. A transition from one address to another is a
real event and currently passes in silence.

**Your VPN dropped.** `VPNState` already distinguishes `full`, `split` and `off`. A
`full → off` transition is the highest-stakes fact this app computes, and right now the only
way to learn it is to look at the menu bar at the right moment. This is the entry with the
worst consequence for going unsaid.

Both want the same mechanism, and the mechanism has a cost: `UNUserNotificationCenter`
prompts for permission, and IPBar currently asks for nothing at all. Ways to spend less:

- Notifications off by default, with a Settings toggle that triggers the prompt when you
  turn it on. Nobody who doesn't want this is ever asked.
- Or no notifications at all — mark the change in the panel instead ("changed from
  `203.0.113.41` 4m ago"). Cheaper, honest, but only seen if you open the panel, which
  defeats the point for the VPN case.

The VPN case probably justifies the prompt. The IP-change case probably doesn't on its own.

## After that — finish the reachability story

Three small things, each completing a sentence the app already starts.

**The captive portal button.** The panel says the cause is *"a sign-in page nobody has been
shown yet"* — and then leaves you to go and find it. Opening `http://captive.apple.com` in
the default browser lands on the portal, because that is the probe macOS itself uses. One
button, no new detection, and it turns a diagnosis into a fix.

**Gateway and DNS in the panel.** Two things people look up constantly, and both fall out of
`SCDynamicStore`: `Router` from the global IPv4 dictionary we already read, DNS from the
service's `DNS` dictionary. An app about which addresses you have should probably know which
one you talk *through*.

**Naming local addresses from the panel.** The deferral at `MenuContent.swift:177`. Without
NAT an IPv6 address is the same string in both sections, so naming it in each would give one
address two names. `RowKey` is already scoped, so the remaining work is deciding what the
panel shows, not how it stores it.

## Later — reach and polish

| | |
| --- | --- |
| **Shortcuts / App Intents** | "Get my public IP" in Shortcuts and Spotlight. An `AppIntent` plus an `AppShortcutsProvider`, and `--diagnose` stops being the only way in from outside. |
| **Address history** | Local, clearable, never leaves the Mac — anything else contradicts the whole app. Answers "what was I on yesterday". |
| **Menu bar width cap** | A full IPv6 address is 39 characters and eats the bar. Truncation needs to pick a *correct* half to keep, which is the actual design work. |
| **Sparkle** | `brew upgrade` is currently the only update path; anyone who unzips a release manually never hears about another one. But Sparkle is a dependency *and* a recurring network call, so the README's claim would have to change. Worth it only if distribution moves beyond the tap. |
| **Localisation** | The strings are opinionated English prose. Translating them well is harder than translating labels, and doing it badly would cost more than it gains. |

## Not doing

- **Speed tests, latency graphs, ping indicators.** All need a poll loop, and all measure
  something IPBar is not about.
- **Port scanning.** A different app with a different threat model.
- **A map, or anything geographic beyond the flag.** The flag is free — it comes from a
  response already being fetched. A map would need real geolocation, a second third party,
  and would imply a precision that IP geolocation does not have.
- **ASN and ISP name.** Genuinely useful, and genuinely unavailable from the Cloudflare
  response already in flight. Adding a provider to get it would cost the README's best line.
- **Analytics, crash reporting, telemetry.** No.

---

## Open questions

- **Who is this for?** The static-IP framing was a real answer to a real annoyance. "Name
  networks" widens it a lot. Is that the goal, or does it dilute a sharp thing?
- **What earns a notification?** The app currently interrupts you never, which is a position
  worth defending. VPN drop is the strongest candidate for the first exception.
- **How much belongs in the panel?** It reads well because it is short. Gateway, DNS,
  history and change markers each make it longer.
