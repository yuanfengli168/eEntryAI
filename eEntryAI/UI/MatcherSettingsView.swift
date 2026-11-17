// MARK: - Field matcher settings page (fully decoupled: renders from registry)
// User picks the extraction model; download/delete/test per model.
// Adding a model = one MatcherModelInfo entry — this page adapts automatically.

import SwiftUI

struct MatcherSettingsView: View {
    @StateObject private var downloads = ModelDownloadManager.shared
    @State private var selectedID: String? = MatcherSettings.selectedID
    @State private var testResults: [String: String] = [:]      // modelID → test outcome

    var body: some View {
        List {
            Section {
                ForEach(MatcherModelInfo.all) { info in
                    row(info)
                }
            } header: {
                Text("Extraction model")
            } footer: {
                Text("The chosen model maps OCR text to passport fields. Everything runs on this device — passport data never leaves your iPhone.")
            }
        }
        .navigationTitle("Field Matching")
        .onAppear {
            if selectedID == nil {
                selectedID = MatcherModelInfo.preferred { id in
                    guard let engine = MatcherModelInfo.makeEngine(id: id) else { return false }
                    if case .ready = engine.availability { return true }
                    return false
                }?.id
            }
        }
    }

    @ViewBuilder
    private func row(_ info: MatcherModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    MatcherSettings.selectedID = info.id
                    selectedID = info.id
                } label: {
                    HStack {
                        Image(systemName: selectedID == info.id
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedID == info.id ? .green : .secondary)
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(info.displayName).bold()
                                if info.isDefault {
                                    Text("default").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            Text(subtitle(info)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                statusChip(info)
            }

            if case .needsDownload(let sizeMB) = engineAvailability(info) {
                if downloads.isDownloaded(info) {
                    Button("Delete downloaded files", role: .destructive) {
                        downloads.delete(info)
                    }
                    .font(.caption)
                } else if let p = downloads.progress[info.id], p < 1 {
                    ProgressView(value: p)
                } else {
                    Button("Download (\(sizeMB) MB)") {
                        downloads.download(info)
                    }
                    .font(.caption)
                }
            }

            if let result = testResults[info.id] {
                Text(result)
                    .font(.caption.monospaced())
                    .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Status + actions

    private func subtitle(_ info: MatcherModelInfo) -> String {
        switch info.id {
        case MatcherModelInfo.appleFM.id: return "Built into iOS · schema-forced JSON"
        case MatcherModelInfo.gemmaE2B.id: return "MLX · Gemma 3n E2B · on-device"
        case MatcherModelInfo.gemmaE4B.id: return "MLX · Gemma 3n E4B · on-device"
        default: return "On-device"
        }
    }

    private func engineAvailability(_ info: MatcherModelInfo) -> MatcherAvailability {
        MatcherModelInfo.makeEngine(id: info.id)?.availability
            ?? .unavailable(reason: "Engine not registered")
    }

    @ViewBuilder
    private func statusChip(_ info: MatcherModelInfo) -> some View {
        switch engineAvailability(info) {
        case .ready:
            Button("Test") { runTest(info) }
                .font(.caption).buttonStyle(.bordered)
        case .needsDownload(let sizeMB):
            Text(downloads.isDownloaded(info) ? "Ready" : "\(sizeMB) MB")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).font(.caption2).foregroundStyle(.red)
        }
    }

    // MARK: Test extraction (synthetic fixture — no real data)

    private func runTest(_ info: MatcherModelInfo) {
        guard let engine = MatcherModelInfo.makeEngine(id: info.id) else {
            testResults[info.id] = "✗ no engine registered"
            return
        }
        switch engine.availability {
        case .ready: break
        case .needsDownload: testResults[info.id] = "✗ download first"; return
        case .unavailable(let reason): testResults[info.id] = "✗ \(reason)"; return
        }
        Task {
            do {
                let fields = try await engine.extract(ocrText: Self.syntheticOCR)
                let names = fields.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
                testResults[info.id] = "✓ \(fields.count) fields: \(names)"
            } catch {
                testResults[info.id] = "✗ \(error.localizedDescription)"
            }
        }
    }

    /// Synthetic bio-page OCR fixture (specimen values — no real personal data).
    static let syntheticOCR = """
    PEOPLE'S REPUBLIC OF CHINA — PASSPORT
    Type/Code: P / CHN
    Passport No. E12345678
    Name LI/YUANFENG
    Nationality CHINESE
    Date of birth 26 MAR 1994
    Place of Birth BEIJING
    Date of expiry 29 DEC 2030
    Sex M
    P<CHN<LI<<YUANFENG<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    """
}
