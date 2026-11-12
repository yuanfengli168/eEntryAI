# eEntryAI
A simple AI agents help you fill in arrival card of Singapore, China, USA, etc.

## Prototype status (Nov 2026)

**Working:** Singapore Arrival Card auto-fill end-to-end on iOS simulator.
One profile → app opens `eservices.ica.gov.sg/arrivalcard` in an embedded browser →
JS injection fills all 25 fields across the 3-tab wizard (identity, trip, health,
transport, accommodation) → user reviews and taps Submit themselves.

- `doc/Architecture.md` — system design (layers, adapter packs, patterns)
- `doc/CountryPortalMap_11122026.md` — 6-country portal research + SG field schema
- `packs/sg/fields.json` — SG adapter pack v1 (field map; OTA-updatable design)
- `eEntryAI/` — SwiftUI app (Core / Adapters / Automation / UI layers)
- `project.yml` — xcodegen spec

Build: `xcodegen generate && xcodebuild -scheme eEntryAI -destination 'platform=iOS Simulator' build`

