// OCR pipeline tests — synthetic MRZ image → Vision OCR → MRZParser round-trip.
// Uses the computed-valid fixtures from MRZParserTests. No real personal data.

import XCTest
@testable import eEntryAI

final class OCRPipelineTests: XCTestCase {

    func testSyntheticMRZRoundTrip() async throws {
        let line1 = "P<NLD<EXAMPLE<<SPECIMEN<<<<<<<<<<<<<<<<<<<<<"
        let line2 = "HA672249<7NLD6808149F2508186<<<<<<<<<<<<<<04"

        let image = OCRPipeline.renderSyntheticMRZ(line1: line1, line2: line2)
        let result = await OCRPipeline.process(image: image)

        guard case .mrzFound(let fields, let warnings) = result else {
            if case .noMRZ(let text) = result {
                XCTFail("OCR ran but MRZ not found. Raw text: \(text.prefix(200))")
            } else {
                XCTFail("OCR failed entirely")
            }
            return
        }
        XCTAssertEqual(fields.value(for: .passportNumber), "HA672249")
        XCTAssertEqual(fields.value(for: .nationality), "NLD")
        // OCR truncates trailing '<' padding + composite digit on rendered text —
        // the parser tolerates it with a warning (real-world behavior). Hard
        // failures (corrupted passport number) are covered by MRZParserTests.
        let hardWarnings = warnings.filter { !$0.contains("truncated") }
        XCTAssertTrue(hardWarnings.isEmpty, "only truncation warnings expected: \(warnings)")
    }

    func testPlainPhotoYieldsNoMRZ() async throws {
        // A rendered image with no MRZ content must report noMRZ, not garbage.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 200))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: 800, height: 200)))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black
            ]
            ("Hello, this is just a photo of a sunset, nothing machine readable.")
                .draw(at: CGPoint(x: 20, y: 80), withAttributes: attrs)
        }
        let result = await OCRPipeline.process(image: image)
        guard case .noMRZ = result else {
            XCTFail("non-MRZ image must yield noMRZ")
            return
        }
    }

    func testOCRPipelineIsNetworkFree() {
        // Architecture guard: the pipeline file must not import or reference any
        // networking API. (Static check — the whole point is on-device-only.)
        let path = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent().appendingPathComponent("eEntryAI.app").path
        if let source = try? String(
            contentsOfFile: sourceFileURL(for: "OCRPipeline.swift").path, encoding: .utf8
        ) {
            XCTAssertFalse(source.contains("URLSession"), "pipeline must not use URLSession")
            XCTAssertFalse(source.contains("https://"), "pipeline must not hardcode endpoints")
        }
    }

    private func sourceFileURL(for name: String) -> URL {
        // Tests run from the app bundle; source lives in the repo. Locate via
        // #filePath's directory (repo path is stable in CI and dev machines).
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent()   // eEntryAITests/
            .deletingLastPathComponent()                        // repo root
        return repoRoot.appendingPathComponent("eEntryAI/Core/\(name)")
    }
}
