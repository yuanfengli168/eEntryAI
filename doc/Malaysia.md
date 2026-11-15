# Malaysia (MDAC) — Design Doc

**Status:** draft for discussion (2026-11-13). SG prototype works; do not implement until SG is closed out.

**Scenario driving this design:** a family of 5, same commute (same flight), same hotel, arriving Dec 17, returning to SG Dec 19 — five MDAC submissions sharing one trip, differing only in personal identity.

---

## 1. Portal facts (verified live 2026-11-13)

| Item | Detail |
|---|---|
| Portal | `https://imigresen-online.imi.gov.my/mdac/main?registerMain` (Malaysia Digital Arrival Card, MDAC) |
| Tech stack | **jQuery + Bootstrap, plain HTML form** — NOT Angular. Every field has a stable `id`. Far simpler than ICA. |
| Account | None. Per-traveler submission. |
| Window | Submit within **3 days including the date of submission** before arrival |
| Cost | Free |
| Group support | **None.** One traveler per submission — 5 people = 5 separate registrations |
| CAPTCHA | **"Slide the Puzzle" slider verification** — `Submit` stays `disabled` until the slider succeeds (`onSuccess` → `$('#submit').attr("disabled", false)`) |
| Per-traveler result | Registration confirmation (checkable via `register?viewRegistration`; there is also E-gate eligibility check at `/mdac/egate`) |

## 2. Extracted field schema (from live HTML, element IDs)

**Traveler section**
| Label | id | Type / options |
|---|---|---|
| Name | `name` | text (letters+spaces only, `isCharacterKey`) |
| Passport No. | `passNo` | text |
| Date of Birth | `dob` | text, **DD/MM/YYYY**, datepicker attached |
| Nationality / Citizenship | `nationality` | `<select>`, values like `HKG - HONG KONG SAR` (ISO-3 prefixed) |
| Place of Birth | `pob` | `<select>`, same code format |
| Sex | `sex` | `<select>`: **MALE / FEMALE only** (no OTHERS — unlike SG) |
| Date of Passport Expiry | `passExpDte` | text, DD/MM/YYYY |
| Email Address | `email` | text, must pass regex |
| **Confirm Email Address** | `confirmEmail` | text, **must equal `email`** (JS `validateEmail()`) |
| Country / Region Code | `region` | phone country code |
| Mobile No. | `mobile` | digits only |
| **Confirm Mobile** | `confirmMobile` | **must equal `mobile`** (`validateMobile()`) |

**Trip section**
| Label | id | Type / options |
|---|---|---|
| Date of Arrival | `arrDt` | text DD/MM/YYYY |
| Date of Departure | `depDt` | text DD/MM/YYYY |
| Flight / Vessel / Transportation No. | `vesselNm` | text |
| Mode of Travel | `trvlMode` | `<select>`: 1=AIR, 2=LAND, 3=SEA |
| Last Port of Embarkation before Malaysia | `embark` | `<select>`, code format (e.g. SGP) |

**Accommodation section (conditional — see §4)**
| Label | id | Type |
|---|---|---|
| Accommodation of Stay | `accommodationStay` | `<select>`: 01=HOTEL/MOTEL/REST HOUSE, 02=RESIDENCE OF FRIENDS/RELATIVES, 99=OTHERS |
| Address (In Malaysia) | `accommodationAddress1` / `accommodationAddress2` | text |
| State | `accommodationState` | `<select>` — **AJAX**: `retrieveRefCity?state=` |
| City | `accommodationCity` (class `.accommodationCity`) | `<select>` — **AJAX chained on State**, then `retrievePostcode?cityCd=` |
| Postcode | `accommodationPostcode` | populated by AJAX from City |

**Verification**
- **Slider CAPTCHA** ("Slide the Puzzle", remote verify `/mdac/captcha`) gates the Submit button
- No review page: submit fires directly once form is valid + CAPTCHA solved

## 3. Differences vs Singapore (what the engine must learn)

| Aspect | SG (ICA) | MY (MDAC) | Impact |
|---|---|---|---|
| Framework | Angular Material | jQuery/Bootstrap | **New strategies needed, but simpler**: `SELECT_BY_ID` (native `<select>`), `TEXTBOX_BY_ID` — no combobox typing tricks, no ArrowDown |
| Dropdowns | type-to-filter comboboxes | static `<select>` with options | Easier; option values are ISO codes, labels are `CODE - NAME` |
| Confirm fields | none | email ×2, mobile ×2 | New `CONFIRM_FIELD` strategy: copy value from source field after both set |
| CAPTCHA | none observed | slider puzzle | New flow step: **CAPTCHA handoff** — automation fills everything, pauses, user solves slider, user taps Submit |
| Chained selects | none | State → City → Postcode (AJAX) | Engine must select sequentially and wait for options to populate |
| Group submission | "Add Traveller" in-wizard | none | App-side loop: **repeat the whole flow per traveler** |
| Review page | dedicated tab 3 | none | End-of-flow marker = "form valid + CAPTCHA visible" instead of review text |
| Sex options | FEMALE/MALE/OTHERS | MALE/FEMALE only | Profile mapping must normalize (see §6) |
| Date format | DD/MM/YYYY boxes | DD/MM/YYYY single text | `DATE_DMY_TEXTBOXES` doesn't apply; new `DATE_TEXT_DMY` strategy |
| Field keying | aria-label text | element `id` | Pack selector syntax gains an `id:` mode |

**Verdict: MDAC is Pattern A (AUTOFILL_SUBMIT) with two new sub-capabilities: `CAPTCHA_HANDOFF` and `PER_TRAVELER_REPEAT`.** Technically easier than SG per-submission; the complexity is all in the family workflow.

## 4. Conditional behavior (from portal JS)

`showAccommodation(nationality)`: the accommodation section (`formAccommodation`) displays only if the traveler's nationality is in the visa-required list (`mdacVisaCountry` hidden field) OR "allCountry" applies. For most visa-free nationalities (e.g. SG/HK passport holders visiting visa-free) the section is hidden — **but a hotel stay may still need declaring for certain cases**. Per the user scenario (SG-based family, hotel stay): expect the section hidden for visa-free nationals; if hidden, hotel info may simply not be requested by MDAC. **Open question Q1** below — must be verified with a real HK/SG passport nationality during implementation.

## 5. Data model proposal (Core domain)

```swift
/// One journey shared by everyone: dates, transport, lodging.
struct Trip {                     // existing, unchanged shape
    var arrivalDate: String       // 2026-12-17
    var departureDate: String     // 2026-12-19
    var lastPortBeforeDest: String  // SINGAPORE (renamed from lastPortBeforeSG)
    var transportNo: String        // e.g. "TR108" (vesselNm)
    var modeOfTravel: ModeOfTravel // .air
    // hotel fields stay as-is
}

/// A person traveling on a Trip.
struct Traveler: Codable, Identifiable {
    var id: UUID = UUID()
    var profile: Profile           // full identity (reuse existing struct)
    var isSelf: Bool               // the phone owner — first in list
    // Per-traveler overrides of trip-shared contact info:
    var emailOverride: String?     // nil = use group contact
    var mobileOverride: String?
}

/// A family/friend group on the same Trip.
struct TravelGroup: Codable, Identifiable {
    var id: UUID = UUID()
    var trip: Trip
    var travelers: [Traveler]      // ordered, self first
    var contactEmail: String       // shared default (parent's)
    var contactMobileCountryCode: String
    var contactMobile: String
}
```

Notes:
- `Trip` renames `lastPortBeforeSG` → `lastPortBeforeDest` (generalize once MY lands). Additive-safe with decode migration.
- Contacts default to group-level with per-traveler override — matches "same family, one parent's phone/email", while MDAC still requires an email+mobile per submission.
- Storage: `TravelGroup` v0 = file JSON (existing FileStore pattern), same as profile/history.

## 6. Field mapping (SG profile → MDAC fields)

| MDAC id | Source | Transform |
|---|---|---|
| `name` | profile.fullNameInPassport | letters+spaces only — strip digits/punct |
| `passNo` | profile.passportNumber | as-is |
| `dob` | profile.dateOfBirth | ISO → **DD/MM/YYYY** |
| `nationality` | profile.nationality | **name → ISO code lookup** (needs a `name→ISO3` table in the pack; e.g. HONG KONG SAR → `HKG`) |
| `pob` | profile.countryOfBirth | same lookup |
| `sex` | profile.sexInPassport | MALE/FEMALE; **OTHERS → open question Q2** (map to? or user must choose) |
| `passExpDte` | profile.passportExpiry | ISO → DD/MM/YYYY |
| `email` / `confirmEmail` | traveler email (override → group) | copy twice |
| `region` | profile.phoneCountryCode | digit normalization |
| `mobile` / `confirmMobile` | traveler mobile | copy twice |
| `arrDt` / `depDt` | trip.arrivalDate / departureDate | ISO → DD/MM/YYYY |
| `vesselNm` | trip.transportNo | new trip field (flight number reuse) |
| `trvlMode` | trip.modeOfTravel | name → 1/2/3 |
| `embark` | trip.lastPortBeforeDest | name → ISO code (SINGAPORE → SGP) |
| `accommodation*` | trip.hotel fields | only if section visible (Q1) |

## 7. Proposed UX flow (family of 5)

1. **Trip setup screen** (new): dates, flight no., hotel, shared contact → creates `TravelGroup`
2. **Traveler roster**: "You" + 4 family members; add via profile-lite form (or copy from main profile with edits)
3. Tap **"Fill Malaysia for all 5"**:
   - App opens MDAC, fills traveler 1 (self), pauses → **user solves slider CAPTCHA → user taps Submit**
   - Confirmation snapshot (registration outcome) → recorded to history
   - App reloads the form, fills traveler 2 → repeat
   - Progress: "Traveler 2 of 5" indicator; cancellable between travelers
4. **History**: one entry per traveler (linked by a shared `groupId` in `Submission`)

The CAPTCHA forces a human-in-the-loop per submission anyway — so the app's role is: fill all ~20 fields, scroll to the slider, and prompt "your turn". That's still a 30-second → ~1-minute flow per person vs 5–7 minutes manual.

## 8. New engine capabilities (pack-driven)

| Capability | Type | Notes |
|---|---|---|
| `SELECT_BY_ID`, `TEXTBOX_BY_ID`, `DATE_TEXT_DMY` | strategies | simple id-based fills for jQuery forms |
| `CONFIRM_FIELD` | strategy | `{ "mirrorOf": "email" }` — re-read source, set, validate equality |
| `OPTIONS_AJAX_CHAIN` | page-level | select State → wait for City options → select → wait for Postcode |
| `captcha: { "type": "slider", "handoff": true }` | flow step | automation pauses; status bar shows "Please solve the slider" |
| `repeat: { "perTraveler": true }` | flow step | loop the page sequence across `TravelGroup.travelers` |
| `nationalityCodeTable` | pack resource | name → ISO-3 map (MY uses `HKG - HONG KONG SAR` format) |

All expressible inside the existing pack JSON format — no engine rewrite, just new strategies + two flow steps.

## 9. Open questions (to discuss before implementing)

- **Q1** Does MDAC show the accommodation section for SG-resident / HK-passport travelers? (Likely hidden for visa-free nationals — verify with real nationality during build.)
- **Q2** `sex` has no OTHERS option in MDAC (SG does). How should the app handle an OTHERS profile? (Options: block MY for OTHERS with a clear message; or ask user per-trip.)
- **Q3** Should the group's 5 submissions also auto-fill an **SG arrival card** for the Dec 19 return (if any traveler is a non-resident)? Or is everyone SG-resident (no SG card needed)?
- **Q4** Does each family member need their own email/mobile, or is reusing the parent's contact acceptable to MDAC? (Portal has no stated rule; recommend: default to parent contact, per-person override UI.)
- **Q5** Slider CAPTCHA: accept human-solves-slider (recommended, assistive), or explore programmatic solving (higher risk + ToS concerns)?

## 10. Implementation phases (when SG is closed)

1. **MY-1 — schema pack**: `packs/my/fields.json` (v1) from §2, code tables, date/confirm strategies
2. **MY-2 — single-traveler MDAC run**: fill → captcha handoff → submit, end-to-end verified like SG
3. **MY-3 — group model**: `TravelGroup`/`Traveler` structs, trip-setup + roster UI
4. **MY-4 — batch loop**: per-traveler repeat, progress UI, per-person history records
5. **MY-5 — polish**: code-table OTA, Q1–Q5 answers folded in

Estimated effort: MY-1/2 ≈ a day (simpler portal than SG); MY-3/4 ≈ 1–2 days (new UI).
