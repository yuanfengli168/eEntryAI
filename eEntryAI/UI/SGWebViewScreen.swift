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
    @State private var resumeRequested = false

    enum Phase: Equatable {
        case loading, entry, filling, reviewWaiting, done
        case needsYou([FailedField])
        case failed(String)
    }

    /// P1: one failed required field, shown in the needs-you list.
    struct FailedField: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let reason: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                WebViewContainer(model: model, phase: $phase, pageIdx: $pageIdx, resumeRequested: $resumeRequested, log: appendLog)
            }
            .navigationTitle("SG Arrival Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onChange(of: resumeRequested) { _ in }   // binding triggers updateUIView above
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch phase {
                case .loading: ProgressView(); Text("Loading portal…")
                case .entry: Text("Portal ready").foregroundStyle(.green)
                case .filling: ProgressView(); Text("Filling page \(pageIdx + 1)…")
                case .reviewWaiting: Text("Please review & submit yourself").foregroundStyle(.orange)
                case .done: Text("Submitted ✓").foregroundStyle(.green)
                case .needsYou(let failures):
                    Text("Needs you — \(failures.count) field\(failures.count == 1 ? "" : "s")")
                        .foregroundStyle(.orange).bold()
                    Spacer()
                    Button("Resume") { resumeRequested = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                case .failed(let msg): Text("Failed: \(msg)").foregroundStyle(.red)
                }
                if case .reviewWaiting = phase { Spacer() }
                if !log.isEmpty && !phase.isNeedsYou {
                    Button("Log (\(log.count))") { showLog = true }
                }
            }
            if case .needsYou(let failures) = phase {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fix these on the portal page, tap the portal's Next, then tap Resume:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(failures) { f in
                        Text("• \(f.label) — \(f.reason)")
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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

extension SGWebViewScreen.Phase {
    var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }
}

struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @Binding var phase: SGWebViewScreen.Phase
    @Binding var pageIdx: Int
    @Binding var resumeRequested: Bool
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

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // P2: Resume button → continue filling from the next page.
        if resumeRequested {
            resumeRequested = false
            Task { @MainActor in
                await context.coordinator.resumeFlow(webView: uiView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewContainer
        private let orchestrator = AutofillOrchestrator()
        private var pack: AdapterPack?
        private weak var webView: WKWebView?
        private var started = false
        /// P2: index of the last page we filled (or attempted) — resume continues after it.
        private var lastCompletedPage = -1

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

            // Step 2: fill pages, gated — stop (don't click Next) when a required
            // field failed. Resume continues from the next page index.
            await fillFrom(pageIndex: 0, pack: pack, resolver: resolver, webView: webView)
        }

        /// P1/P2: fills pages starting at `pageIndex` until a required field fails
        /// (→ needsYou) or the review page is reached (→ reviewWaiting).
        @MainActor
        private func fillFrom(
            pageIndex: Int, pack: AdapterPack,
            resolver: FieldValueResolver, webView: WKWebView
        ) async {
            lastCompletedPage = pageIndex - 1

            for (idx, page) in pack.pages.enumerated() where idx >= pageIndex {
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
                var results: [AutofillOrchestrator.FieldResult] = []
                do {
                    results = try await orchestrator.runPage(
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

                // P1 gate: a failed required field means the portal will refuse Next —
                // hand off instead of fighting the validator.
                let fieldByKey = Dictionary(page.fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                let failures = results
                    .filter { !$0.ok && $0.error != "hidden (condition)" }
                    .compactMap { r -> SGWebViewScreen.FailedField? in
                        guard let field = fieldByKey[r.key], field.required ?? true else { return nil }
                        return SGWebViewScreen.FailedField(label: field.label, reason: r.error ?? "unknown")
                    }
                if !failures.isEmpty {
                    lastCompletedPage = idx
                    parent.phase = .needsYou(failures)
                    parent.log("NEEDS-YOU (\(failures.count)): " + failures.map { $0.label }.joined(separator: ", "))

                    // Test-only: simulate the user's manual fix + portal Next tap so
                    // the resume path can be verified end-to-end on the simulator.
                    if ProcessInfo.processInfo.arguments.contains("-uitest-simulate-fix") {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        _ = await callUserFix(pack: pack, webView: webView)
                        await resumeFlow(webView: webView)
                    }
                    return   // user fixes on the portal; Resume continues from idx+1
                }

                if idx < pack.pages.count - 1 {
                    await orchestrator.clickNext(pack: pack, webView: webView)
                    parent.log("→ next page")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                lastCompletedPage = idx
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

        /// P2: user fixed the fields on the portal and advanced — continue from
        /// the page after the one where we stopped.
        @MainActor
        func resumeFlow(webView: WKWebView) async {
            guard let pack else { return }
            guard case .needsYou = parent.phase else { return }
            let nextPage = lastCompletedPage + 1
            parent.log("Resume: continuing from page \(nextPage + 1)")
            let resolver = FieldValueResolver(
                profile: parent.model.profile ?? Profile(),
                trip: parent.model.trip
            )
            await fillFrom(pageIndex: nextPage, pack: pack, resolver: resolver, webView: webView)
        }

        /// Test-only: plays the user's part — picks the right nationality through
        /// the real portal widgets, then taps the portal's own Next button.
        @MainActor
        private func callUserFix(pack: AdapterPack, webView: WKWebView) async {
            _ = try? await webView.evaluateJavaScript("""
            window.__eEntryAI.startComboboxSelect('Nationality/Citizenship', 'CHINESE');
            """)
            try? await Task.sleep(nanoseconds: 2_500_000_000)   // combobox sequence completes
            // Diagnostics: input value after the fix + which tab is active.
            let check = (try? await AutomationJS.run("""
            (function() {
              var inp = window.__eEntryAI.byAria('Nationality/Citizenship', ['input[aria-label="']);
              var cb = window.__cbResult;
              return JSON.stringify({ inputNow: inp ? inp.value : 'no-input', cbResult: cb });
            })()
            """, in: webView) as? String) ?? "?"
            parent.log("FIX-CHECK: \(check)")
            let nextScript = """
            (function() {
              var btns = document.querySelectorAll('button');
              var hit = null;
              for (var i = 0; i < btns.length; i++) {
                if (window.__eEntryAI.norm(btns[i].textContent).indexOf('NEXT') !== -1) hit = btns[i];
              }
              if (hit) { hit.click(); return 'user-clicked-next'; }
              return 'next-not-found';
            })()
            """
            let r = (try? await AutomationJS.run(nextScript, in: webView) as? String) ?? "?"
            parent.log("SIMULATED USER: \(r)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // Angular advances
        }
    }
}
