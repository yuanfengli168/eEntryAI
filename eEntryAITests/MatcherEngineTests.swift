// Matcher tests: JSON-parsing robustness + registry resolution.
// Inference itself needs real weights (bake-off phase on device) — here we pin
// the deterministic contract around the LLMs' output.

import XCTest
@testable import eEntryAI

final class MatcherEngineTests: XCTestCase {

    // MARK: JSON tolerance (MLXMatcher.parseFields)

    func testParseCleanJSON() {
        let json = """
        {"fullName":"LI YUANFENG","passportNumber":"E12345678","nationality":"CHN",
         "dateOfBirth":"1994-03-26","sex":"MALE","expiryDate":"2030-12-29",
         "issuingCountry":"CHN","placeOfBirth":"BEIJING"}
        """
        let fields = MLXMatcher.parseFields(from: json)
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(fields.value(for: .fullName), "LI YUANFENG")
        XCTAssertEqual(fields.value(for: .passportNumber), "E12345678")
        XCTAssertEqual(fields.value(for: .placeOfBirth), "BEIJING")
    }

    func testParseMarkdownFencedJSON() {
        let content = """
        ```json
        {"fullName": "LI YUANFENG", "passportNumber": "E12345678"}
        ```
        """
        let fields = MLXMatcher.parseFields(from: content)
        XCTAssertEqual(fields.value(for: .fullName), "LI YUANFENG")
        XCTAssertEqual(fields.value(for: .passportNumber), "E12345678")
    }

    func testParseJSONWithProse() {
        // Small models sometimes wrap JSON in chatter — the {...} span wins.
        let content = """
        Here are the extracted fields:
        {"fullName":"LI YUANFENG"} hope that helps!
        """
        let fields = MLXMatcher.parseFields(from: content)
        XCTAssertEqual(fields.value(for: .fullName), "LI YUANFENG")
        XCTAssertEqual(fields.count, 1)
    }

    func testParseGarbageYieldsNothing() {
        XCTAssertTrue(MLXMatcher.parseFields(from: "not json at all").isEmpty)
        XCTAssertTrue(MLXMatcher.parseFields(from: "").isEmpty)
    }

    func testEmptyValuesDropped() {
        // The prompt demands "" for unreadable — those must not become fields.
        let json = """
        {"fullName":"LI YUANFENG","passportNumber":"","placeOfBirth":"   "}
        """
        let fields = MLXMatcher.parseFields(from: json)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.value(for: .fullName), "LI YUANFENG")
    }

    // MARK: Registry resolution

    func testRegistryPreferenceOrder() {
        // Nothing downloaded → first entry in preference order is the fallback.
        let none = { (id: String) -> Bool in false }
        XCTAssertEqual(MatcherModelInfo.preferred(available: none)?.id, "gemma-3n-e2b")

        // E2B available → E2B.
        let e2bOnly = { (id: String) -> Bool in id == "gemma-3n-e2b" }
        XCTAssertEqual(MatcherModelInfo.preferred(available: e2bOnly)?.id, "gemma-3n-e2b")

        // Only E4B → E4B.
        let e4bOnly = { (id: String) -> Bool in id == "gemma-3n-e4b" }
        XCTAssertEqual(MatcherModelInfo.preferred(available: e4bOnly)?.id, "gemma-3n-e4b")
    }

    func testExplicitSelectionWins() {
        // User picks E4B while E2B is also available → E4B resolves.
        MatcherSettings.selectedID = "gemma-3n-e4b"
        let any = { (id: String) -> Bool in
            id == "gemma-3n-e2b" || id == "gemma-3n-e4b"
        }
        // resolveEngine consults availability; E4B is a needsDownload model so
        // the filesystem check applies — with isDownloaded=true it must win.
        let engine = MatcherSettings.resolveEngine(isDownloaded: any)
        XCTAssertEqual(engine?.id, "gemma-3n-e4b")
        MatcherSettings.selectedID = nil
    }

    func testUnavailableSelectionFallsBack() {
        // User selection unavailable (Apple FM on simulator) → preference chain.
        MatcherSettings.selectedID = "apple-fm"
        let e2b = { (id: String) -> Bool in id == "gemma-3n-e2b" }
        let engine = MatcherSettings.resolveEngine(isDownloaded: e2b)
        XCTAssertEqual(engine?.id, "gemma-3n-e2b")
        MatcherSettings.selectedID = nil
    }
}

private extension Array where Element == ExtractedField {
    func value(for key: IdentityFieldKey) -> String? {
        first(where: { $0.key == key })?.value
    }
}
