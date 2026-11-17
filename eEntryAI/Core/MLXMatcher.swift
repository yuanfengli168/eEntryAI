// MARK: - MLX matcher (Gemma 3n E2B / E4B via registry config)
// On-demand downloaded GGUF/MLX weights from Hugging Face; runs via mlx-swift.
// NOTE: engine loads lazily at first extraction; download is managed by
// ModelDownloadManager (B/C phase). This file is the inference + JSON glue.

import Foundation

struct MLXMatcher: FieldMatcherEngine {
    let id: String
    let modelInfo: MatcherModelInfo

    init(modelInfo: MatcherModelInfo) {
        self.modelInfo = modelInfo
        self.id = modelInfo.id
    }

    var availability: MatcherAvailability {
        // Filesystem check — model weights on disk = ready.
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Models/\(modelInfo.id)")
        let hasConfig = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path
        )
        return hasConfig ? .ready : .needsDownload(sizeMB: modelInfo.sizeMB)
    }

    func extract(ocrText: String) async throws -> [ExtractedField] {
        // MLX inference integration lands with the mlx-swift package (phase C).
        // Until then: explicit failure so callers fall back to deterministic parsers.
        throw MatcherError.engineNotReady(id)
    }
}

enum MatcherError: Error, LocalizedError {
    case engineNotReady(String)

    var errorDescription: String? {
        switch self {
        case .engineNotReady(let id): return "Matcher '\(id)' is not ready yet (download/inference pending)"
        }
    }
}
