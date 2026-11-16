// MARK: - Vault UI (Vault V-3): Face ID gate, persons, flip cards
// doc/Vault.md §2-3: scan/upload/manual inputs; photo front, tap-to-flip back.

import SwiftUI
import PhotosUI

struct VaultView: View {
    @StateObject private var vault = VaultStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch vault.lockState {
            case .locked:
                lockScreen
            case .unlocked:
                vaultContent
            }
        }
        .onAppear {
            Task { try? await vault.unlock() }      // biometry prompt on open
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { vault.touchActivity() }
        }
    }

    // MARK: Lock screen

    private var lockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Vault Locked")
                .font(.title3.bold())
            Text("Your documents are encrypted at rest")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let err = vault.lastUnlockError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("Unlock with Face ID") {
                Task {
                    do { try await vault.unlock() }
                    catch {
                        // lastUnlockError is already set by the store; this keeps
                        // the button visibly responsive even on failure.
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Vault content

    private var vaultContent: some View {
        List {
            ForEach(vault.index.persons) { person in
                Section(person.displayName + (person.isSelf ? "  (you)" : "")) {
                    let docs = vault.documents(for: person.id)
                    if docs.isEmpty {
                        Text("No documents")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(docs) { doc in
                        DocumentCard(vault: vault, document: doc)
                    }
                    Menu("Add document") {
                        AddDocumentMenu { source in
                            presentAdd(source: source, personID: person.id)
                        }
                    }
                }
            }

            Section {
                Button("Add family member") { showingAddPerson = true }
                    .foregroundStyle(.primary)
            } footer: {
                Text("You are the vault custodian — your Face ID unlocks everyone's documents.")
            }
        }
        .navigationTitle("Vault")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Lock") { vault.lock() } }
        }
        .sheet(isPresented: $showingAddPerson) {
            AddPersonSheet { name in
                try? vault.addPerson(name: name)
            }
        }
        .sheet(item: $addDocumentTarget) { target in
            AddDocumentSheet(vault: vault, personID: target.personID, source: target.source.sheetSource)
        }
    }

    @State private var showingAddPerson = false
    @State private var addDocumentTarget: AddTarget?

    private struct AddTarget: Identifiable {
        let id = UUID()
        let personID: UUID
        let source: AddDocumentSource
    }

    private func presentAdd(source: AddDocumentSource, personID: UUID) {
        addDocumentTarget = AddTarget(personID: personID, source: source)
    }
}

// MARK: - Add person sheet

private struct AddPersonSheet: View {
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
            }
            .navigationTitle("Add family member")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Add-document launcher (menu items)

enum AddDocumentSource: String, Identifiable {
    case scan, upload, manual
    var id: String { rawValue }
}

struct AddDocumentMenu: View {
    var onPick: (AddDocumentSource) -> Void

    var body: some View {
        Button("Scan with camera") { onPick(.scan) }
        Button("Upload from Photos") { onPick(.upload) }
        Button("Type manually") { onPick(.manual) }
    }
}
