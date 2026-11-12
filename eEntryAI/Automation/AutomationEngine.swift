// MARK: - AutomationEngine (Architecture.md layer 3)
// Generic WKWebView orchestration driven entirely by AdapterPack JSON.
// Strategy handlers implement the field strategies; country packs are data, not code.

import Foundation
import WebKit

// MARK: Strategy names (match packs/*/fields.json)

enum FieldStrategy: String {
    case textboxByLabel = "TEXTBOX_BY_LABEL"
    case searchCombobox = "SEARCH_COMBOBOX"
    case radioOptions = "RADIO_OPTIONS"
    case radioDynamic = "RADIO_DYNAMIC"
    case dateDmyTextboxes = "DATE_DMY_TEXTBOXES"
    case checkboxByLabel = "CHECKBOX_BY_LABEL"
    case button = "BUTTON"
}

// MARK: Value resolution: profile/trip -> field value

struct FieldValueResolver {
    let profile: Profile
    let trip: Trip

    /// Resolves "profile.fullNameInPassport" / "trip.purpose" style paths.
    func resolve(_ valueFrom: String) -> String? {
        let parts = valueFrom.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let mirror = Mirror(reflecting: parts[0] == "profile" ? profile : trip)
        for child in mirror.children where child.label == String(parts[1]) {
            return unwrapString(child.value)
        }
        return nil
    }

    private func unwrapString(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let e = value as? any RawRepresentable, let raw = e.rawValue as? String { return raw }
        return nil
    }
}

// MARK: The injected JS (single library, all strategies; parameterized per call)
// All main-actor: WKWebView is main-actor-isolated and every caller is UI-driven.

@MainActor
enum AutomationJS {
    /// Escape for embedding values into JS string literals.
    static func js(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static let library = """
    (function() {
      window.__eEntryAI = {
        norm: function(s) {
            return (s || '').replace(/\\s+/g, ' ').trim().toUpperCase();
        },
        normDigits: function(s) {
            return (s || '').replace(/\\s+/g, '');
        },
        setValue: function(el, value) {
            el.focus();
            el.value = value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.blur();
        },
        // Angular Material reactive forms need real-looking typing on autocomplete
        // inputs. WKWebView ignores synthetic KeyboardEvent+input for panel opening —
        // use execCommand('insertText') (trusted WebKit text-insertion path), then
        // fall back to per-char key events.
        typeValue: function(el, value) {
            el.focus();
            el.select && el.select();
            el.value = '';
            var inserted = false;
            try {
              inserted = document.execCommand('insertText', false, value);
            } catch (e) { inserted = false; }
            if (!inserted || el.value !== value) {
              el.value = '';
              el.dispatchEvent(new Event('input', { bubbles: true }));
              for (var i = 0; i < value.length; i++) {
                var ch = value[i];
                el.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true, cancelable: true }));
                el.value += ch;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true, cancelable: true }));
              }
            } else {
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
            }
        },
        byAria: function(label, kinds) {
            var candidates = [];
            kinds.forEach(function(k) { candidates.push(k + label); });
            for (var i = 0; i < candidates.length; i++) {
              try { var el = document.querySelector(candidates[i]); if (el) return el; } catch (e) {}
            }
            return null;
        },
        // Radiogroup lookup: ICA prefixes aria-labels with "Select " and appends
        // footnotes/URLs. Normalize: uppercase, strip "Select ", cut at first caret,
        // compare prefix-to-prefix up to the shorter of the two.
        findRadiogroup: function(label) {
            var clean = function(s) {
              s = window.__eEntryAI.norm(s);
              if (s.indexOf('SELECT ') === 0) s = s.slice(7);
              s = s.split('^')[0];
              s = s.split('HTTP')[0];
              return s.trim();
            };
            var groups = document.querySelectorAll('[role="radiogroup"]');
            var wanted = clean(label);
            for (var i = 0; i < groups.length; i++) {
              var a = clean(groups[i].getAttribute('aria-label'));
              var n = Math.min(a.length, wanted.length);
              if (n > 0 && a.slice(0, n) === wanted.slice(0, n)) return groups[i];
            }
            return null;
        },
        fillTextbox: function(label, value) {
            var el = window.__eEntryAI.byAria(label, ['input[aria-label="', 'input[placeholder="']);
            if (!el) {
              var all = document.querySelectorAll('input');
              for (var i = 0; i < all.length; i++) {
                if (window.__eEntryAI.norm(all[i].getAttribute('aria-label')) === window.__eEntryAI.norm(label)) { el = all[i]; break; }
              }
            }
            if (!el) return { ok: false, error: 'textbox not found: ' + label };
            window.__eEntryAI.setValue(el, value);
            return { ok: true };
        },
        // RADIO_OPTIONS: mat-radio-button text holds the visible option ("MALE"),
        // input.value is a code (F/M/O) — always match on the button text.
        selectRadio: function(label, value) {
            var group = window.__eEntryAI.findRadiogroup(label);
            if (!group) return { ok: false, error: 'radiogroup not found: ' + label };
            var btns = group.querySelectorAll('mat-radio-button, label, [role="radio"]');
            var wanted = window.__eEntryAI.norm(value);
            for (var i = 0; i < btns.length; i++) {
              var t = window.__eEntryAI.norm(btns[i].textContent);
              if (t === wanted) {
                var input = btns[i].querySelector('input[type="radio"]') || btns[i];
                input.click();
                return { ok: true, matched: t };
              }
            }
            return { ok: false, error: 'option not found: ' + value, groupLabel: group.getAttribute('aria-label') };
        },
        selectRadioDynamic: function(label, isoDate) {
            var group = window.__eEntryAI.findRadiogroup(label);
            if (!group) return { ok: false, error: 'group not found: ' + label };
            var months = ['JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE','JULY','AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER'];
            var parts = isoDate.split('-');
            var wanted = parseInt(parts[2], 10) + ' ' + months[parseInt(parts[1], 10) - 1] + ' ' + parts[0];
            var btns = group.querySelectorAll('mat-radio-button, label, [role="radio"]');
            var texts = [];
            for (var i = 0; i < btns.length; i++) {
              var t = window.__eEntryAI.norm(btns[i].textContent);
              texts.push(t);
              if (t.indexOf(wanted) !== -1) {
                (btns[i].querySelector('input[type="radio"]') || btns[i]).click();
                return { ok: true, matched: t };
              }
            }
            // Fallback for 3-date-window fields: the earliest option (portal "today").
            // Useful when the device clock drifted out of the portal's window.
            if (texts.length) {
              var first = btns[0];
              (first.querySelector('input[type="radio"]') || first).click();
              return { ok: true, matched: texts[0], note: 'fallback-earliest' };
            }
            return { ok: false, error: 'date option not found', wanted: wanted, texts: texts.slice(0, 6).join(' | ') };
        },
        // SEARCH_COMBOBOX — two steps (WKWebView cannot resolve returned Promises):
        // 1) typeAndOpenOptions: fill combobox, render filtered options, report count.
        // 2) pickOption: click the normalized-exact match.
        // SEARCH_COMBOBOX — WKWebView loses Angular state between evaluateJavaScript
        // round-trips (panel closes between calls). So: startComboboxSelect kicks off
        // an async JS sequence (type → wait → pick) storing the outcome on a global;
        // pollComboboxSelect returns it when done.
        startComboboxSelect: function(label, value) {
            window.__cbResult = null;
            var el = window.__eEntryAI.byAria(label, ['input[role="combobox"][aria-label="', 'input[aria-label="']);
            if (!el) { window.__cbResult = { ok: false, error: 'combobox not found: ' + label }; return 'started'; }
            window.__eEntryAI.typeValue(el, value);
            // Material keyboard path: ArrowDown opens the panel & highlights first option;
            // repeated ArrowDown moves highlight; Enter commits. Retry until option visible.
            setTimeout(function() {
              var opts = document.querySelectorAll('mat-option, [role="option"]');
              var wanted = window.__eEntryAI.norm(window.__eEntryAI.normDigits(value));
              for (var i = 0; i < opts.length; i++) {
                var t = window.__eEntryAI.norm(opts[i].textContent);
                if (t === wanted || window.__eEntryAI.normDigits(t) === wanted) {
                  opts[i].click();
                  window.__cbResult = { ok: true, matched: t };
                  return;
                }
              }
              // Panel not open from typing: force it open via the keyboard route.
              el.focus();
              el.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true }));
              el.dispatchEvent(new KeyboardEvent('keyup', { key: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true }));
              setTimeout(function() {
                var opts2 = document.querySelectorAll('mat-option, [role="option"]');
                // Two wanted forms: with spaces collapsed (typical labels) and fully
                // de-spaced (spaced-digit country codes like "8 5 2").
                var wantedPlain = window.__eEntryAI.norm(value);
                for (var j = 0; j < opts2.length; j++) {
                  var t2 = window.__eEntryAI.norm(opts2[j].textContent);
                  var segs = t2.split(',').map(function(s) { return s.trim(); });
                  if (t2 === wanted || t2 === wantedPlain || segs.indexOf(wanted) !== -1 || segs.indexOf(wantedPlain) !== -1) {
                    opts2[j].click();
                    window.__cbResult = { ok: true, matched: t2 };
                    return;
                  }
                }
                window.__cbResult = { ok: false, error: 'option not found for ' + label, optionCount: opts2.length,
                  expanded: el.getAttribute('aria-expanded') };
              }, 1200);
            }, 1200);
            return 'started';
        },
        pollComboboxSelect: function() {
            return window.__cbResult;
        },
        pickComboboxOption: function(label, value) {
            var opts = document.querySelectorAll('mat-option, [role="option"]');
            var active = document.activeElement;
            var overlay = document.querySelector('.cdk-overlay-container');
            var wanted = window.__eEntryAI.norm(window.__eEntryAI.normDigits(value));
            for (var i = 0; i < opts.length; i++) {
              var t = window.__eEntryAI.norm(opts[i].textContent);
              if (t === wanted || window.__eEntryAI.normDigits(t) === wanted) {
                opts[i].click();
                return { ok: true, matched: t };
              }
            }
            return { ok: false, error: 'option not found for ' + label, optionCount: opts.length,
              focus: active ? (active.getAttribute('aria-label') || active.tagName) : 'none',
              overlayChildren: overlay ? overlay.children.length : -1 };
        },
        fillDateDMY: function(label, isoDate) {
            var ps = document.querySelectorAll('p, label, span');
            var scope = null;
            var wanted = window.__eEntryAI.norm(label);
            for (var i = 0; i < ps.length; i++) {
              if (window.__eEntryAI.norm(ps[i].textContent).indexOf(wanted) !== -1) { scope = ps[i]; break; }
            }
            if (!scope) return { ok: false, error: 'date label not found: ' + label };
            var node = scope.parentElement;
            for (var d = 0; d < 6 && node; d++) {
              var days = node.querySelectorAll('input[aria-label="Day"], input[aria-label*="Day"]');
              if (days.length) {
                var m = isoDate.match(/^(\\d{4})-(\\d{2})-(\\d{2})$/);
                if (!m) return { ok: false, error: 'bad ISO date' };
                var day = node.querySelector('input[aria-label="Day"], input[aria-label*="Day"]');
                var month = node.querySelector('input[aria-label="Month"], input[aria-label*="Month"]');
                var year = node.querySelector('input[aria-label="Year"], input[aria-label*="Year"]');
                if (!day || !month || !year) return { ok: false, error: 'DMY inputs missing' };
                window.__eEntryAI.setValue(day, m[3]);
                window.__eEntryAI.setValue(month, m[2]);
                window.__eEntryAI.setValue(year, m[1]);
                return { ok: true };
              }
              node = node.parentElement;
            }
            return { ok: false, error: 'DMY container not found for ' + label };
        },
        detectText: function(needle) {
            return document.body.innerText.indexOf(needle) !== -1;
        },
        clickCheckboxByLabel: function(label) {
            var wanted = window.__eEntryAI.norm(label);
            var boxes = document.querySelectorAll('mat-checkbox, input[type="checkbox"]');
            for (var i = 0; i < boxes.length; i++) {
              var scopeEl = boxes[i].closest('div');
              var t = scopeEl ? scopeEl.textContent : '';
              if (window.__eEntryAI.norm(t).indexOf(wanted) !== -1) { boxes[i].click(); return { ok: true }; }
            }
            return { ok: false, error: 'checkbox not found: ' + label };
        },
        clickButtonByText: function(text, container) {
            var scope = container || document;
            var buttons = scope.querySelectorAll('button');
            var wanted = window.__eEntryAI.norm(text);
            for (var i = 0; i < buttons.length; i++) {
              if (window.__eEntryAI.norm(buttons[i].textContent).indexOf(wanted) !== -1) {
                buttons[i].click();
                return { ok: true };
              }
            }
            return { ok: false, error: 'button not found: ' + text };
        },
        pageHasTextbox: function(label) {
            return !!window.__eEntryAI.byAria(label, ['input[aria-label="']);
        }
      };
      return 'eEntryAI-JS-loaded';
    })();
    """

    static func loadLibrary(into webView: WKWebView) async throws {
        try await webView.evaluateJavaScript(library)
    }

    @MainActor
    static func run(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.evaluateJavaScript("(window.__eEntryAI ? " + script + " : ({ ok: false, error: 'LIB-NOT-LOADED' }))")
    }
}

// MARK: Orchestrator (main-actor: driven by the WebView coordinator)

@MainActor
final class AutofillOrchestrator {
    struct FieldResult: Codable {
        let key: String
        let ok: Bool
        let error: String?
    }

    private(set) var lastResults: [FieldResult] = []

    func runPage(
        pack: AdapterPack, page: AdapterPack.Page,
        resolver: FieldValueResolver, webView: WKWebView
    ) async throws -> [FieldResult] {
        // Re-inject on every page: SPA route changes can invalidate JS state in WKWebView.
        do {
            let libResult = try await webView.evaluateJavaScript(AutomationJS.library)
            try? await webView.evaluateJavaScript(
                "window.__libcheck = window.__eEntryAI ? 'LIB-OK' : 'LIB-MISSING'; window.__libcheck"
            )
        }
        var results: [FieldResult] = []

        for field in page.fields {
            // conditional visibility: run parent fields first — pack order guarantees deps.
            if let visibleWhen = field.visibleWhen {
                let visible = await checkVisibility(visibleWhen, in: webView, allFields: page.fields)
                if !visible {
                    results.append(.init(key: field.key, ok: true, error: "hidden (condition)"))
                    continue
                }
            }
            let result = await fill(field: field, resolver: resolver, webView: webView)
            results.append(result)
            // conditional fields appear after parent selection — small settle delay.
            if field.strategy == FieldStrategy.radioOptions.rawValue && field.visibleWhen == nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        lastResults = results
        return results
    }

    private func checkVisibility(_ rule: AdapterPack.PackField.VisibilityRule, in webView: WKWebView, allFields: [AdapterPack.PackField]) async -> Bool {
        // Pack rules reference the PARENT BY KEY ("modeOfTravel") — resolve to its label
        // ("Mode of Travel") for the radiogroup lookup.
        guard let parent = allFields.first(where: { $0.key == rule.field }) else { return false }
        let script = """
        (function() {
          var group = window.__eEntryAI.findRadiogroup(\(AutomationJS.js(parent.label)));
          if (!group) return false;
          var checked = group.querySelector('input[type="radio"]:checked');
          return !!checked && (window.__eEntryAI.norm(checked.value) === \(AutomationJS.js(rule.equals)) || window.__eEntryAI.norm(checked.closest('mat-radio-button, label, div').textContent).indexOf(\(AutomationJS.js(rule.equals))) !== -1);
        })()
        """
        return (try? await AutomationJS.run(script, in: webView) as? Bool) ?? false
    }

    private func fill(field: AdapterPack.PackField, resolver: FieldValueResolver, webView: WKWebView) async -> FieldResult {
        let value: String?
        if let from = field.valueFrom {
            value = resolver.resolve(from) ?? field.defaultValue
        } else {
            value = field.defaultValue
        }

        switch FieldStrategy(rawValue: field.strategy) {
        case .textboxByLabel:
            guard let v = value else { return skip(field) }
            let r = await call(webView, "fillTextbox(\(AutomationJS.js(field.label)), \(AutomationJS.js(v)))")
            return result(field, r)

        case .searchCombobox:
            guard let v = value else { return skip(field) }
            // Single-JS-execution sequence: type → wait → pick, stored on a global.
            // Swift polls the global until the result object appears.
            let start = await call(webView, "startComboboxSelect(\(AutomationJS.js(field.label)), \(AutomationJS.js(v)))")
            guard start?["ok"] as? Bool == false && start?["error"] != nil else {
                var finalResult: [String: Any]? = nil
                for _ in 0..<16 {   // poll up to ~8s
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    finalResult = await call(webView, "pollComboboxSelect()")
                    if finalResult != nil { break }
                }
                if let fr = finalResult, let ok = fr["ok"] as? Bool, ok {
                    return .init(key: field.key, ok: true, error: nil)
                }
                return result(field, finalResult ?? ["error": "combobox select timed out"])
            }
            return result(field, start)

        case .radioOptions:
            guard let v = value else { return skip(field) }
            let r = await call(webView, "selectRadio(\(AutomationJS.js(field.label)), \(AutomationJS.js(v)))")
            return result(field, r)
        case .radioDynamic:
            guard let v = value else { return skip(field) }
            let r = await call(webView, "selectRadioDynamic(\(AutomationJS.js(field.label)), \(AutomationJS.js(v)))")
            return result(field, r)

        case .dateDmyTextboxes:
            guard let v = value else { return skip(field) }
            let r = await call(webView, "fillDateDMY(\(AutomationJS.js(field.label)), \(AutomationJS.js(v)))")
            return result(field, r)

        default:
            return .init(key: field.key, ok: false, error: "unknown strategy \(field.strategy)")
        }
    }

    private func call(_ webView: WKWebView, _ script: String) async -> [String: Any]? {
        do {
            let result = try await webView.evaluateJavaScript("(window.__eEntryAI ? window.__eEntryAI." + script + " : ({ ok: false, error: 'LIB-NOT-LOADED' }))")
            return result as? [String: Any]
        } catch {
            return ["ok": false, "error": "swift-error: \(String(describing: error))"]
        }
    }

    private func result(_ field: AdapterPack.PackField, _ r: [String: Any]?) -> FieldResult {
        if let r, let ok = r["ok"] as? Bool, ok {
            return .init(key: field.key, ok: true, error: nil)
        }
        var err = (r?["error"] as? String) ?? "JS call failed"
        if let typed = r?["typedValue"] as? String { err += " (typed='\(typed)')" }
        if let count = r?["optionCount"] as? Int { err += " [options=\(count)]" }
        if let focus = r?["focus"] as? String { err += " [focus=\(focus)]" }
        if let oc = r?["overlayChildren"] as? Int { err += " [overlay=\(oc)]" }
        if let expanded = r?["expanded"] as? String { err += " [expanded=\(expanded)]" }
        if let owns = r?["owns"] as? String { err += " [owns=\(owns)]" }
        if let html = r?["html"] as? String { err += " [html=\(html.prefix(300))]" }
        if let wants = r?["wanted"] as? String { err += " [wanted=\(wants)]" }
        if let texts = r?["texts"] as? String { err += " [texts=\(texts)]" }
        return .init(key: field.key, ok: false, error: err)
    }

    private func skip(_ field: AdapterPack.PackField) -> FieldResult {
        .init(key: field.key, ok: false, error: "no value available in profile/trip")
    }

    // MARK: Navigation helpers (pack-driven)

    func clickEntryButton(pack: AdapterPack, webView: WKWebView) async {
        _ = await call(webView, "clickButtonByText(\(AutomationJS.js(pack.navigation.entryAction.button)))")
    }

    func clickNext(pack: AdapterPack, webView: WKWebView) async {
        _ = await call(webView, "clickButtonByText(\(AutomationJS.js(pack.navigation.nextButton)))")
    }

    func isReviewPage(pack: AdapterPack, webView: WKWebView) async -> Bool {
        guard let page = pack.pages.last, let marker = page.reviewDetection?.textContains else { return false }
        return (try? await AutomationJS.run("detectText(\(AutomationJS.js(marker)))", in: webView) as? Bool) ?? false
    }
}
