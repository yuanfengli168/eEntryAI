# Secret Vault — Design Doc

**Status:** design agreed 2026-11-16 (pre-implementation). Vault v1 is the next build after P1/P2.

**Purpose:** the encrypted on-device home for identity documents. Kills manual profile
typing (camera/upload/typing converge on one data model), serves the family-traveler
model (Malaysia.md), and delivers the day-one privacy requirement: secrets never
leave the iPhone, at rest they're ciphertext.

---

## 1. Data model

```
VaultPerson                    (family member; "me" + others)
 ├─ id, displayName
 ├─ documents: [VaultDocument]
 └─ relationship notes (free text, optional)

VaultDocument                  (a physical document; add/remove freely)
 ├─ id, type (v1: .passport; later: .idCardTD1, .visa…)
 ├─ state: valid | expiring(<6mo, amber) | expired(gray, kept)
 ├─ frontImage: encrypted file reference
 ├─ extracted: [ExtractedField]   (MRZ or manual entry)
 └─ createdAt, source: .scan | .upload | .manual

ExtractedField
 ├— key (maps to Profile fields), value, confidence (0-1)
 └— lowConfidence(<0.8) → amber underline on card back
```

Rules:
- Documents are objects — renewal adds a new one, old stays (history + "which passport did I use" reference)
- Each person's profile fields derive from their PRIMARY (latest valid) document
- `Profile` (the fill source) becomes a computed projection of the vault, not a separate hand-maintained store

## 2. Input paths (all converge on one model)

| Path | Pipeline | Notes |
|---|---|---|
| Live camera scan | AVFoundation capture → Vision OCR → MRZ parser | primary; auto-capture on MRZ detection |
| Upload from Photos | PhotosPicker → same OCR pipeline | existing scans, desk workflow |
| Manual typing | straight into fields, no OCR | fallback; always one tap away (Revolut pattern: never block on OCR) |

### OCR reality (learned from a real passport photo, 2026-11-16)

Vision reads the **printed (visual-zone) fields well** but MRZ OCR-B glyphs poorly
(fillers → bullets, line 2 often lost to glare/angle). Consequences, all shipped:
- MRZ parse yields a **line1Only partial** (country + names at fixed positions —
  position-based, no regex needed) when line 2 is unreadable
- **VisualZoneParser** extracts printed fields as fallback/extras: nationality word-list → ISO,
  place of birth (label-anchored), dob/expiry dates (regex + context), name, sex,
  format-guided passport-number repair. Reduced confidence → amber underline → user verifies
- Everything the parser extracts is **field values only** — the image never leaves the process

### Planned: local-LLM field matching (next iteration)

The label→field wiring (exact string match on OCR-garbled labels) is the fragile
layer. Plan: replace it with an **on-device LLM** that maps OCR output → our
`IdentityFieldKey` schema (constrained JSON output). Privacy model unchanged:
OCR text stays in-process; the model runs on-device. Candidate models and the
decision live in §10.

MRZ (ICAO 9303) yields: name, passport number, nationality, DOB, sex, expiry, issuing country.
**NOT in MRZ:** place of birth, place of residence → P0 asks once, remembered.
MRZ check digits validate the parse — a failed checksum = offer re-scan/typing, never save garbage.

## 3. Card UI (agreed design)

- Card front: document photo
- Tap → flip (or expand) → extracted fields underneath; low-confidence fields get amber underline
- No verification ceremony — correction is opt-in, not a blocking step
- Expiry badge on card: "expires in 4 months" (airlines want 6-month validity — planning value)

## 4. Security architecture

```
At rest (ALWAYS):
  photos + vault index → AES-256-GCM encrypted files (Application Support)
  key material → Keychain, kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  vault encryption key → generated once, WRAPPED by Secure Enclave
                         (kSecAccessControlBiometryCurrentSet)

Unlock (vault screens only):
  Face ID → LAContext → unwrap key → decrypt vault into MEMORY only

Auto-lock (clears key from memory; at rest is ciphertext regardless):
  - app → background: immediate
  - idle on vault screens: 5 min (configurable: 1 / 5 / 10 / never)
  - manual Lock button
```

- Vault screens gated; rest of the app (country picker, webview) works without
  Face ID — a mid-submission lock-out must never happen
- **Migration duty:** the current plaintext `profile.json` is a known gap. Vault v1
  replaces it: identity fields move INTO the vault; the old file store is deleted
  on first successful vault unlock (with user confirmation).
- Keychain-wrapped key means: no Face ID = no unwrap = no decrypt. Secure Enclave
  never exports the wrapping key. Device-loss: vault is unrecoverable (by design);
  re-scan documents. Cloud backup = explicit non-goal for v1.

## 5. Auto-lock spec

| Trigger | Default | Configurable |
|---|---|---|
| App → background | lock | no (security default) |
| Idle while vault open | 5 min | 1 / 5 / 10 / never |
| Manual Lock button | instant | — |
| Face ID fail ×N | lock + passcode fallback | system behavior |

Settings live in a Vault section of the app (not iOS Settings — keep it in-context).

## 6. Integration points

- **P0 pre-flight**: vault data auto-fills the gap sheet (identity fields pre-populated;
  only genuinely missing data is asked)
- **Fill engine**: `Profile` projection = primary document's extracted fields + the
  P0-remembered fields (birthplace, residence) — FieldValueResolver unchanged
- **Malaysia TravelGroup**: `Traveler` gets `personID → VaultPerson` (family members'
  identities come from the vault, per Malaysia.md §5)

## 7. Out of scope v1 (tracked, not built)

- Visual-zone OCR (non-MRZ text on the bio page) — P0 covers the 2 missing fields
- Cloud/encrypted backup, device transfer
- Non-passport document types
- Multiple vault users (the phone owner is the custodian of family docs — by design)
- Watch/iPad unlock

## 8. Build phases

- **V-1**: VaultStore (encrypted file + SE-wrapped key + lock/unlock + auto-lock timers)
- **V-2**: MRZ parser + Vision OCR pipeline + checksum validation (unit-tested against
  sample MRZ strings — no camera needed for the parser tests)
- **V-3**: Scan/Upload/Manual input UIs → card grid with flip
- **V-4**: person management + Profile projection + plaintext-store migration + P0 wiring
- **V-5**: settings (auto-lock options) + expiry badges

Estimate: ~2 days. V-2 is the riskiest (OCR behavior on real passport photos) — build it
second so V-1's security core is solid before UI exists.

## 9. Deployment & signing decisions (2026-11-16)

| Environment | Signing | Biometry |
|---|---|---|
| Simulator (prototype) | **Ad-hoc** (`CODE_SIGN_IDENTITY=-`, no Apple account) + `keychain-access-groups` entitlements file. Required: unsigned builds fail Keychain with -34018 (errSecMissingEntitlement). | Simulated Face ID: enroll via Simulator menu Features ▸ Face ID. Errors surface on the lock screen. |
| Real device (next phase) | **Temporary/proper signing identity** — free Apple ID works for personal-device installs; no code changes, only signing config. | Real Face ID via LAContext (same code path); passcode fallback automatic. |
| App Store (future) | Distribution certificate + full entitlements review. | Same. |

Keychain items are `ThisDeviceOnly` by design: no backup migration, no cross-device key sync.
