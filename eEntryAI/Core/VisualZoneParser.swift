// MARK: - Visual-zone parser (passports, printed fields)
// When MRZ is missing/mangled, the printed bio page still carries most fields —
// and OCR actually reads the human typography BETTER than OCR-B MRZ glyphs.
// Label-anchored + format-guided; everything arrives with reduced confidence
// (the user verifies on the card back; manual edits are confidence=1.0).

import Foundation

struct VisualZoneParser {
    /// Extracts what it can from raw OCR text of a bio page.
    /// Returns fields with reduced confidence; missing fields are simply absent.
    static func parse(rawText: String) -> [ExtractedField] {
        var fields: [ExtractedField] = []
        let text = rawText.uppercased()

        // ---- Nationality / place of birth: known word list ----
        // e.g. "CHINESE" printed under Nationality. Match against common adjectives.
        let nationalities = [
            "CHINESE": "CHN", "AMERICAN": "USA", "BRITISH": "GBR", "FRENCH": "FRA",
            "GERMAN": "DEU", "JAPANESE": "JPN", "KOREAN": "KOR", "INDIAN": "IND",
            "SINGAPOREAN": "SGP", "MALAYSIAN": "MYS", "AUSTRALIAN": "AUS",
            "CANADIAN": "CAN", "DUTCH": "NLD", "HONGKONG": "HKG", "RUSSIAN": "RUS",
            "THAI": "THA", "VIETNAMESE": "VNM", "FILIPINO": "PHL", "INDONESIAN": "IDN",
        ]
        if let (word, iso) = nationalities.first(where: { text.contains($0.key) }) {
            fields.append(ExtractedField(key: .nationality, value: iso, confidence: 0.7))
            _ = word
        }

        // ---- Place of birth: after the "PLACE OF BIRTH"-ish label ----
        if let pob = capture(after: ["PLACE OF BIRTH", "PLACE OF B1RTH"], in: text) {
            fields.append(ExtractedField(key: .placeOfBirth, value: pob, confidence: 0.6))
        }

        // ---- Dates: "26 MAR 1994" style (DD MMM YYYY), or DD/MM/YYYY ----
        let months = [
            ("JAN", "01"), ("FEB", "02"), ("MAR", "03"), ("APR", "04"),
            ("MAY", "05"), ("JUN", "06"), ("JUL", "07"), ("AUG", "08"),
            ("SEP", "09"), ("OCT", "10"), ("NOV", "11"), ("DEC", "12"),
        ]
        // Find every date in the text; classify by context: nearest preceding
        // label decides (DATE OF BIRTH vs DATE OF ISSUE vs DATE OF EXPIRY).
        let dateRegex = try! NSRegularExpression(pattern: #"(\d{2})\s*([A-Z]{3,4}|\d{2})\s*(\d{2,4})"#)

        struct Found { let day: Int; let month: Int; let year: Int; let range: NSRange; let iso: String }
        var found: [Found] = []
        let ns = text as NSString
        // Garbled OCR often injects stray chars between date parts
        // ("29 R/DEC 2030") — strip non-date noise around month tokens first.
        let cleanedText = text.replacingOccurrences(
            of: #"(\d{2})\s*[A-Z]?[./-]?\s*([A-Z]{3})"#,
            with: "$1 $2",
            options: .regularExpression
        )
        let nsClean = cleanedText as NSString
        dateRegex.enumerateMatches(in: cleanedText, range: NSRange(location: 0, length: nsClean.length)) { m, _, _ in
            guard let m else { return }
            let dayS = nsClean.substring(with: m.range(at: 1))
            let monthS = nsClean.substring(with: m.range(at: 2))
            let yearS = nsClean.substring(with: m.range(at: 3))
            guard let day = Int(dayS), (1...31).contains(day) else { return }
            var month = -1
            if let idx = months.firstIndex(where: { monthS.hasPrefix($0.0) }) {
                month = Int(months[idx].1)!
            } else if let m2 = Int(monthS), (1...12).contains(m2) {
                month = m2
            }
            guard month > 0 else { return }
            var year = Int(yearS) ?? 0
            if year < 100 { year += 1900 + (year > 30 ? 0 : 100) }   // 94→1994, 27→2027
            guard (1900...2100).contains(year) else { return }
            let iso = String(format: "%04d-%02d-%02d", year, month, day)
            found.append(Found(day: day, month: month, year: year, range: m.range, iso: iso))
        }

        // Nearest label before each date decides its meaning (offsets shift by
        // the cleaning — search in cleanedText).
        for d in found {
            let before = nsClean.substring(to: d.range.location)
            if before.contains("BIRTH") && !fields.contains(where: { $0.key == .dateOfBirth }) {
                fields.append(ExtractedField(key: .dateOfBirth, value: d.iso, confidence: 0.6))
            } else if before.contains("EXPIR") && !fields.contains(where: { $0.key == .expiryDate }) {
                fields.append(ExtractedField(key: .expiryDate, value: d.iso, confidence: 0.6))
            }
            // DATE OF ISSUE intentionally skipped — arrival cards don't ask for it.
        }

        // ---- Name: after "SURNAME"/"GIVEN NAME" labels, or a plain "Name" label ----
        if let surname = capture(after: ["SURNAME", "SURN4ME"], in: text) {
            if let given = capture(after: ["GIVEN NAME", "G1VEN NAME"], in: text) {
                fields.append(ExtractedField(key: .fullName, value: "\(given) \(surname)", confidence: 0.6))
            } else {
                fields.append(ExtractedField(key: .fullName, value: surname, confidence: 0.5))
            }
        } else if let name = capture(after: ["NAME", "N4ME"], in: text) {
            // "Name LI YUANFENG" — given first, surname last (as printed).
            fields.append(ExtractedField(key: .fullName, value: name, confidence: 0.6))
        }

        // ---- Sex: "M", "F", "X" near the sex label ----
        if let sexZone = capture(after: ["SEX", "5EX"], in: text) {
            let first = sexZone.prefix(1)
            if first == "M" { fields.append(ExtractedField(key: .sex, value: "MALE", confidence: 0.6)) }
            if first == "F" { fields.append(ExtractedField(key: .sex, value: "FEMALE", confidence: 0.6)) }
        }

        // ---- Passport number: format-guided repair ----
        // Typical patterns: AB1234567, E12345678, G1234567, P1234567...
        // Strip label noise; try O→0-style repair until it matches [A-Z]{1,2}\d{6,8}.
        if let pn = passportNumber(in: text) {
            fields.append(ExtractedField(key: .passportNumber, value: pn, confidence: 0.6))
        }

        return fields
    }

    // MARK: Helpers

    /// Text following any of the labels, up to 40 chars, cleaned.
    private static func capture(after labels: [String], in text: String) -> String? {
        for label in labels {
            guard let r = text.range(of: label) else { continue }
            let rest = String(text[r.upperBound...])
            // Stop at the first newline — labels caption their own line only.
            let line = String(rest.split(separator: "\n").first ?? Substring(rest))
            let cleaned = line
                .trimmingCharacters(in: CharacterSet(charactersIn: " .·•-/:"))
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// Finds a passport-number-shaped token and repairs common OCR digit errors.
    private static func passportNumber(in text: String) -> String? {
        // Candidate: 1-2 letters then 6-8 alnum, allowing O/I/S/B/Z/G in the digit part.
        let regex = try! NSRegularExpression(pattern: #"\b[A-Z]{1,2}[A-Z0-9]{5,8}\b"#)
        let ns = text as NSString
        let candidates = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in candidates.reversed() {         // MRZ/number usually printed late on the page
            let raw = ns.substring(with: m.range)
            // Skip obvious label words
            guard !["CHINESE", "BEIJING", "PASSPORT", "CHINA", "SANFRANCISCO"].contains(raw) else { continue }
            // Repair trailing digit run: O→0, I/L→1, S→5, B→8, Z→2, G→6 — but only
            // AFTER the first 1-2 letters.
            var chars = Array(raw)
            guard chars.count >= 7 else { continue }
            var letterPrefix = 0
            for ch in chars where ch.isLetter && letterPrefix < 2 {
                letterPrefix += 1
            }
            for i in letterPrefix..<chars.count {
                switch chars[i] {
                case "O": chars[i] = "0"
                case "I", "L": chars[i] = "1"
                case "S": chars[i] = "5"
                case "B": chars[i] = "8"
                case "Z": chars[i] = "2"
                case "G": chars[i] = "6"
                default: break
                }
            }
            let repaired = String(chars)
            // Valid shape: letters + digits only after repair
            let shape = try! NSRegularExpression(pattern: #"^[A-Z]{1,2}\d{6,8}$"#)
            if shape.firstMatch(in: repaired, range: NSRange(location: 0, length: repaired.count)) != nil {
                return repaired
            }
        }
        return nil
    }
}
