// MARK: - CountryAdapter layer (Architecture.md layer 2)
// Adapter packs are versioned JSON (packs/<country>/fields.json).
// Bundled copy = fallback truth; OTA update mechanism added later (AdapterPackStore).

import Foundation

// MARK: Pack model (mirrors packs/sg/fields.json)

struct AdapterPack: Codable {
    struct PackField: Codable {
        struct VisibilityRule: Codable {
            let field: String
            let equals: String
        }

        let key: String
        let label: String
        let strategy: String
        let valueFrom: String?
        let required: Bool?
        let options: [String]?
        let defaultValue: String?
        let visibleWhen: VisibilityRule?
        let format: String?
        let note: String?
    }

    struct Page: Codable {
        struct ReviewDetection: Codable {
            let textContains: String
        }

        let id: String
        let name: String
        let fields: [PackField]
        let reviewDetection: ReviewDetection?
    }

    struct Navigation: Codable {
        struct EntryAction: Codable {
            let path: String
            let button: String
        }

        let entryAction: EntryAction
        let nextButton: String
        let previousButton: String
    }

    let packVersion: Int
    let countryCode: String
    let countryName: String
    let pattern: String
    let minAppVersion: String
    let entryUrl: String
    let visitorManualPath: String?
    let pages: [Page]
    let navigation: Navigation
    let knownQuirks: [String]?
}

// MARK: Loader with validation (bundled pack is the fallback truth)

enum AdapterPackError: Error {
    case packNotFound
    case packInvalid
    case packUnsupportedAppVersion
}

final class AdapterPackLoader {
    /// Loads pack from bundle. Later: check OTA cache first, validate signature, fall back here.
    func load(countryCode: String) throws -> AdapterPack {
        // iOS filesystem is case-sensitive; pack directories on disk are lowercase
        // (packs/sg/) while country codes are uppercase (SG). Match case-insensitively.
        var foundURL: URL?
        if let resourceRoot = Bundle.main.resourceURL {
            let packsRoot = resourceRoot.appendingPathComponent("packs")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: packsRoot.path)) ?? []
            if let dir = entries.first(where: { $0.caseInsensitiveCompare(countryCode) == .orderedSame }) {
                let direct = packsRoot
                    .appendingPathComponent(dir)
                    .appendingPathComponent("fields.json")
                if FileManager.default.fileExists(atPath: direct.path) {
                    foundURL = direct
                }
            }
        }
        if foundURL == nil {
            for sub in ["packs/\(countryCode)", countryCode, "packs/\(countryCode.lowercased())"] {
                if let url = Bundle.main.url(
                    forResource: "fields", withExtension: "json", subdirectory: sub
                ) {
                    foundURL = url
                    break
                }
            }
        }
        guard let url = foundURL else { throw AdapterPackError.packNotFound }

        let data = try Data(contentsOf: url)
        let pack = try JSONDecoder().decode(AdapterPack.self, from: data)

        guard pack.countryCode == countryCode else { throw AdapterPackError.packInvalid }
        guard isAppVersion(greaterThanOrEqualTo: pack.minAppVersion) else {
            throw AdapterPackError.packUnsupportedAppVersion
        }
        return pack
    }

    private func isAppVersion(greaterThanOrEqualTo minimum: String) -> Bool {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let minParts = minimum.split(separator: ".").compactMap { Int($0) }
        // Pad shorter side so "0" vs "0.1.0" compares correctly (0 vs 0, 0 < 1).
        let len = max(currentParts.count, minParts.count)
        let cur = currentParts + Array(repeating: 0, count: len - currentParts.count)
        let min = minParts + Array(repeating: 0, count: len - minParts.count)
        for (c, m) in zip(cur, min) where c != m {
            return c > m
        }
        return true
    }
}

// MARK: Country registry — adding a country = add pack JSON + one enum case

enum SupportedCountry: String, CaseIterable, Identifiable {
    case sg = "SG"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sg: return "Singapore 🇸🇬"
        }
    }

    var isAvailable: Bool { true }   // stub future: VN/CN/US/AU/JP shown as "coming soon"
}

protocol CountryAdapter {
    var country: SupportedCountry { get }
    func loadPack() throws -> AdapterPack
}

struct SGCountryAdapter: CountryAdapter {
    let country: SupportedCountry = .sg
    private let loader = AdapterPackLoader()

    func loadPack() throws -> AdapterPack { try loader.load(countryCode: country.rawValue) }
}
