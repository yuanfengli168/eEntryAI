// MARK: - Vault domain model (doc/Vault.md §1)
// Person → documents → extracted fields. The vault is the source of truth for
// identity data; Profile becomes a projection (wired in V-4).

import Foundation

// MARK: Person

struct VaultPerson: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var displayName: String
    var isSelf: Bool = false          // the phone owner / vault custodian
    var documentIDs: [UUID] = []
}

// MARK: Document

enum DocumentType: String, Codable {
    case passport                      // v1; TD1 ID cards later
}

enum DocumentState: String, Codable {
    case valid, expiring, expired

    init(expiry: String, today: Date = Date()) {
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: expiry) else { self = .valid; return }
        let months = Calendar.current.dateComponents(
            [.month], from: today, to: date
        ).month ?? 0
        if date < today { self = .expired }
        else if months < 6 { self = .expiring }
        else { self = .valid }
    }
}

enum DocumentSource: String, Codable {
    case scan, upload, manual
}

struct VaultDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var personID: UUID
    var type: DocumentType = .passport
    var source: DocumentSource
    var createdAt: Date = Date()

    // Encrypted image file name inside the vault container (nil = manually typed, no photo).
    var imageFileName: String?

    // MRZ-derived (or manually entered) identity fields with confidence.
    var extracted: [ExtractedField] = []

    // Convenience projections over extracted fields.
    var passportNumber: String? { extracted.value(for: .passportNumber) }
    var fullName: String? { extracted.value(for: .fullName) }
    var nationality: String? { extracted.value(for: .nationality) }
    var dateOfBirth: String? { extracted.value(for: .dateOfBirth) }
    var sex: String? { extracted.value(for: .sex) }
    var expiryDate: String? { extracted.value(for: .expiryDate) }
    var issuingCountry: String? { extracted.value(for: .issuingCountry) }

    var state: DocumentState {
        DocumentState(expiry: expiryDate ?? "")
    }
}

// MARK: Extracted field

enum IdentityFieldKey: String, Codable, CaseIterable, Identifiable {
    case fullName, passportNumber, nationality, dateOfBirth, sex
    case expiryDate, issuingCountry, placeOfBirth
    var id: String { rawValue }

    /// Human label for the card back and forms.
    var displayLabel: String {
        switch self {
        case .fullName: return "Full name"
        case .passportNumber: return "Passport No."
        case .nationality: return "Nationality"
        case .dateOfBirth: return "Date of birth"
        case .sex: return "Sex"
        case .expiryDate: return "Expiry"
        case .issuingCountry: return "Issuing country"
        case .placeOfBirth: return "Place of birth"
        }
    }
}

struct ExtractedField: Codable, Equatable, Identifiable {
    var id: String { key.rawValue }
    let key: IdentityFieldKey
    var value: String
    /// 1.0 for manual entry; OCR confidences come from the MRZ parser.
    var confidence: Double

    static let manualConfidence: Double = 1.0
    static let lowConfidenceThreshold: Double = 0.8

    var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
}

extension Array where Element == ExtractedField {
    func value(for key: IdentityFieldKey) -> String? {
        first(where: { $0.key == key })?.value.nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Vault index (the decryptable manifest)

struct VaultIndex: Codable, Equatable {
    var schemaVersion: Int = 1
    var persons: [VaultPerson] = []
    var documents: [VaultDocument] = []
}
