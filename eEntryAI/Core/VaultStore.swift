// MARK: - VaultStore: the encrypted security core (doc/Vault.md §4)
//
// At rest (ALWAYS): vault index + document images are AES-256-GCM ciphertext.
// The vault key itself is a Keychain item gated by biometry access control
// (kSecAttrAccessControl = biometryCurrentSet + orDevicePasscode):
// reading it triggers Face ID, evaluated by the Secure Enclave. The item is
// ThisDeviceOnly — it never migrates and never appears in backups.
//
// Unlock: Face ID → read vault key → decrypt vault into MEMORY only.
// Lock (manual / background / idle): drop key from memory; data at rest
// remains ciphertext regardless of lock state.

import Foundation
import CryptoKit
import LocalAuthentication
import Security
import UIKit

// MARK: Errors

enum VaultError: Error, LocalizedError {
    case keychainFailure(OSStatus)
    case vaultKeyUnavailable
    case decryptionFailed
    case locked
    case biometryUnavailable
    case cancelledByUser

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status): return "Keychain error (\(status))"
        case .vaultKeyUnavailable: return "Vault key not found"
        case .decryptionFailed: return "Vault decryption failed"
        case .locked: return "Vault is locked"
        case .biometryUnavailable: return "Face ID / passcode unavailable"
        case .cancelledByUser: return "Cancelled"
        }
    }
}

// MARK: The store

@MainActor
final class VaultStore: ObservableObject {
    enum LockState: Equatable {
        case locked, unlocked
    }

    // MARK: Published state

    @Published private(set) var lockState: LockState = .locked
    @Published private(set) var index = VaultIndex()

    // MARK: In-memory unlocked material (dropped on lock)

    private var vaultKey: SymmetricKey?
    private var hasStoredKey = false
    private var lockTimer: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?

    // MARK: Auto-lock settings (doc/Vault.md §5)

    var autoLockSeconds: Int = 300            // 5 min default; 0 = never
    static let autoLockOptions: [(label: String, seconds: Int)] = [
        ("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600), ("Never", 0)
    ]

    // MARK: Keychain constants

    private static let service = "com.eEntryAI.app.vault"
    private static let account = "vault-key"
    private static let accessControlFlags: SecAccessControlCreateFlags = [.biometryCurrentSet, .devicePasscode]

    // MARK: Lifecycle

    init() {
        hasStoredKey = Self.keyExists()
        observeBackground()

        // Test-only: seeded demo content for UI verification runs (simulator).
        if ProcessInfo.processInfo.arguments.contains("-uitest-vaultdemo") {
            Task { @MainActor in
                do {
                    try await unlock()           // simulator auto-approves biometrics
                    if index.persons.isEmpty {
                        try addPerson(name: "Jacky Li", isSelf: true)
                        try addPerson(name: "Family Member")
                        guard let selfPerson = index.persons.first(where: { $0.isSelf }) else { return }
                        // Synthetic MRZ fixture — no real personal data.
                        var doc = VaultDocument(personID: selfPerson.id, source: .manual)
                        doc.extracted = [
                            ExtractedField(key: .fullName, value: "JACKY LI", confidence: 1.0),
                            ExtractedField(key: .passportNumber, value: "HA672249", confidence: 1.0),
                            ExtractedField(key: .nationality, value: "CHN", confidence: 1.0),
                            ExtractedField(key: .dateOfBirth, value: "1990-06-01", confidence: 1.0),
                            ExtractedField(key: .sex, value: "MALE", confidence: 1.0),
                            ExtractedField(key: .expiryDate, value: "2027-08-18", confidence: 1.0),
                            ExtractedField(key: .issuingCountry, value: "CHN", confidence: 1.0),
                        ]
                        try addDocument(doc)
                    }
                } catch {
                    // Demo seeding is best-effort; the UI still works without it.
                }
            }
        }
    }

    /// Background → lock immediately (security default, not configurable).
    private func observeBackground() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    // MARK: Unlock / lock

    /// Face ID (or device passcode) → read the biometry-gated vault key from the
    /// Keychain → decrypt the index into memory.
    func unlock() async throws {
        if !hasStoredKey {
            try createVault()
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use device passcode"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw VaultError.biometryUnavailable
        }
        // Keychain read with this context triggers the Face ID prompt
        // (access control on the item, evaluated by the Secure Enclave).
        guard let keyData = Self.readVaultKey(context: context) else {
            throw VaultError.vaultKeyUnavailable
        }

        vaultKey = SymmetricKey(data: keyData)
        try decryptIndexIntoMemory()
        lockState = .unlocked
        startIdleTimer()
    }

    /// Drop the in-memory key + plaintext index. Ciphertext at rest is unaffected.
    func lock() {
        vaultKey = nil
        index = VaultIndex()
        lockState = .locked
        lockTimer?.cancel()
        lockTimer = nil
    }

    private func requireUnlocked() throws {
        guard lockState == .unlocked, vaultKey != nil else { throw VaultError.locked }
    }

    // MARK: First-run creation

    /// New vault: generate the AES key, store it as a NEW Keychain item with the
    /// biometry access control. Item creation needs no auth (nothing exists yet).
    private func createVault() throws {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let status = Self.storeVaultKey(keyData)
        guard status == errSecSuccess else { throw VaultError.keychainFailure(status) }
        hasStoredKey = true

        vaultKey = key
        index = VaultIndex()
        try persistIndex()
        lockState = .unlocked
        startIdleTimer()
    }

    // MARK: Keychain helpers

    private static func keyExists() -> Bool {
        var q = baseQuery()
        q[kSecReturnData as String] = false
        var item: CFTypeRef?
        // Existence check only — no auth prompt (no data returned).
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return status == errSecSuccess
    }

    /// Reading requires Face ID via the item's access control.
    private static func readVaultKey(context: LAContext) -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// First write of a NEW item: no auth needed (item creation).
    private static func storeVaultKey(_ data: Data) -> OSStatus {
        var q = baseQuery()
        q[kSecValueData as String] = data
        let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, accessControlFlags, nil
        )
        q[kSecAttrAccessControl as String] = access
        return SecItemAdd(q as CFDictionary, nil)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    // MARK: Encrypted persistence

    private var vaultDirectory: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexFileURL: URL { vaultDirectory.appendingPathComponent("index.vault") }

    private func persistIndex() throws {
        guard let key = vaultKey else { throw VaultError.locked }
        let data = try JSONEncoder().encode(index)
        let sealed = try AES.GCM.seal(data, using: key).combined!
        try sealed.write(to: indexFileURL, options: .atomic)
    }

    private func decryptIndexIntoMemory() throws {
        guard let key = vaultKey else { throw VaultError.locked }
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            index = VaultIndex()      // created but never persisted → empty
            return
        }
        let sealed = try Data(contentsOf: indexFileURL)
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else {
            throw VaultError.decryptionFailed
        }
        index = try JSONDecoder().decode(VaultIndex.self, from: plain)
    }

    // MARK: CRUD (unlocked only)

    func addPerson(name: String, isSelf: Bool = false) throws {
        try requireUnlocked()
        if isSelf { index.persons.removeAll { $0.isSelf } }   // one "self"
        index.persons.append(VaultPerson(displayName: name, isSelf: isSelf))
        try persistIndex()
    }

    func addDocument(_ document: VaultDocument, image: Data? = nil) throws {
        try requireUnlocked()
        var doc = document
        if let image {
            let fileName = "doc-\(doc.id.uuidString).jpg"
            try writeEncryptedFile(image, name: fileName)
            doc.imageFileName = fileName
        }
        index.documents.append(doc)
        if let pIdx = index.persons.firstIndex(where: { $0.id == doc.personID }) {
            index.persons[pIdx].documentIDs.append(doc.id)
        }
        try persistIndex()
    }

    func removeDocument(_ documentID: UUID) throws {
        try requireUnlocked()
        if let doc = index.documents.first(where: { $0.id == documentID }),
           let fileName = doc.imageFileName {
            try? deleteEncryptedFile(fileName)
        }
        index.documents.removeAll { $0.id == documentID }
        for pIdx in index.persons.indices {
            index.persons[pIdx].documentIDs.removeAll { $0 == documentID }
        }
        try persistIndex()
    }

    func removePerson(_ personID: UUID) throws {
        try requireUnlocked()
        let docs = index.documents.filter { $0.personID == personID }
        for doc in docs { try? removeDocument(doc.id) }
        index.persons.removeAll { $0.id == personID }
        try persistIndex()
    }

    func documents(for personID: UUID) -> [VaultDocument] {
        index.documents.filter { $0.personID == personID }
    }

    // MARK: Encrypted file storage (document images)

    func writeEncryptedFile(_ data: Data, name fileName: String) throws {
        guard let key = vaultKey else { throw VaultError.locked }
        let sealed = try AES.GCM.seal(data, using: key).combined!
        try sealed.write(to: vaultDirectory.appendingPathComponent(fileName), options: .atomic)
    }

    func readEncryptedFile(_ fileName: String) throws -> Data {
        guard let key = vaultKey else { throw VaultError.locked }
        let sealed = try Data(contentsOf: vaultDirectory.appendingPathComponent(fileName))
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else {
            throw VaultError.decryptionFailed
        }
        return try AES.GCM.open(box, using: key)
    }

    func deleteEncryptedFile(_ fileName: String) throws {
        let url = vaultDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Idle auto-lock

    private func startIdleTimer() {
        lockTimer?.cancel()
        guard autoLockSeconds > 0 else { return }
        lockTimer = Task { [weak self, seconds = autoLockSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    /// Call on any user interaction with vault screens (resets the idle timer).
    func touchActivity() {
        if lockState == .unlocked { startIdleTimer() }
    }
}
