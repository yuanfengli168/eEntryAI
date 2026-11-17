// MARK: - Apple Foundation Models matcher (Guided Generation)
// Schema-forced JSON extraction. Requires Apple Intelligence hardware —
// unavailable on the simulator; test on real iPhone 17 Pro Max.

import Foundation
import FoundationModels

/// Schema for guided generation — must be a top-level type (macro limitation).
@Generable
struct PassportFieldsSchema {
    @Guide(description: "Full name as printed, uppercase. Empty string if unreadable.")
    var fullName: String
    @Guide(description: "Passport number, letters+digits. Empty string if unreadable.")
    var passportNumber: String
    @Guide(description: "Nationality ISO 3-letter code (e.g. CHN). Empty string if unreadable.")
    var nationality: String
    @Guide(description: "Date of birth, ISO format YYYY-MM-DD. Empty string if unreadable.")
    var dateOfBirth: String
    @Guide(description: "Sex: MALE, FEMALE, or OTHERS. Empty string if unreadable.")
    var sex: String
    @Guide(description: "Passport expiry date, ISO format YYYY-MM-DD. Empty string if unreadable.")
    var expiryDate: String
    @Guide(description: "Issuing country ISO 3-letter code. Empty string if unreadable.")
    var issuingCountry: String
    @Guide(description: "Place of birth as printed. Empty string if unreadable.")
    var placeOfBirth: String
}

/// SystemLanguageModel wrapper: maps OCR text → IdentityFieldKey fields.
struct AppleFMMatcher: FieldMatcherEngine {
    let id = MatcherModelInfo.appleFM.id

    var availability: MatcherAvailability {
        let model = SystemLanguageModel()
        switch model.availability {
        case .available: return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable(reason: "Apple Intelligence not enabled")
            case .deviceNotEligible: return .unavailable(reason: "Device not eligible")
            case .modelNotReady: return .unavailable(reason: "Model still downloading")
            @unknown default: return .unavailable(reason: "Unknown availability state")
            }
        }
    }

    func extract(ocrText: String) async throws -> [ExtractedField] {
        let model = SystemLanguageModel()
        guard case .available = model.availability else {
            throw MatcherError.engineNotReady(id)
        }
        let session = LanguageModelSession(model: model)

        let prompt = """
        You extract identity fields from OCR text of a passport bio page.
        Copy values EXACTLY as printed — do not invent or correct anything.
        Use empty string for any field you cannot clearly read.
        OCR text follows:

        \(ocrText)
        """
        let response: LanguageModelSession.Response<PassportFieldsSchema> = try await session.respond(
            to: prompt, generating: PassportFieldsSchema.self
        )
        let result = response.content

        var fields: [ExtractedField] = []
        func add(_ key: IdentityFieldKey, _ value: String, conf: Double = 0.7) {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return }
            fields.append(ExtractedField(key: key, value: v.uppercased(), confidence: conf))
        }
        add(.fullName, result.fullName)
        add(.passportNumber, result.passportNumber)
        add(.nationality, result.nationality)
        add(.dateOfBirth, result.dateOfBirth)
        add(.sex, result.sex)
        add(.expiryDate, result.expiryDate)
        add(.issuingCountry, result.issuingCountry)
        add(.placeOfBirth, result.placeOfBirth)
        return fields
    }
}
