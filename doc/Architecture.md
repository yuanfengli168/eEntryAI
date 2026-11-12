# eEntryAI — System Architecture (v0 draft, 2026-11-12)

**Goal:** one identity profile → one-click arrival-card submission across countries, on-device AI, secrets never leave the iPhone.

This doc extends [UserActivityFlow1_11122026.drawio](UserActivityFlow1_11122026.drawio) (the UX spec — stays authoritative for user flow) with the system view that the drawio doesn't cover: storage, secrets, country extensibility, AI model management.

---

## 1. Layered architecture

```
┌────────────────────────────────────────────────────────────┐
│  UI Layer (SwiftUI)                                         │
│  ProfileEntry · CountryPicker · WebViewScreen · HistoryList │
│  OnboardingChat (AI asks for missing fields)                 │
├────────────────────────────────────────────────────────────┤
│  CountryAdapter layer  (protocol `CountryAdapter`)          │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │
│  │ SGAdapter    │ │ VNAdapter …  │ │ JPAdapter …      │   │
│  │ Pattern A    │ │ Pattern A    │ │ Pattern B (QR)   │   │
│  └──────────────┘ └──────────────┘ └──────────────────┘   │
│  Each adapter = code-free JSON pack + thin Swift glue      │
├────────────────────────────────────────────────────────────┤
│  AutomationEngine (shared, Pattern A)                       │
│  WKWebView orchestration · JS injection · DOM extraction    │
│  Field resolution · error detection · page-state detection │
├────────────────────────────────────────────────────────────┤
│  AIEngine (protocol, swappable)                             │
│  v0: HardcodedMapEngine (pack lookup only)                  │
│  v1: FoundationModelsEngine (Apple, guided generation)      │
│  v2: + DownloadableModelStore (MLX/Core ML CJK packs)       │
├────────────────────────────────────────────────────────────┤
│  Core domain (pure Swift, no UI deps)                       │
│  Profile (versioned Codable) · Trip · Submission · Result  │
├────────────────────────────────────────────────────────────┤
│  Storage layer (protocols — implementations swappable)      │
│  ProfileStore protocol:  v0 FileStore → v1 KeychainStore    │
│  HistoryStore protocol: v0 FileStore → v1 SwiftData/GRDB   │
│  SecretsStore:           v0 none → v1 Keychain+SecureEnv    │
│  AdapterPackStore:       bundle + OTA cache (versioned)     │
└────────────────────────────────────────────────────────────┘
```

**Dependency rule:** arrows point downward only. UI never touches WKWebView JS directly; CountryAdapters never touch storage internals. Any layer is replaceable without touching the ones above.

## 2. The two schemas (different owners, different strategies)

### 2.1 Identity Profile — WE own it (evolve slowly, migrate)

```swift
struct Profile: Codable {
    var schemaVersion: Int = 1        // bump on any breaking change
    // identity
    var fullNameInPassport: String
    var passportNumber: String
    var passportExpiry: String        // ISO-8601 "2030-12-12"
    var sexInPassport: Sex            // .female/.male/.others
    var dateOfBirth: String?          // ISO-8601; nil = day/month unknown
    var nationality: String           // "CHINESE" (portal-normalized names)
    var countryOfBirth: String        // "HONG KONG SAR"
    var placeOfResidence: String      // "HONG KONG SAR"
    var email: String
    var phoneCountryCode: String      // "852"
    var mobileNumber: String
    // trip (per-trip, not per-profile — stored separately, prefilled)
    var defaults: TripDefaults?       // purpose, accommodation, etc.
}

enum ProfileDecoder {
    /// Decode with migration chain: v1 → v2 → …
    static func decode(from data: Data) throws -> Profile
}
```

Evolution rules (critical):
1. **Additive only**: new fields must have defaults (`var x: String? = nil`).
2. **Deprecate, never delete**: renamed fields keep the old one decoded-then-migrated.
3. **`schemaVersion` bump** on breaking change; `ProfileDecoder` owns the migration chain.
4. Optional fields never silently fail the whole decode — decode is tolerant at field level.

### 2.2 Portal Field Maps — ICA/other govts own them (churn fast, ship OTA)

**Never Swift structs.** Versioned JSON **adapter packs** per country:

```
Packs/
├── sg/
│   ├── pack.json          # metadata: packVersion, minAppVersion, pattern
│   ├── fields.json        # field → selector/strategy map
│   ├── options/           # reference data snapshots (airlines, hotels, …)
│   │   ├── airlines.json
│   │   └── hotels.json
│   └── flow.json          # page/tab order, conditional rules, validation hints
└── au/ (future)
```

`fields.json` concept (SG example):

```json
{
  "packVersion": 3,
  "countryCode": "SG",
  "portalUrl": "https://eservices.ica.gov.sg/arrivalcard/sgac/fvipa/submit",
  "pattern": "AUTOFILL_SUBMIT",
  "fields": [
    {
      "profileKey": "fullNameInPassport",
      "label": "Full Name (In Passport)",
      "strategy": "TEXTBOX_BY_LABEL",
      "selector": "placeholder='Given name followed by Surname'",
      "required": true
    },
    {
      "profileKey": "nationality",
      "label": "Nationality/Citizenship",
      "strategy": "SEARCH_COMBO",
      "search": "type-to-filter, pick first exact option match",
      "required": true
    },
    {
      "key": "arrivalDate",
      "strategy": "RADIO",
      "optionsFrom": "DYNAMIC_LIST",   // 3 dates computed at runtime
      "valueFrom": "trip.arrivalDate",
      "required": true
    },
    {
      "key": "modeOfTransport",
      "strategy": "RADIO",
      "options": ["COMMERCIAL FLIGHT", "PRIVATE/CARGO AIRLINE/OTHERS"],
      "visibleWhen": { "field": "modeOfTravel", "equals": "AIR" },
      "valueFrom": "trip.transportMode"
    }
  ],
  "conditionals": [
    { "when": "trip.accommodationType == HOTEL", "then": ["nameOfHotel"], "else": [] }
  ],
  "reviewDetection": { "text": "Please review your details carefully" },
  "submit": { "strategy": "CHECKBOX_THEN_BUTTON", "requiresUserTap": true }
}
```

Pack lifecycle:
- **Bundled copy** = fallback truth; app always works offline.
- **OTA updates**: fetch newest `pack.json` from our server; verify signature + `packVersion` monotonic; cache in `AdapterPackStore`. Corrupt/unsigned/older → use bundled.
- `minAppVersion` in metadata lets a new pack refuse to load on old apps (graceful degradation instead of breakage).
- When ICA renames a label tomorrow: server-side JSON edit → app hot-fix, **no App Store review**.

### 2.3 AI fallback role (the "decoupled AI" insight)

`HardcodedMapEngine` resolves ~95% of fields via pack JSON. `AIEngine` is consulted **only** for:
- fields the pack doesn't know (new/renamed — resilience between OTA pack updates),
- fuzzy option matching in comboboxes,
- conversational onboarding ("what's your passport number?").

This means AI is a **degradation path, not a dependency** — the app works fully without it, gets smarter when present. v0 ships no model at all.

## 3. Pattern catalogue (one AutomationEngine, three country patterns)

| Pattern | Countries | Mechanism | Adapter responsibility |
|---|---|---|---|
| **A — AUTOFILL_SUBMIT** | SG, VN, AU(DPD), ESTA | WKWebView + JS injection + user-taps-submit | Provide field map + review/submit markers |
| **B — PREPARE_QR** | CN, JP | Fill form → generate QR → save to Photos/Wallet | Provide field map + QR extraction |
| **C — ASSIST_ONLY** | US arrival step | Show checklist, deep-link to official app/site | Provide deep links + checklist content |

The AutomationEngine (WKWebView orchestration) is written **once, generically**, driven entirely by pack JSON. Adding country #2 in Pattern A = writing a new JSON pack + a smoke test. No engine changes.

## 4. Secrets & storage roadmap (design now, implement later)

- **ProfileStore protocol** already isolates persistence. v0: `FileStore` (JSON in app sandbox). v1: `KeychainStore` — values in Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), index in SwiftData. v2: biometric gate (LAContext) on app launch.
- **SecretsStore** (v1): AU DPD credentials, future Visa/passport scans — Keychain only, never in `UserDefaults`, never in files, never in analytics.
- **Threat model v1** (when we get to it): sandboxed app → protect against backup exfiltration, device stolen unlocked, malicious profile sync. Secure Enclave key wrapping when we add backups.
- Design decision recorded: **no cloud sync v0/v1.** On-device only. If user wants multi-device later, that's an explicit v2 feature with E2E encryption.

## 5. Roadmap alignment (todo list)

| Phase | Todo | Layer touched |
|---|---|---|
| 0 ✅ | sg-arrival-card research | none (doc) |
| 1 | profile-schema + adapter pack format (this doc) | Core + Packs |
| 2 | architecture-doc (this) → scaffold-ios-app | UI |
| 3 | sg-webview-autofill v0 (HardcodedMapEngine) | Automation + Packs |
| 4 | history-storage | Storage |
| 5 | ai-field-matching | AIEngine |
| 6 | profile-security-design | Storage/Secrets |
| 7+ | vn/cn/us/au/jp research → packs | CountryAdapter |

**Open questions to decide while scaffolding:**
1. `TripDefaults` vs per-trip entry UX — how much to prefill vs ask each time?
2. Group submission ("Add Traveller") — v0 single traveler, schema ready for `[Traveler]`?
3. History: SwiftData now vs FileStore now + SwiftData later (recommend: file JSON now, migrate later — matches "protocol-first" rule).
