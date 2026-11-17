// MARK: - MLX matcher (Gemma 3n E2B / E4B via registry config)
// Real on-device inference via the vendored MLXLLM package. Loads lazily,
// caches the model container; extraction = one chat completion with a
// strict JSON prompt. Runs on the simulator (CPU) and device (ANE/Metal).

import Foundation
import MLXLLM
import MLXLMCommon

struct MLXMatcher: FieldMatcherEngine {
    let id: String
    let modelInfo: MatcherModelInfo

    init(modelInfo: MatcherModelInfo) {
        self.modelInfo = modelInfo
        self.id = modelInfo.id
    }

    var availability: MatcherAvailability {
        // Filesystem check — model weights on disk = ready.
        let dir = MatcherModelPaths.directory(for: modelInfo)
        let hasConfig = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path
        )
        return hasConfig ? .ready : .needsDownload(sizeMB: modelInfo.sizeMB)
    }

    func extract(ocrText: String) async throws -> [ExtractedField] {
        let dir = MatcherModelPaths.directory(for: modelInfo)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path
        ) else {
            throw MatcherError.engineNotReady(id)
        }

        let container = try await MatcherModelRegistry.loadLocal(
            modelInfo: modelInfo, directory: dir
        )
        let session = ChatSession(
            container,
            instructions: Self.systemPrompt,
            generateParameters: GenerateParameters(temperature: 0)
        )
        let content = try await session.respond(to: Self.userPrompt(ocrText))
        return Self.parseFields(from: content)
    }

    // MARK: Prompting

    static let systemPrompt = """
    You extract identity fields from OCR text of a passport bio page.
    Return ONLY a JSON object with exactly these keys:
    "fullName", "passportNumber", "nationality", "dateOfBirth", "sex",
    "expiryDate", "issuingCountry", "placeOfBirth".
    Rules: copy values EXACTLY as printed (uppercase); dates as YYYY-MM-DD;
    nationality and issuingCountry as ISO 3-letter codes; sex as MALE/FEMALE/OTHERS;
    use "" for any field you cannot clearly read. No explanations, JSON only.
    """

    static func userPrompt(_ ocrText: String) -> String {
        """
        Extract the passport fields from this OCR text:

        \(ocrText)
        """
    }

    // MARK: JSON parsing (tolerant: strips ```json fences etc.)

    static func parseFields(from content: String) -> [ExtractedField] {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: first {...} span if the model added prose.
        if !text.hasPrefix("{"),
           let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [] }

        var fields: [ExtractedField] = []
        func add(_ key: IdentityFieldKey, _ raw: String, conf: Double = 0.7) {
            let v = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !v.isEmpty else { return }
            fields.append(ExtractedField(key: key, value: v, confidence: conf))
        }
        add(.fullName, obj["fullName"] ?? "")
        add(.passportNumber, obj["passportNumber"] ?? "")
        add(.nationality, obj["nationality"] ?? "")
        add(.dateOfBirth, obj["dateOfBirth"] ?? "")
        add(.sex, obj["sex"] ?? "")
        add(.expiryDate, obj["expiryDate"] ?? "")
        add(.issuingCountry, obj["issuingCountry"] ?? "")
        add(.placeOfBirth, obj["placeOfBirth"] ?? "")
        return fields
    }
}

// MARK: - Local model paths (no MainActor dependency)

enum MatcherModelPaths {
    static func directory(for info: MatcherModelInfo) -> URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Models/\(info.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Model container registry (one loaded model at a time)

@MainActor
enum MatcherModelRegistry {
    private static var loadedID: String?
    private static var loadedContainer: ModelContainer?

    /// Loads (or reuses) a downloaded local model directory.
    static func loadLocal(modelInfo: MatcherModelInfo, directory: URL) async throws -> ModelContainer {
        if let container = loadedContainer, loadedID == modelInfo.id {
            return container
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: directory)
        )
        loadedContainer = container
        loadedID = modelInfo.id
        return container
    }
}
