// MRZ parser unit tests — ICAO 9303 TD3 spec cases + checksum edge cases.
// Uses the ICAO Doc 9303 Part 5 sample passport (the spec's worked example).

import XCTest
@testable import eEntryAI

final class MRZParserTests: XCTestCase {

    // Valid fixtures with COMPUTED check digits (ICAO 9303 TD3 layout, both lines 44 chars):
    // line1 = P< + country(3) + < + name(38); line2 = pn(9) check nat(3) dob(6) check sex
    // exp(6) check personal(14) check composite
    static let icaoLine1 = "P<NLD<EXAMPLE<<SPECIMEN<<<<<<<<<<<<<<<<<<<<<"
    static let icaoLine2 = "HA672249<7NLD6808149F2508186<<<<<<<<<<<<<<04"

    // MARK: Happy path

    func testICAO9303Specimen() throws {
        let result = MRZParser.parseTD3(line1: Self.icaoLine1, line2: Self.icaoLine2)
        guard case .success(let fields, let warnings) = result else {
            if case .failure(let reason) = result { XCTFail("specimen should parse: \(reason)") }
            return
        }
        XCTAssertEqual(fields.value(for: .passportNumber), "HA672249")
        XCTAssertEqual(fields.value(for: .nationality), "NLD")
        XCTAssertEqual(fields.value(for: .dateOfBirth), "1968-08-14")
        XCTAssertEqual(fields.value(for: .sex), "FEMALE")
        XCTAssertEqual(fields.value(for: .expiryDate), "2025-08-18")
        XCTAssertEqual(fields.value(for: .issuingCountry), "NLD")
        XCTAssertEqual(fields.value(for: .fullName), "SPECIMEN EXAMPLE")
        XCTAssertTrue(warnings.isEmpty, "computed-valid fixture must have zero warnings: \(warnings)")
    }

    // MARK: Check digits

    func testCheckDigitKnownValues() {
        // Verified against the ICAO algorithm (weights 7,3,1) by hand:
        XCTAssertEqual(MRZParser.checkDigit("520727"), 3)     // Doc 9303 worked example
        XCTAssertEqual(MRZParser.checkDigit("HA672249<"), 7)
        XCTAssertEqual(MRZParser.checkDigit("680814"), 9)
        XCTAssertEqual(MRZParser.checkDigit("AA0000000"), 0)
        XCTAssertEqual(MRZParser.checkDigit("<<<<<<<<<<<"), 0)
    }

    func testCorruptedPassportNumberRejected() {
        // Flip one char in the passport number → checksum fails → reject.
        let corrupted = "HA672248<7NLD6808149F2508186<<<<<<<<<<<<<<04"
        let result = MRZParser.parseTD3(line1: Self.icaoLine1, line2: corrupted)
        guard case .failure = result else {
            XCTFail("corrupted passport number must be rejected")
            return
        }
    }

    // MARK: Noise tolerance

    func testRawTextWithNoise() {
        // OCR output typically has header text around the two lines.
        let raw = """
        PASSPORT
        KONINKRIJK DER NEDERLANDEN
        \(Self.icaoLine1)
        \(Self.icaoLine2)
        """
        let result = MRZParser.parse(rawText: raw)
        guard case .success(let fields, _) = result else {
            XCTFail("must find MRZ inside noisy text")
            return
        }
        XCTAssertEqual(fields.value(for: .passportNumber), "HA672249")
    }

    func testNotAnMRZRejected() {
        let result = MRZParser.parse(rawText: "Hello world this is not a machine readable zone")
        guard case .failure = result else {
            XCTFail("non-MRZ text must fail, not produce garbage")
            return
        }
    }

    // MARK: Century rule

    func testDOBCenturyRule() {
        // DOB "680814" → 1968 (well over 15 years ago → last century).
        let result = MRZParser.parseTD3(line1: Self.icaoLine1, line2: Self.icaoLine2)
        guard case .success(let fields, _) = result else { return XCTFail("parse failed") }
        XCTAssertEqual(fields.value(for: .dateOfBirth), "1968-08-14")
    }

    // MARK: Names

    func testMultiWordNames() {
        // Compound given names: "MARIA<DE<LA<CRUZ" — computed-valid check digits.
        let l1 = "P<ESP<SANCHEZ<<MARIA<DE<LA<CRUZ<<<<<<<<<<<<<"
        let l2 = "AA00000000ESP5808142F2101015<<<<<<<<<<<<<<00"
        let result = MRZParser.parseTD3(line1: l1, line2: l2)
        guard case .success(let fields, _) = result else {
            if case .failure(let reason) = result { XCTFail("multi-word name parse: \(reason)") }
            return
        }
        XCTAssertEqual(fields.value(for: .fullName), "MARIA DE LA CRUZ SANCHEZ")
    }

    // MARK: Document state

    func testDocumentStateExpiryRules() {
        let future = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
        let soon = Calendar.current.date(byAdding: .month, value: 3, to: Date())!
        let past = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let iso = ISO8601DateFormatter()

        XCTAssertEqual(DocumentState(expiry: iso.string(from: future)), .valid)
        XCTAssertEqual(DocumentState(expiry: iso.string(from: soon)), .expiring)
        XCTAssertEqual(DocumentState(expiry: iso.string(from: past)), .expired)
        XCTAssertEqual(DocumentState(expiry: "garbage"), .valid)   // unparseable → don't alarm
    }
}

private extension Array where Element == ExtractedField {
    func value(for key: IdentityFieldKey) -> String? {
        first(where: { $0.key == key })?.value
    }
}
