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

## Done — name networks, not addresses

Shipped. The key is the gateway MAC of the primary **physical** interface — never the
default route, which a full-tunnel VPN displaces onto a tunnel whose gateway has no ARP
entry at all. `ServiceOrder` breaks the tie when Wi-Fi and Ethernet are both up.

Design decisions and the spike that settled the mechanics are in
[the design doc](docs/superpowers/specs/2026-09-13-name-networks-design.md).

## Next — say when something changes

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

## Then — finish the reachability story

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
