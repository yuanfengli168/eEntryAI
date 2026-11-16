// MARK: - Add document flow (scan / upload / manual) → card save
// doc/Vault.md §2: all three paths converge on one VaultDocument.

import SwiftUI
import PhotosUI
import UIKit

extension AddDocumentSource {
    var sheetSource: AddDocumentSheet.Source {
        switch self {
        case .scan: return .scan
        case .upload: return .upload
        case .manual: return .manual
        }
    }
}

struct AddDocumentSheet: View {
    enum Source: String, Identifiable {
        case scan, upload, manual
        var id: String { rawValue }
    }
    let vault: VaultStore
    let personID: UUID
    let source: Source

    @Environment(\.dismiss) private var dismiss
    @State private var pickedImage: UIImage?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var extracted: [ExtractedField] = []
    @State private var warnings: [String] = []
    @State private var parseFailed = false
    @State private var showManualFields = false
    /// Test/diagnostic: raw OCR text (field values only, never the image).
    @State private var ocrDebugText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                switch source {
                case .upload:
                    Section("Passport photo (bio page)") {
                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            Label(pickedImage == nil ? "Choose photo" : "Change photo",
                                  systemImage: "photo")
                        }
                        if let img = pickedImage {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    resultSection

                case .scan:
                    Section {
                        // Camera capture runs through the same OCR path; on the
                        // simulator the camera isn't available, so offer photo fallback.
                        Label("Camera capture (device only)", systemImage: "camera")
                            .foregroundStyle(.secondary)
                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            Label("Pick a photo instead", systemImage: "photo")
                        }
                        if let img = pickedImage {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    resultSection

                case .manual:
                    manualSection
                }
            }
            .navigationTitle("Add document")
            .onChange(of: photoPickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pickedImage = image
                        switch await OCRPipeline.process(image: image) {
                        case .mrzFound(let fields, let warns):
                            extracted = fields
                            warnings = warns
                            parseFailed = false
                            ocrDebugText = ""
                        case .noMRZ(let text):
                            extracted = []
                            warnings = []
                            parseFailed = true
                            ocrDebugText = text
                        case .ocrFailed:
                            extracted = []
                            warnings = ["OCR failed — try again or type manually"]
                            parseFailed = true
                            ocrDebugText = ""
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(extracted.isEmpty && !showManualFields)
                }
            }
        }
    }

    // MARK: Result section (OCR paths)

    @ViewBuilder
    private var resultSection: some View {
        if !extracted.isEmpty {
            Section("Extracted (tap any value to correct)") {
                ForEach(extracted) { field in
                    ExtractedRow(field: field) { newValue in
                        updateField(field.key, newValue: newValue)
                    }
                }
            }
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } else if parseFailed {
            Section {
                Label("Couldn't read the MRZ. Try a closer, straight-on crop of the two MRZ lines at the bottom of the photo page, or type it in.",
                      systemImage: "xmark.octagon")
                    .foregroundStyle(.orange)
                Button("Type manually instead") {
                    showManualFields = true
                }
            }
            if !ocrDebugText.isEmpty {
                Section("OCR debug (what Vision read)") {
                    Text(ocrDebugText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if showManualFields { manualSection }
        }
    }

    // MARK: Manual section

    @ViewBuilder
    private var manualSection: some View {
        Section("Passport details") {
            ForEach(IdentityFieldKey.allCases) { key in
                manualRow(key)
            }        }
    }

    @ViewBuilder
    private func manualRow(_ key: IdentityFieldKey) -> some View {
        let value = binding(for: key)
        VStack(alignment: .leading, spacing: 4) {
            Text(label(for: key)).font(.subheadline.weight(.medium))
            TextField(placeholder(for: key), text: value)
                .textInputAutocapitalization(.characters)
        }
    }

    private func binding(for key: IdentityFieldKey) -> Binding<String> {
        Binding(
            get: { extracted.first(where: { $0.key == key })?.value ?? "" },
            set: { updateField(key, newValue: $0) }
        )
    }

    private func updateField(_ key: IdentityFieldKey, newValue: String) {
        if let idx = extracted.firstIndex(where: { $0.key == key }) {
            extracted[idx].value = newValue
            extracted[idx].confidence = ExtractedField.manualConfidence      // user-typed = truth
        } else {
            extracted.append(ExtractedField(key: key, value: newValue, confidence: ExtractedField.manualConfidence))
        }
    }

    private func label(for key: IdentityFieldKey) -> String {
        switch key {
        case .fullName: return "Full name (Given Surname)"
        case .passportNumber: return "Passport number"
        case .nationality: return "Nationality (ISO 3-letter)"
        case .dateOfBirth: return "Date of birth (YYYY-MM-DD)"
        case .sex: return "Sex (MALE/FEMALE/OTHERS)"
        case .expiryDate: return "Expiry (YYYY-MM-DD)"
        case .issuingCountry: return "Issuing country (ISO 3-letter)"
        case .placeOfBirth: return "Place of birth"
        }
    }

    private func placeholder(for key: IdentityFieldKey) -> String {
        switch key {
        case .fullName: return "SPECIMEN EXAMPLE"
        case .passportNumber: return "HA672249"
        case .nationality: return "NLD"
        case .dateOfBirth: return "1968-08-14"
        case .sex: return "FEMALE"
        case .expiryDate: return "2025-08-18"
        case .issuingCountry: return "NLD"
        case .placeOfBirth: return "BEIJING"
        }
    }

    // MARK: Save

    private func save() {
        var doc = VaultDocument(personID: personID, source: source == .manual ? .manual : .upload)
        doc.extracted = extracted
        do {
            if let image = pickedImage, let jpeg = image.jpegData(compressionQuality: 0.85) {
                try vault.addDocument(doc, image: jpeg)
            } else {
                try vault.addDocument(doc)
            }
            dismiss()
        } catch {
            warnings.append("Save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Single extracted row

struct ExtractedRow: View {
    let field: ExtractedField
    var onEdit: (String) -> Void

    @State private var draft: String

    init(field: ExtractedField, onEdit: @escaping (String) -> Void) {
        self.field = field
        self.onEdit = onEdit
        _draft = State(initialValue: field.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(labelFor(field.key)).font(.subheadline.weight(.medium))
            TextField("", text: $draft, onCommit: { onEdit(draft) })
                .textInputAutocapitalization(.characters)
                .underline(color: field.isLowConfidence ? Color.orange : Color.clear)
            if field.isLowConfidence {
                Text("Low confidence — please verify")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func labelFor(_ key: IdentityFieldKey) -> String {
        switch key {
        case .fullName: return "Full name"
        case .passportNumber: return "Passport number"
        case .nationality: return "Nationality"
        case .dateOfBirth: return "Date of birth"
        case .sex: return "Sex"
        case .expiryDate: return "Expiry"
        case .issuingCountry: return "Issuing country"
        case .placeOfBirth: return "Place of birth"
        }
    }
}
