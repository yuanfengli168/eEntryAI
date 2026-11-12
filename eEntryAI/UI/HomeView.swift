// MARK: - UI Layer (Architecture.md layer 1)
// Home = drawio decision node "fill?/history": pick country -> fill; or history list.

import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: Profile?
    @Published var trip = Trip()
    @Published var history: [Submission] = []
    @Published var lastFieldResults: [String] = []

    private var profileStore: FileProfileStore?
    private var historyStore: FileHistoryStore?

    init() {
        profileStore = try? FileProfileStore()
        historyStore = try? FileHistoryStore()
        profile = try? profileStore?.load()
        history = (try? historyStore?.loadAll()) ?? []

        // Test-only fixture seeding (UI test / live feasibility run):
        // -uitest-seed writes a fake profile+trip so the SG autofill flow can be
        // exercised end-to-end without touching the Profile UI. Not used in production.
        if ProcessInfo.processInfo.arguments.contains("-uitest-seed") {
            let cal = Calendar(identifier: .gregorian)
            let today = cal.startOfDay(for: Date())
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]

            // Match the portal's own clock: the SG Arrival Card window is today+2.
            // (A fixture seeded near midnight drifts out of the window otherwise.)
            func portalToday() -> String {
                var tz = TimeZone(identifier: "Asia/Singapore")!
                var sgCal = Calendar(identifier: .gregorian)
                sgCal.timeZone = tz
                return fmt.string(from: sgCal.startOfDay(for: Date()))
            }

            var fixture = Profile()
            fixture.fullNameInPassport = "TEST USER SCHEMAEXTRACT"
            fixture.passportNumber = "EK1234567"
            fixture.passportExpiry = "2030-12-12"
            fixture.sexInPassport = .male
            fixture.dateOfBirth = "1990-06-01"
            fixture.nationality = "CHINESE"
            fixture.countryOfBirth = "HONG KONG SAR"
            fixture.placeOfResidence = "HONG KONG SAR"
            fixture.email = "schema.test@example.com"
            fixture.phoneCountryCode = "852"
            fixture.mobileNumber = "91234567"
            profile = fixture

            trip.arrivalDate = portalToday()
            trip.departureDate = fmt.string(from: today.addingTimeInterval(8 * 86_400))
            trip.lastPortBeforeSG = "HONG KONG SAR"
            trip.nextPortAfterSG = "HONG KONG SAR"
            trip.purpose = .holiday
            trip.modeOfTravel = .air
            trip.modeOfTransport = .commercial
            trip.airlineName = "AIR CHINA (CA)"
            trip.flightNumber = "123"
            trip.accommodationType = .hotel
            trip.hotelName = "MARINA BAY SANDS SINGAPORE"
            trip.healthSymptoms = false
            trip.healthYellowFever = false
        }
    }

    func saveProfile(_ p: Profile) {
        profile = p
        try? profileStore?.save(p)
    }

    func recordSubmission(country: String, status: SubmissionStatus) {
        let record = Submission(
            country: country,
            travelerName: profile?.fullNameInPassport ?? "Unknown",
            arrivalDate: trip.arrivalDate,
            status: status,
            createdAt: Date()
        )
        history.insert(record, at: 0)
        try? historyStore?.add(record)
    }
}

struct HomeView: View {
    @StateObject private var model = AppModel()
    @State private var showWebView = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.profile == nil {
                        NavigationLink("Create your profile") { ProfileEntryView(model: model) }
                    } else {
                        NavigationLink("Edit profile") { ProfileEntryView(model: model) }
                    }
                } header: { Text("1. Identity — saved once, on-device only") }

                Section {
                    ForEach(SupportedCountry.allCases) { country in
                        Button(country.displayName) { showWebView = true }
                            .foregroundStyle(.primary)
                    }
                } header: { Text("2. Pick destination & fill arrival card") }

                Section {
                    Button("History") { showHistory = true }
                } header: { Text("3. Past submissions") }
            }
            .navigationTitle("eEntryAI")
            .sheet(isPresented: $showWebView) {
                SGWebViewScreen(model: model)
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(history: model.history)
            }
            .onAppear {
                // Test-only: auto-open the SG WebView flow for automated feasibility runs.
                if ProcessInfo.processInfo.arguments.contains("-uitest-autoopen") {
                    showWebView = true
                }
            }
        }
    }
}

// MARK: Profile entry (drawio "ai ask, type to ai" — v0: manual form)

struct ProfileEntryView: View {
    @ObservedObject var model: AppModel
    @State private var draft: Profile = Profile()

    var body: some View {
        Form {
            Section("Passport") {
                TextField("Full Name (In Passport)", text: $draft.fullNameInPassport)
                TextField("Passport Number", text: $draft.passportNumber)
                TextField("Passport Expiry (YYYY-MM-DD)", text: $draft.passportExpiry)
                Picker("Sex (in passport)", selection: $draft.sexInPassport) {
                    ForEach(Sex.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Date of Birth (YYYY-MM-DD)", text: Binding(
                    get: { draft.dateOfBirth ?? "" },
                    set: { draft.dateOfBirth = $0.isEmpty ? nil : $0 }
                ))
            }
            Section("Origin") {
                TextField("Nationality (e.g. CHINESE)", text: $draft.nationality)
                TextField("Country of Birth (e.g. HONG KONG SAR)", text: $draft.countryOfBirth)
                TextField("Place of Residence", text: $draft.placeOfResidence)
            }
            Section("Contact") {
                TextField("Email", text: $draft.email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                TextField("Country Code (e.g. 852)", text: $draft.phoneCountryCode)
                    .keyboardType(.phonePad)
                TextField("Mobile Number", text: $draft.mobileNumber)
                    .keyboardType(.phonePad)
            }
        }
        .navigationTitle("Profile")
        .onAppear { if let p = model.profile { draft = p } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { model.saveProfile(draft) }
            }
        }
    }
}

// MARK: History (drawio "show history in a list (scrollable)")

struct HistoryView: View {
    let history: [Submission]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if history.isEmpty {
                ContentUnavailableView("No submissions yet", systemImage: "tray")
            } else {
                List(history) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.country).bold()
                            Spacer()
                            Text(record.status.rawValue.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text("\(record.travelerName) — arriving \(record.arrivalDate)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
