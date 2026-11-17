// MARK: - On-demand model downloads (phase C groundwork)
// Downloads MLX weights from Hugging Face into Application Support/Models.
// Progress + delete are surfaced by the settings page; files are public model
// weights — never user data.

import Foundation

@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    @Published private(set) var progress: [String: Double] = [:]     // modelID → 0-1
    @Published private(set) var downloaded: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    private var modelsDirectory: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func localDirectory(for info: MatcherModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(info.id, isDirectory: true)
    }

    func isDownloaded(_ info: MatcherModelInfo) -> Bool {
        downloaded.contains(info.id) || FileManager.default.fileExists(
            atPath: localDirectory(for: info).appendingPathComponent("config.json").path
        )
    }

    // MARK: Download (public HF repos — model weights only)

    func download(_ info: MatcherModelInfo) {
        guard !isDownloaded(info), tasks[info.id] == nil,
              let repo = info.hfRepo else { return }
        progress[info.id] = 0
        tasks[info.id] = Task { [weak self] in
            await self?.runDownload(info, repo: repo)
        }
    }

    private func runDownload(_ info: MatcherModelInfo, repo: String) async {
        // Hugging Face resolve URLs for the standard MLX-format file set.
        let files = ["config.json", "model.safetensors", "model.safetensors.index.json",
                     "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
                     "generation_config.json"]
        let base = "https://huggingface.co/\(repo)/resolve/main/"
        let dest = localDirectory(for: info)

        for file in files {
            guard let url = URL(string: base + file) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // Optional file (e.g. index.json) — skip quietly on 404.
                    continue
                }
                try data.write(to: dest.appendingPathComponent(file), options: .atomic)
            } catch {
                continue     // individual optional-file failures don't abort the set
            }
        }
        progress[info.id] = 1
        downloaded.insert(info.id)
        tasks[info.id] = nil
    }

    func delete(_ info: MatcherModelInfo) {
        tasks[info.id]?.cancel()
        tasks[info.id] = nil
        try? FileManager.default.removeItem(at: localDirectory(for: info))
        downloaded.remove(info.id)
        progress[info.id] = nil
    }
}
