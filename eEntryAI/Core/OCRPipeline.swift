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

    /// Recognizes text in the image and attempts MRZ parse. Two recognition
    /// passes: .accurate first, then .fast (different line segmentation often
    /// rescues angled/laminated MRZs). Still fully on-device.
    /// Falls back to the visual-zone parser when the MRZ is unreadable.
    static func process(image: UIImage) async -> OCRResult {
        guard let cgImage = image.cgImage else { return .ocrFailed }

        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let rawText = recognize(cgImage: cgImage, level: level)
            switch MRZParser.parse(rawText: rawText) {
            case .success(let fields, let warnings):
                // Full MRZ success — but merge in visual-zone extras (e.g. place
                // of birth, which the MRZ doesn't carry) if absent.
                var merged = fields
                let vz = VisualZoneParser.parse(rawText: rawText)
                for extra in vz where !fields.contains(where: { $0.key == extra.key }) {
                    merged.append(extra)
                }
                return .mrzFound(fields: merged, warnings: warnings)
            case .failure:
                continue
            }
            if level == .fast {
                // Both MRZ passes failed — try the printed fields.
                let text = recognize(cgImage: cgImage, level: .accurate)
                let vz = VisualZoneParser.parse(rawText: text)
                if !vz.isEmpty {
                    return .mrzFound(
                        fields: vz,
                        warnings: ["MRZ unreadable — extracted from printed fields. Please verify all values."]
                    )
                }
                return text.isEmpty ? .ocrFailed : .noMRZ(text: text)
            }
        }
        // accurate produced text but parse failed and fast produced nothing useful:
        let text = recognize(cgImage: cgImage, level: .accurate)
        return text.isEmpty ? .ocrFailed : .noMRZ(text: text)
    }

    private static func recognize(cgImage: CGImage, level: VNRequestTextRecognitionLevel) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false          // MRZ charset is fixed
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { obs in
            obs.topCandidates(1).first?.string
        }.joined(separator: "\n")
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
