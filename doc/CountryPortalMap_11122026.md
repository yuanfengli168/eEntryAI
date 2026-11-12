# eEntryAI — Country Portal Map (Draft 2026-11-12)

One identity profile → auto-filled arrival cards → submitted per country.
Status legend: 🔍 = portal research pending, ⚠️ = feasibility risk, ✅ = researched

## 1. Singapore 🇸🇬 — ✅ (today's focus)

| Item | Detail |
|---|---|
| Portal | https://eservices.ica.gov.sg/arrivalcard (SG Arrival Card w/ Electronic Health Declaration) |
| Account | None — submit per trip |
| Window | Within 3 days **before** arrival (incl. day of arrival) |
| Cost | Free |
| App type | JS single-page wizard (embedded browser target) |
| Feasibility | **HIGH** — web form, no login, no CAPTCHA observed |

Next: map the wizard's page-by-page field schema → profile fields (see [Singapore deep dive](#singapore-deep-dive)).

## 2. Vietnam 🇻🇳 — 🔍

- Electronic arrival declaration ("e-Arrival card") via Vietnam National Portal for foreigners; paper fallback at ports.
- Likely portal: `dichvucong.gov.vn`-family service. **To verify:** exact URL, languages, account/CAPTCHA.
- Feasibility: TBD (expect MEDIUM — national portal may be slow/heavily scripted).

## 3. China 🇨🇳 — 🔍 ⚠️

- Foreigner Arrival Card (外国人入境卡); NIA pushes "online filling" (网上填写) via NIA app / WeChat mini-program → QR at border.
- **Risk:** automation inside WeChat mini-programs is hard with an embedded browser; may need app-integration path instead.
- Feasibility: **LOW-MEDIUM** for web automation; verify whether a browser portal exists.

## 4. USA 🇺🇸 — 🔍 ⚠️

- No single "arrival card" for visa-waiver travelers. The pieces:
  - ESTA (esta.cbp.dhs.gov) — pre-travel authorization, paid, per-trip validity. A web form, but authorization ≠ arrival card.
  - Customs declaration (CBP Form 6059B) — at most airports handled by APC kiosks / Mobile Passport Control app (MPC, official CBP app — no browser automation possible).
  - I-94 — digital now, tied to entry stamping.
- **Likely position:** support ESTA form-filling; arrival-side is kiosk/app-bound → assist-only.
- Feasibility: **LOW** for the arrival step itself.

## 5. Australia 🇦🇺 — 🔍

- Digital Passenger Declaration (DPD): https://dpd.homeaffairs.gov.au — **requires account** (email + password).
- Paper Incoming Passenger Card still accepted at borders.
- Feasibility: **MEDIUM-HIGH** — web app, but account creation/login adds steps; profile must store DPD credentials (or we automate login via secure keychain).

## 6. Japan 🇯🇵 — 🔍

- Visit Japan Web: https://services.digital.go.jp/en/visit-japan-web — account-based; passport registered via OCR; generates QR for immigration + customs.
- Paper arrival card for foreigners still exists but Visit Japan Web is the recommended channel.
- Feasibility: **MEDIUM** — account + passport-image OCR step; QR output means we don't "submit" to immigration, we prepare the QR for scanning. Different pattern than SG (prepare-vs-submit).

## Cross-cutting notes

- **Pattern A (submit for user):** SG, AU(DPD), VN(?), ESTA — embedded browser + AI autofill + user-reviewed submit.
- **Pattern B (prepare artifact):** CN (QR), JP (QR) — generate QR/confirmation for user to present at border.
- **Pattern C (assist-only):** US arrival step (kiosk/MPC app).
- Identity profile must cover the union of all schemas: passport data, trip data, health declarations, customs declarations (AU/US ask goods/currency), contacts, accommodation.
- All PII stored on-device only (Keychain/Secure Enclave); AI on-device (Apple Foundation Models default, small CJK model add-on for CN/JP/VN portals).

## Singapore deep dive ✅ (walked 2026-11-12)

**URL flow:** `eservices.ica.gov.sg/arrivalcard` → visitor path: `/sgac/fvipa/submit` → 3-tab wizard (Angular/Material). No login, no CAPTCHA. ~5-7 min manual; target <1 min automated.

### Tab 1 — Traveller Details
| Field | Type | Notes |
|---|---|---|
| Date of Arrival | radio | Only 3 dates offered (arrival window: today + 2 days) |
| Full Name (In Passport) * | text | |
| Passport Number * | text | |
| Passport Expiry * | D/M/Y textboxes | DD/MM/YYYY |
| Sex (in Passport) * | radio | FEMALE / MALE / OTHERS |
| Date of Birth * | D/M/Y textboxes | DD/MM/YYYY; "Day unknown"/"Month unknown" checkboxes |
| Nationality/Citizenship * | **searchable combobox** | e.g. "CHINESE" |
| Country/Place of Birth * | **searchable combobox** | e.g. "HONG KONG SAR" |
| Place of Residence (Home Country) * | **searchable combobox** | |
| Email Address * | text | uppercase transform applied |
| Country Code * | combobox | e.g. "852" |
| Mobile Number * | text | |
| Last City/Port of Embarkation * | **searchable combobox** | |
| Purpose of Travel * | combobox | BUSINESS/…, EDUCATION/TRAINING, EMPLOYMENT, OFFICIAL/GOVERNMENT VISIT, HOLIDAY/SIGHTSEEING/LEISURE |
| Departure Date from SG * | D/M/Y textboxes | **must be > arrival date** |
| Next City/Port of Disembarkation * | **searchable combobox** | has "Same as Last City" checkbox |
| Ever used different-name passport? * | radio YES/NO | |
| Health Q1 (fever/cough/…) * | radio YES/NO | |
| Health Q2 (yellow-fever countries, 6 days) * | radio YES/NO | |
| Add Traveller | button | group submission supported (group leader) |

### Tab 2 — Visit Details (conditional logic)
| Field | Type | Appears when |
|---|---|---|
| Mode of Travel * | radio | always: AIR / LAND / SEA |
| Mode of Transport * | radio | AIR → COMMERCIAL FLIGHT / PRIVATE/CARGO/OTHERS |
| Flight Code * | **searchable combobox** (airline list) | Mode=AIR |
| Flight Number * | text | Mode=AIR (auto-prefixed with code, e.g. CA123) |
| Type of Accommodation * | radio | always: HOTEL / RESIDENTIAL / TRANSIT / DAY TRIP |
| Name of Hotel * | **searchable combobox** | Accommodation=HOTEL |

### Tab 3 — Review
- All values rendered read-only → **AI verification pass possible** (compare rendered values vs profile before user taps submit)
- Declaration checkbox + Submit button

### Automation-relevant findings
1. All dropdowns are **searchable** (type → filtered listbox) — automatable via fill+option-click.
2. **Conditional fields** appear/disappear based on radios — DOM extraction must run after each choice.
3. Inline validation errors (e.g. "Date cannot be before arrival date") — need error-state detection.
4. Angular Material components — inputs need proper event dispatch (input/change events), not just value set.
5. Estimated ~30 unique profile fields cover SG entirely; ~80% overlap with other countries' schemas expected.
