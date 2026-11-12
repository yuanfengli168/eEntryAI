// MARK: - Storage layer (Architecture.md layer 6)
// Protocols + v0 file-backed implementations. KeychainStore swap-in later.

import Foundation

protocol ProfileStore {
    func load() throws -> Profile?
    func save(_ profile: Profile) throws
    func delete() throws
}

protocol HistoryStore {
    func loadAll() throws -> [Submission]
    func add(_ submission: Submission) throws
}

enum StorageError: Error {
    case directoryCreationFailed
    case encodingFailed
    case decodingFailed
}

/// v0: JSON file in app sandbox (Application Support). v1 replaces with KeychainStore.
final class FileProfileStore: ProfileStore {
    private let fileURL: URL

    init(filename: String = "profile.json") throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        fileURL = dir.appendingPathComponent(filename)
    }

    func load() throws -> Profile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        // Tolerant decode: unknown future fields ignored, missing optional fields OK.
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
            // Schema migration chain goes here when schemaVersion > 1 exists.
            throw StorageError.decodingFailed
        }
        return profile
    }

    func save(_ profile: Profile) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// v0: JSON file. Migrate to SwiftData when history grows queries.
final class FileHistoryStore: HistoryStore {
    private let fileURL: URL

    init(filename: String = "history.json") throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        fileURL = dir.appendingPathComponent(filename)
    }

    func loadAll() throws -> [Submission] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return (try? JSONDecoder().decode([Submission].self, from: data)) ?? []
    }

    func add(_ submission: Submission) throws {
        var all = try loadAll()
        all.insert(submission, at: 0)
        let data = try JSONEncoder().encode(all)
        try data.write(to: fileURL, options: .atomic)
    }
}
