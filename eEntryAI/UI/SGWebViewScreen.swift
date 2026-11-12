// MARK: - WebView screen (drawio embedded browser + fill flow)
// WKWebView + AutofillOrchestrator. User reviews page 3 and taps Submit themselves.

import SwiftUI
import WebKit

struct SGWebViewScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var log: [String] = []
    @State private var pageIdx = 0
    @State private var showLog = false

    enum Phase: Equatable {
        case loading, entry, filling, reviewWaiting, done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                WebViewContainer(model: model, phase: $phase, pageIdx: $pageIdx, log: appendLog)
            }
            .navigationTitle("SG Arrival Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            switch phase {
            case .loading: ProgressView(); Text("Loading portal…")
            case .entry: Text("Portal ready").foregroundStyle(.green)
            case .filling: ProgressView(); Text("Filling page \(pageIdx + 1)…")
            case .reviewWaiting: Text("Please review & submit yourself").foregroundStyle(.orange)
            case .done: Text("Submitted ✓").foregroundStyle(.green)
            case .failed(let msg): Text("Failed: \(msg)").foregroundStyle(.red)
            }
            Spacer()
            if !log.isEmpty {
                Button("Log (\(log.count))") { showLog = true }
            }
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showLog) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
    }
    private func appendLog(_ line: String) {
        log.append(line)
        // Test-only: mirror log to Application Support so automated runs can read it from the host.
        if ProcessInfo.processInfo.arguments.contains("-uitest-autoopen") {
            if let dir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ) {
                let url = dir.appendingPathComponent("autofill_log.txt")
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @Binding var phase: SGWebViewScreen.Phase
    @Binding var pageIdx: Int
    var log: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Present a desktop browser: the portal's Material autocomplete panel only
        // opens in the desktop web variant (verified against the live site).
        // Automation targets the desktop DOM; the user still sees and reviews everything.
        config.applicationNameForUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        context.coordinator.setup(webView: web, model: model)
        if let url = URL(string: "https://eservices.ica.gov.sg/arrivalcard") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewContainer
        private let orchestrator = AutofillOrchestrator()
        private var pack: AdapterPack?
        private weak var webView: WKWebView?
        private var started = false

        init(parent: WebViewContainer) { self.parent = parent }

        func setup(webView: WKWebView, model: AppModel) {
            self.webView = webView
            do {
                pack = try SGCountryAdapter().loadPack()
                parent.log("Pack loaded: \(pack?.countryName ?? "?") v\(pack?.packVersion ?? 0)")
            } catch {
                parent.log("PACK ERROR: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !started else { return }
            started = true
            started = true
            Task { @MainActor in
                parent.phase = .entry
                parent.log("Portal loaded. Pack: SG v\(pack?.packVersion ?? 0)")
                await runFlow()
            }
        }

        @MainActor
        private func runFlow() async {
            guard let pack, let webView else { return }

            // Step 0: dismiss "Help us improve" popup if present (blocks clicks).
            try? await Task.sleep(nanoseconds: 2_500_000_000)   // let landing page settle
            let dismissScript = """
            (function() {
              var btns = document.querySelectorAll('button');
              for (var i = 0; i < btns.length; i++) {
                if (window.__eEntryAI) {} // lib may not exist yet
                if ((btns[i].textContent || '').trim() === 'Dismiss') { btns[i].click(); return 'dismissed'; }
              }
              return 'no-popup';
            })()
            """
            let dismissResult = (try? await webView.evaluateJavaScript(dismissScript) as? String) ?? "?"
            parent.log("Popup: \(dismissResult)")

            // Step 1: entry — load JS lib, then click the VISITOR "Fill in Manually"
            // (the portal has two: resident first, visitor last — click all matches is
            // wrong; we click the LAST one, which is the visitor path per pack navigation).
            try? await AutomationJS.loadLibrary(into: webView)
            let entryScript = """
            (function() {
              var btns = document.querySelectorAll('button');
              var hit = null;
              for (var i = 0; i < btns.length; i++) {
                if (window.__eEntryAI.norm(btns[i].textContent).indexOf('FILL IN MANUALLY') !== -1) hit = btns[i];
              }
              if (hit) { hit.click(); return 'clicked'; }
              return 'not-found';
            })()
            """
            let entryResult = (try? await AutomationJS.run(entryScript, in: webView) as? String) ?? "?"
            parent.log("Entry click: \(entryResult)")
            // wait until the wizard tab-1 inputs exist (Angular router + render settle)
            var wizardReady = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let ready = (try? await webView.evaluateJavaScript(
                    "!!document.querySelector('input[aria-label=\"Passport Number\"]')"
                ) as? Bool) ?? false
                if ready { wizardReady = true; break }
            }
            parent.log("Wizard ready: \(wizardReady)")

            let resolver = FieldValueResolver(
                profile: parent.model.profile ?? Profile(),
                trip: parent.model.trip
            )

            // Step 2: fill pages 1..2 (page 3 = review)
            for (idx, page) in pack.pages.enumerated() {
                guard !page.fields.isEmpty else { continue }   // review page: skip
                parent.pageIdx = idx
                parent.phase = .filling
                // Wait for this page's first field to render before filling (Angular tab switch).
                if idx > 0 {
                    let firstFieldLabel = page.fields.first?.label ?? ""
                    var pageReady = false
                    for _ in 0..<16 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let ready = (try? await AutomationJS.run(
                            "pageHasTextbox(\(AutomationJS.js(firstFieldLabel))) || !!window.__eEntryAI.findRadiogroup(\(AutomationJS.js(firstFieldLabel))) || document.body.innerText.indexOf(\(AutomationJS.js(firstFieldLabel))) !== -1", in: webView
                        ) as? Bool) ?? false
                        if ready { pageReady = true; break }
                    }
                    parent.log("Page \(idx + 1) ready: \(pageReady)")
                }
                do {
                    let results = try await orchestrator.runPage(
                        pack: pack, page: page, resolver: resolver, webView: webView
                    )
                    for r in results {
                        if r.ok && r.error == "hidden (condition)" {
                            parent.log("\(r.key): – (hidden by condition)")
                        } else {
                            parent.log("\(r.key): \(r.ok ? "✓" : "✗ \(r.error ?? "")")")
                        }
                    }
                } catch {
                    parent.log("page \(idx) error: \(error)")
                }
                if idx < pack.pages.count - 1 {
                    await orchestrator.clickNext(pack: pack, webView: webView)
                    parent.log("→ next page")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }

            // Step 3: review reached — verify it rendered, then hand control to user.
            if await orchestrator.isReviewPage(pack: pack, webView: webView) {
                parent.phase = .reviewWaiting
                parent.log("Review page detected — your turn.")
            } else {
                parent.phase = .failed("review page not detected")
                parent.log("✗ review page NOT detected")
            }
        }
    }
}
