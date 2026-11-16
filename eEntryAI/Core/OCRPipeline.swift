// MARK: - On-device OCR pipeline (Vault V-3)
// Image → Vision text recognition → MRZParser. NO network calls anywhere:
// the image bytes never leave the app process. Deterministic parse follows OCR.

import Foundation
import Vision
import UIKit

enum OCRPipeline {
    enum OCRResult {
        case mrzFound(fields: [ExtractedField], warnings: [String])
        case noMRZ(text: String)     // OCR worked but no MRZ lines — let user type
        case ocrFailed
    }

    /// Recognizes text in the image and attempts MRZ parse. On the simulator
    /// this uses CPU; on device it runs on the Neural Engine. Either way:
    /// same process, zero network.
    static func process(image: UIImage) async -> OCRResult {
        guard let cgImage = image.cgImage else { return .ocrFailed }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false          // MRZ is charset-fixed; correction hurts

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return .ocrFailed
        }

        let lines = (request.results ?? []).compactMap { observation -> String? in
            observation.topCandidates(1).first?.string
        }
        let rawText = lines.joined(separator: "\n")

        switch MRZParser.parse(rawText: rawText) {
        case .success(let fields, let warnings):
            return .mrzFound(fields: fields, warnings: warnings)
        case .failure:
            return .noMRZ(text: rawText)
        }
    }

    // MARK: Synthetic MRZ image (test-only + verification)

    /// Renders a synthetic passport MRZ strip for pipeline verification —
    /// contains NO real personal data. Deterministic: same inputs → same image.
    static func renderSyntheticMRZ(line1: String, line2: String) -> UIImage {
        let size = CGSize(width: 1000, height: 260)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // MRZ uses OCR-B; monospace fallback is fine for recognition.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            let l1 = NSAttributedString(string: line1, attributes: attrs)
            let l2 = NSAttributedString(string: line2, attributes: attrs)
            l1.draw(at: CGPoint(x: 30, y: 40))
            l2.draw(at: CGPoint(x: 30, y: 130))
        }
    }
}
