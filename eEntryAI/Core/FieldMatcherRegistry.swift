// MARK: - Field matcher engine registry (Vault §10 / Architecture AIEngine)
// Decoupled: settings page renders from this registry; adding a model is one entry.
// Priority order = user's default preference chain:
//   Gemma E2B (default) > Gemma E4B > Apple FM > Qwen (reserved slot)

import Foundation

// MARK: Protocol every matcher implements

/// Maps raw OCR text → identity fields. Runs fully on-device.
protocol FieldMatcherEngine {
    /// Stable identifier (registry key).
    var id: String { get }
    /// Extracts fields from OCR text. JSON-schema-shaped output.
    func extract(ocrText: String) async throws -> [ExtractedField]
    /// Free-form availability state for the settings UI.
    var availability: MatcherAvailability { get }
}

enum MatcherAvailability: Equatable {
    case ready
    case needsDownload(sizeMB: Int)
    case unavailable(reason: String)
}

enum MatcherError: Error, LocalizedError {
    case engineNotReady(String)

    var errorDescription: String? {
        switch self {
        case .engineNotReady(let id): return "Matcher '\(id)' is not ready (download or availability pending)"
        }
    }
}

// MARK: Registry entry (pure config — no imports of engines)

struct MatcherModelInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let sizeMB: Int
    /// Hugging Face repo for on-demand download (nil = built into the OS).
    let hfRepo: String?
    let isDefault: Bool

    /// Factory resolves the engine for a downloaded/ready model.
    static func makeEngine(id: String) -> FieldMatcherEngine? {
        switch id {
        case MatcherModelInfo.appleFM.id: return AppleFMMatcher()
        case MatcherModelInfo.gemmaE2B.id: return MLXMatcher(modelInfo: MatcherModelInfo.gemmaE2B)
        case MatcherModelInfo.gemmaE4B.id: return MLXMatcher(modelInfo: MatcherModelInfo.gemmaE4B)
        default: return nil
        }
    }

    // MARK: The registry (order = preference chain)

    static let gemmaE2B = MatcherModelInfo(
        id: "gemma-3n-e2b", displayName: "Gemma 3n E2B", sizeMB: 1300,
        hfRepo: "mlx-community/gemma-3n-E2B-it-4bit", isDefault: true
    )
    static let gemmaE4B = MatcherModelInfo(
        id: "gemma-3n-e4b", displayName: "Gemma 3n E4B", sizeMB: 2400,
        hfRepo: "mlx-community/gemma-3n-E4B-it-4bit", isDefault: false
    )
    static let appleFM = MatcherModelInfo(
        id: "apple-fm", displayName: "Apple Foundation Models", sizeMB: 0,
        hfRepo: nil, isDefault: false
    )
    // RESERVED (future): qwen3-4b — add one entry + one factory case.

    static let all: [MatcherModelInfo] = [gemmaE2B, gemmaE4B, appleFM]

    /// First ready model in preference order (used when no explicit selection).
    static func preferred(available: (String) -> Bool) -> MatcherModelInfo? {
        all.first { available($0.id) } ?? all.first
    }
}

// MARK: Selection persistence ( UserDefaults — not secret material)

enum MatcherSettings {
    private static let key = "fieldMatcher.selectedModel"

    static var selectedID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Resolve the engine: explicit selection wins; else preference chain.
    static func resolveEngine(isDownloaded: (String) -> Bool) -> FieldMatcherEngine? {
        let available = { id -> Bool in
            guard let engine = MatcherModelInfo.makeEngine(id: id) else { return false }
            switch engine.availability {
            case .ready: return true
            case .needsDownload: return isDownloaded(id)
            case .unavailable: return false
            }
        }
        if let selected = selectedID,
           let engine = MatcherModelInfo.makeEngine(id: selected) {
            switch engine.availability {
            case .ready: return engine
            case .needsDownload(let size):
                return isDownloaded(selected) ? engine
                    : MatcherModelInfo.makeEngine(id: MatcherModelInfo.preferred(available: available)?.id ?? "")
            case .unavailable: break     // fall through to preference chain
            }
        }
        return MatcherModelInfo.makeEngine(id: MatcherModelInfo.preferred(available: available)?.id ?? "")
    }
}
