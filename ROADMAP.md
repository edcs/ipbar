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
through a Homebrew tap. Small enough to read in a sitting, and covered by tests that
need no network.

The gaps below are not bugs. They're the next honest things to say.

---

## Done — name networks, not addresses

Shipped. The key is the gateway MAC of the primary **physical** interface — never the
default route, which a full-tunnel VPN displaces onto a tunnel whose gateway has no ARP
entry at all. `ServiceOrder` breaks the tie when Wi-Fi and Ethernet are both up.

Design decisions and the spike that settled the mechanics are in
[the design doc](docs/superpowers/specs/2026-09-13-name-networks-design.md).

## Done — say when something changes

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

## Done — finish the reachability story

Shipped. The panel offers to open a captive portal's sign-in page rather than only naming it
as the likely cause, and a **This Network** section carries the router and every resolver.

The router and DNS deliberately come from different places: the router from the primary
physical interface, because under a VPN the default route points at a useless point-to-point
address, and DNS from whatever macOS is actually consulting, which under a VPN is the VPN's.

Naming local addresses from the panel turned out to need no design at all. The deferral
guarded against one IPv6 taking two names in two sections, and 663c778 had already stopped
an address appearing in both.

## Next — reach and polish

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
