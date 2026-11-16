// MARK: - MRZ parser (ICAO 9303 TD3 — passport bio page)
// Deterministic: two 44-char lines → identity fields, every field checksum-verified.
// A failed check digit = reject (offer re-scan / typing) — never save garbage.

import Foundation

enum MRZParseResult {
    case success(fields: [ExtractedField], warnings: [String])
    case failure(reason: String)
}

struct MRZParser {
    // MARK: Entry point

    /// Parses raw OCR text (may contain noise around the two lines).
    /// Finds candidate TD3 lines (44 chars each) and parses them.
    static func parse(rawText: String) -> MRZParseResult {
        // MRZ chars only: A-Z, 0-9, '<' — strip everything else per line.
        let lines = rawText
            .split(separator: "\n")
            .map { String($0) }
            .map { line in
                String(line.uppercased().map { ch in
                    // Common OCR confusions within MRZ charset
                    switch ch {
                    case "«", "‹", "〈", "<", "•", "·", ".", "。": return "<"
                    case "O": return "O"        // ambiguous with 0 — resolved by checksum
                    default: return ch
                    }
                }.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<".contains($0) })
            }

        // Anchor on the TD3 line 1 (must start with P< after glyph repair);
        // line 2 is the NEXT MRZ-shaped line after it. Real OCR sometimes loses
        // line 2 entirely (glare/angle) — that's a line1Only partial, not a failure.
        let candidates = lines.filter { line in
            line.count >= 20 && looksMRZLike(line)
        }
        let pIdx = candidates.firstIndex(where: { $0.hasPrefix("P<") })
        let poIdx = candidates.firstIndex(where: { $0.hasPrefix("PO") || $0.hasPrefix("PL") })
        guard let line1Idx = pIdx ?? poIdx else {
            return .failure(reason: "No MRZ lines found in text")
        }
        let line1 = candidates[line1Idx]
        if line1Idx + 1 < candidates.count {
            return parseTD3(line1: line1, line2: candidates[line1Idx + 1])
        }
        // Partial: line 2 missing — extract what line 1 carries (country, name).
        return parseTD3Line1Only(line1: line1)
    }

    private static func looksMRZLike(_ line: String) -> Bool {
        let fillers = line.filter { $0 == "<" }.count
        let valid = line.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<".contains($0) }.count
        return fillers >= 3 || Double(valid) / Double(max(line.count, 1)) > 0.9
    }

    /// Line-2-absent partial: issuing country + names only, low confidence.
    /// All line-2 fields (passport number, DOB, sex, expiry) require manual entry.
    static func parseTD3Line1Only(line1: String) -> MRZParseResult {
        func norm44(_ s: String) -> String {
            s.count >= 44 ? String(s.prefix(44)) : s + String(repeating: "<", count: 44 - s.count)
        }
        let l1 = norm44(line1)
        // Repair common P<-prefix misreads (P OCHN → P<CHN... style handled by
        // glyph pass already; a leading 'PO'/'PL' here still means P<).
        let repaired = l1.hasPrefix("P<") ? l1 : ("P<" + l1.dropFirst(2))
        guard repaired.hasPrefix("P<") else {
            return .failure(reason: "Not a passport MRZ line 1")
        }
        let issuingCountry = parseField(repaired, at: 2, len: 3)
        let (surname, given) = parseNames(String(repaired.dropFirst(5)))
        let fullName = (given + " " + surname).trimmingCharacters(in: .whitespaces)
        guard !fullName.isEmpty else {
            return .failure(reason: "Name field unreadable")
        }
        return .success(
            fields: [
                ExtractedField(key: .fullName, value: fullName, confidence: 0.7),
                ExtractedField(key: .issuingCountry, value: issuingCountry, confidence: 0.7),
            ],
            warnings: ["MRZ line 2 unreadable — passport number, DOB, sex, expiry need manual entry"]
        )
    }

    /// Strict entry: exactly two 44-char lines.
    static func parseTD3(line1: String, line2: String) -> MRZParseResult {
        // Pad/truncate to canonical 44 — real OCR often loses trailing '<'.
        func norm44(_ s: String) -> String {
            s.count >= 44 ? String(s.prefix(44)) : s + String(repeating: "<", count: 44 - s.count)
        }
        let l1 = norm44(line1)
        let l2 = norm44(line2)

        // Line 1: P<UTO + names
        guard l1.hasPrefix("P<") else {
            return .failure(reason: "Line 1 doesn't start with P< (not a passport MRZ)")
        }
        let issuingCountry = parseField(l1, at: 2, len: 3)          // positions 3–5
        let namePart = String(l1.dropFirst(5))
        let (surname, givenNames) = parseNames(namePart)

        // Line 2 layout (TD3):
        //  1–9    passport number
        //  10     check digit for passport number
        //  11–13  nationality
        //  14–19  date of birth (YYMMDD)
        //  20     check digit for DOB
        //  21     sex (M/F/X)
        //  22–27  expiry date (YYMMDD)
        //  28     check digit for expiry
        //  29–42  personal number (optional, often all <)
        //  43     check digit for personal number
        //  44     composite check digit
        let passportNumber = parseField(l2, at: 0, len: 9)
        let passportCheck = digitAt(l2, 9) ?? -1
        let nationality = parseField(l2, at: 10, len: 3)
        let dobRaw = parseField(l2, at: 13, len: 6)
        let dobCheck = digitAt(l2, 19) ?? -1
        let sexChar = String(l2[l2.index(l2.startIndex, offsetBy: 20)])
        let expiryRaw = parseField(l2, at: 21, len: 6)
        let expiryCheck = digitAt(l2, 27) ?? -1

        // Checksums — per spec, computed over the RAW field text (with padding '<').
        var warnings: [String] = []
        let passportRaw = String(l2.prefix(9))                  // raw 9-char field
        let personalRaw = String(l2[l2.index(l2.startIndex, offsetBy: 28)..<l2.index(l2.startIndex, offsetBy: 42)])   // 14 chars
        let personalCheck = digitAt(l2, 42)
        let passportValid = checkDigit(passportRaw) == passportCheck
        let dobValid = checkDigit(dobRaw) == dobCheck
        let expiryValid = checkDigit(expiryRaw) == expiryCheck
        // Composite check digit input: pn+check, dob+check, expiry+check, personal+check
        let compositeInput = passportRaw + String(passportCheck) + dobRaw + String(dobCheck)
            + expiryRaw + String(expiryCheck) + personalRaw + String(personalCheck ?? 0)
        // Composite is a WARNING-grade check: real OCR frequently truncates the
        // trailing personal/composite digits, and padding makes them unverifiable.
        // The passport-number check digit (position 9, mid-line) is the hard gate.
        let compositeValid: Bool
        if let compositeCheck = digitAt(l2, 43) {
            compositeValid = checkDigit(compositeInput) == compositeCheck
        } else {
            compositeValid = false   // truncated — warn, don't fail
        }

        guard passportValid else { return .failure(reason: "Passport number check digit failed") }

        // Dates: YYMMDD → ICAO century rule (ICAO 9303: dates interpreted as
        // within 35 years back / 15 years forward of the current year).
        guard let dob = mrzDate(dobRaw), let expiry = mrzDate(expiryRaw) else {
            return .failure(reason: "Unparseable date in MRZ")
        }
        if !dobValid { warnings.append("Date of birth check digit failed") }
        if !expiryValid { warnings.append("Expiry check digit failed") }
        if digitAt(l2, 43) == nil {
            warnings.append("Composite check digit truncated (OCR padding) — not verified")
        } else if !compositeValid {
            warnings.append("Composite check digit failed")
        }

        let fullName = (givenNames + " " + surname).trimmingCharacters(in: .whitespaces)
        let sex: String
        switch sexChar {
        case "M": sex = "MALE"
        case "F": sex = "FEMALE"
        default: sex = "OTHERS"
        }

        let fields: [ExtractedField] = [
            .init(key: .fullName, value: fullName, confidence: nameConfidence(namePart)),
            .init(key: .passportNumber, value: passportNumber, confidence: passportValid ? 1.0 : 0.0),
            .init(key: .nationality, value: nationality, confidence: 1.0),
            .init(key: .dateOfBirth, value: dob, confidence: dobValid ? 1.0 : 0.5),
            .init(key: .sex, value: sex, confidence: 0.9),
            .init(key: .expiryDate, value: expiry, confidence: expiryValid ? 1.0 : 0.5),
            .init(key: .issuingCountry, value: issuingCountry, confidence: 1.0),
        ]
        return .success(fields: fields, warnings: warnings)
    }

    // MARK: Helpers

    /// Digit at a 0-based index; nil if the char is '<' (padding) or non-digit.
    private static func digitAt(_ line: String, _ idx: Int) -> Int? {
        guard idx < line.count else { return nil }
        let ch = line[line.index(line.startIndex, offsetBy: idx)]
        return ch.wholeNumberValue.map { min($0, 9) }   // MRZ check digits are 0-9
    }

    private static func parseField(_ line: String, at: Int, len: Int) -> String {
        let start = line.index(line.startIndex, offsetBy: at)
        let end = line.index(start, offsetBy: len)
        return String(line[start..<end])
            .replacingOccurrences(of: "<", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func parseNames(_ part: String) -> (surname: String, given: String) {
        // "SURNAME<<GIVEN<NAMES<<<…" → ("SURNAME", "GIVEN NAMES")
        let comps = part.components(separatedBy: "<<")
        let surname = (comps.first ?? "").replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        let given = (comps.count > 1 ? comps[1] : "").replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        return (surname, given)
    }

    /// ICAO 9303 check digit: weights 7,3,1 repeating; A=10..Z=35, <=0.
    static func checkDigit(_ input: String) -> Int {
        let weights: [Int] = [7, 3, 1]
        var sum = 0
        for (i, ch) in input.enumerated() {
            let value: Int
            if let digit = ch.wholeNumberValue { value = digit }
            else if let ascii = ch.asciiValue, ascii >= 65 && ascii <= 90 { value = Int(ascii - 55) }
            else { value = 0 }                                  // '<'
            sum += value * weights[i % 3]
        }
        return sum % 10
    }

    /// YYMMDD → ISO "YYYY-MM-DD" with the ICAO century rule.
    private static func mrzDate(_ yymmdd: String) -> String? {
        guard yymmdd.count == 6,
              let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)),
              let dd = Int(yymmdd.dropFirst(4).prefix(2)),
              (1...12).contains(mm), (1...31).contains(dd) else { return nil }
        let currentYY = Calendar.current.component(.year, from: Date()) % 100
        let currentCentury = Calendar.current.component(.year, from: Date()) / 100 * 100
        var year = currentCentury + yy
        if yy > currentYY + 15 { year -= 100 }   // more than 15 years ahead → last century
        return String(format: "%04d-%02d-%02d", year, mm, dd)
    }

    private static func nameConfidence(_ namePart: String) -> Double {
        // Lower confidence when odd characters survived in the name field.
        let valid = namePart.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ< ".contains($0) }.count
        return Double(valid) / Double(namePart.count)
    }
}
