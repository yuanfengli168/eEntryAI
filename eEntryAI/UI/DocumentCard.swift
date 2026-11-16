// MARK: - Document card (Vault V-3): photo front, tap-to-flip to extracted fields
// doc/Vault.md §3. States: valid / expiring(amber) / expired(gray).

import SwiftUI
import UIKit

struct DocumentCard: View {
    @ObservedObject var vault: VaultStore
    let document: VaultDocument

    @State private var flipped = false
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ZStack {
                front.opacity(flipped ? 0 : 1)
                back.opacity(flipped ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: flipped)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            vault.touchActivity()
            withAnimation { flipped.toggle() }
        }
        .task { loadImage() }
    }

    private var header: some View {
        HStack {
            Label("Passport", systemImage: "book.pages")
                .font(.subheadline.weight(.semibold))
            Spacer()
            expiryBadge
        }
    }

    @ViewBuilder
    private var expiryBadge: some View {
        switch document.state {
        case .valid:
            Label("Valid", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        case .expiring:
            Label("Expiring soon", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .expired:
            Label("Expired", systemImage: "xmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Front — photo

    private var front: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 100)
                    .overlay(
                        Label(document.source == .manual ? "No photo — typed entry" : "Photo encrypted",
                              systemImage: "photo")
                            .font(.footnote).foregroundStyle(.secondary)
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !document.extracted.isEmpty {
                Text(flipped ? "Show photo" : "Show details")
                    .font(.caption2).padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    // MARK: Back — extracted fields

    private var back: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(document.extracted) { field in
                HStack(alignment: .firstTextBaseline) {
                    Text(field.key.rawValue.replacingOccurrences(of: "passportNumber", with: "Passport No."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(field.value)
                        .font(.subheadline.monospaced())
                        .underline(color: field.isLowConfidence ? Color.orange : Color.clear)
                    Spacer()
                }
            }
            if document.extracted.isEmpty {
                Text("No extracted fields").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private func loadImage() {
        guard let fileName = document.imageFileName else { return }
        if let data = try? vault.readEncryptedFile(fileName) {
            image = UIImage(data: data)
        }
    }
}
