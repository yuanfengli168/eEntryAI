# eEntryAI
A simple AI agents help you fill in arrival card of Singapore, China, USA, etc.

## Prototype status (Nov 2026)

**Working:** Singapore Arrival Card auto-fill end-to-end on iOS simulator.
One profile → pre-flight gap check → app opens `eservices.ica.gov.sg/arrivalcard`
in an embedded browser → JS injection fills all 25 fields across the 3-tab wizard
(identity, trip, health, transport, accommodation) → user reviews and taps Submit themselves.

Reliability loop (P0/P1/P2) shipped:
- **P0 pre-flight**: pack required fields diffed against saved data; native sheet
  collects gaps (pickers, 3-day-window date pickers) before the portal opens
- **P1/P2 needs-you handoff**: a failed required field stops the flow BEFORE
  clicking Next (never fights Angular validation); amber status lists the failed
  fields; user fixes them on the portal, taps the portal's Next, taps Resume —
  filling continues from the next page to the review screen

- `doc/Architecture.md` — system design (layers, adapter packs, patterns)
- `doc/CountryPortalMap_11122026.md` — 6-country portal research + SG field schema
- `doc/Malaysia.md` — MDAC design (family-of-5 batch, CAPTCHA handoff, phased plan)
- `doc/Vault.md` — Secret Vault design (document cards, MRZ scan, Face ID, auto-lock)
- `packs/sg/fields.json` — SG adapter pack v1 (field map; OTA-updatable design)
- `eEntryAI/` — SwiftUI app (Core / Adapters / Automation / UI layers)
- `project.yml` — xcodegen spec

Build: `xcodegen generate && xcodebuild -scheme eEntryAI -destination 'platform=iOS Simulator' build`

