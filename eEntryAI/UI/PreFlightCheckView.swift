// MARK: - P0 Pre-flight check (fill-loop guard)
// Deterministic gap detection BEFORE the WebView opens: pack required fields
// diffed against profile+trip. No AI, no portal interaction.

import SwiftUI
import UIKit

// MARK: Missing-field detection

struct MissingFieldInput: Identifiable {
    let field: AdapterPack.PackField
    let kind: InputKind

    var id: String { field.key }

    enum InputKind {
        case text(hint: String?)
        case picker(options: [String])
        case arrivalDatePicker
        case departureDatePicker
    }
}

enum PreFlightCheck {
    /// Fields the run needs but has no value for. Conditional fields are evaluated
    /// against the current draft (parent selected?) — same gate the engine uses.
    static func missingFields(pack: AdapterPack, profile: Profile, trip: Trip) -> [MissingFieldInput] {
        let resolver = FieldValueResolver(profile: profile, trip: trip)
        var out: [MissingFieldInput] = []

        for page in pack.pages {
            for field in page.fields {
                guard field.required ?? true else { continue }
                if let when = field.visibleWhen, !isVisible(when, page: page, profile: profile, trip: trip) {
                    continue
                }
                let value = resolver.resolve(field.valueFrom ?? "") ?? field.defaultValue ?? ""
                guard value.isEmpty else { continue }
                out.append(MissingFieldInput(field: field, kind: inputKind(for: field)))
            }
        }
        return out
    }

    /// Draft-based visibility: parent's current resolved value must equal the rule.
    static func isVisible(
        _ rule: AdapterPack.PackField.VisibilityRule,
        page: AdapterPack.Page, profile: Profile, trip: Trip
    ) -> Bool {
        guard let parent = page.fields.first(where: { $0.key == rule.field }) else { return false }
        let resolver = FieldValueResolver(profile: profile, trip: trip)
        let parentValue = resolver.resolve(parent.valueFrom ?? "") ?? parent.defaultValue ?? ""
        return parentValue.uppercased() == rule.equals.uppercased()
    }

    private static func inputKind(for field: AdapterPack.PackField) -> MissingFieldInput.InputKind {
        if let options = field.options, !options.isEmpty {
            return .picker(options: options)
        }
        switch field.valueFrom ?? "" {
        case "trip.arrivalDate": return .arrivalDatePicker
        case "trip.departureDate": return .departureDatePicker
        default: return .text(hint: hint(for: field))
        }
    }

    private static func hint(for field: AdapterPack.PackField) -> String? {
        // Portal formats are DD/MM/YYYY but the profile stores ISO — say so explicitly.
        if field.format == "DD/MM/YYYY" { return "YYYY-MM-DD" }
        switch field.valueFrom ?? "" {
        case "profile.nationality": return "e.g. CHINESE"
        case "profile.countryOfBirth": return "e.g. HONG KONG SAR"
        case "profile.placeOfResidence": return "e.g. HONG KONG SAR"
        case "profile.phoneCountryCode": return "e.g. 852"
        case "trip.lastPortBeforeSG": return "e.g. HONG KONG SAR"
        case "trip.nextPortAfterSG": return "e.g. HONG KONG SAR"
        case "trip.airlineName": return "e.g. AIR CHINA (CA) — must match portal option"
        default: return field.note
        }
    }
}

// MARK: Value write-back (profile/trip by valueFrom path)

enum ProfileTripWriter {
    /// Returns updated copies (Swift 6-safe: no inout capture in bindings).
    static func apply(_ value: String, valueFrom: String, profile: Profile, trip: Trip) -> (Profile, Trip) {
        var p = profile
        var t = trip

        switch valueFrom {
        case "profile.fullNameInPassport": p.fullNameInPassport = value
        case "profile.passportNumber": p.passportNumber = value
        case "profile.passportExpiry": p.passportExpiry = value
        case "profile.dateOfBirth": p.dateOfBirth = value
        case "profile.sexInPassport": p.sexInPassport = Sex(rawValue: value) ?? p.sexInPassport
        case "profile.nationality": p.nationality = value
        case "profile.countryOfBirth": p.countryOfBirth = value
        case "profile.placeOfResidence": p.placeOfResidence = value
        case "profile.email": p.email = value
        case "profile.phoneCountryCode": p.phoneCountryCode = value
        case "profile.mobileNumber": p.mobileNumber = value

        case "trip.arrivalDate": t.arrivalDate = value
        case "trip.departureDate": t.departureDate = value
        case "trip.lastPortBeforeSG": t.lastPortBeforeSG = value
        case "trip.nextPortAfterSG": t.nextPortAfterSG = value
        case "trip.purpose": t.purpose = PurposeOfTravel(rawValue: value) ?? t.purpose
        case "trip.modeOfTravel": t.modeOfTravel = ModeOfTravel(rawValue: value) ?? t.modeOfTravel
        case "trip.modeOfTransport": t.modeOfTransport = ModeOfTransport(rawValue: value) ?? t.modeOfTransport
        case "trip.airlineName": t.airlineName = value
        case "trip.flightNumber": t.flightNumber = value
        case "trip.accommodationType": t.accommodationType = AccommodationType(rawValue: value) ?? t.accommodationType
        case "trip.hotelName": t.hotelName = value
        case "trip.usedDifferentNamePassport": t.usedDifferentNamePassport = (value.uppercased() == "YES")
        case "trip.healthSymptoms": t.healthSymptoms = (value.uppercased() == "YES")
        case "trip.healthYellowFever": t.healthYellowFever = (value.uppercased() == "YES")
        default: break
        }
        return (p, t)
    }
}

// MARK: Task wrapper for sheet(item:)

struct PreflightTask: Identifiable {
    let id = UUID()
    let pack: AdapterPack
}

// MARK: The sheet

struct PreFlightCheckView: View {
    @ObservedObject var model: AppModel
    let pack: AdapterPack
    var onStart: () -> Void

    @State private var draftProfile: Profile
    @State private var draftTrip: Trip
    @Environment(\.dismiss) private var dismiss

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(model: AppModel, pack: AdapterPack, onStart: @escaping () -> Void) {
        self.model = model
        self.pack = pack
        self.onStart = onStart
        _draftProfile = State(initialValue: model.profile ?? Profile())
        _draftTrip = State(initialValue: model.trip)
    }

    private var missing: [MissingFieldInput] {
        PreFlightCheck.missingFields(pack: pack, profile: draftProfile, trip: draftTrip)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Trip dates are always editable (sensible defaults applied on appear).
                Section("Trip dates") {
                    DatePicker("Arrival (within 3-day window)",
                               selection: dateBinding(for: "trip.arrivalDate", in: arrivalRange),
                               in: arrivalRange, displayedComponents: .date)
                    DatePicker("Departure from Singapore",
                               selection: dateBinding(for: "trip.departureDate", in: departureRange),
                               in: departureRange, displayedComponents: .date)
                }

                if missing.isEmpty {
                    Section {
                        Label("All required fields are ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        ForEach(missing) { item in
                            row(item)
                        }
                    } header: {
                        Text("Needed for \(pack.countryName) arrival card")
                    } footer: {
                        Text("Fill these once — they're saved on-device and reused for every future submission.")
                    }
                }

                Section {
                    Button("Start filling") { start() }
                        .disabled(!missing.isEmpty)
                    Button("Continue anyway") { start() }
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("“Continue anyway” opens the portal with gaps — you'll complete those fields on the portal page yourself.")
                }
            }
            .navigationTitle("Pre-flight Check")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: applyDateDefaults)
        }
    }

    // MARK: Actions

    private func start() {
        model.saveProfile(draftProfile)
        model.saveTrip(draftTrip)
        dismiss()
        onStart()
    }

    /// Arrival defaults to today; departure to arrival + 2 days (both within portal rules).
    private func applyDateDefaults() {
        if draftTrip.arrivalDate.isEmpty {
            draftTrip.arrivalDate = Self.iso.string(from: arrivalRange.lowerBound)
        }
        if draftTrip.departureDate.isEmpty {
            let arrival = Self.iso.date(from: draftTrip.arrivalDate) ?? arrivalRange.lowerBound
            draftTrip.departureDate = Self.iso.string(from: arrival.addingTimeInterval(2 * 86_400))
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: MissingFieldInput) -> some View {
        switch item.kind {
        case .text(let hint):
            VStack(alignment: .leading, spacing: 4) {
                Text(item.field.label).font(.subheadline.weight(.medium))
                TextField(hint ?? "Required", text: stringBinding(item.field))
                    .keyboardType(keyboardType(for: item.field))
                    .textInputAutocapitalization(autocapitalization(for: item.field))
                if let hint, hint.isEmpty == false {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .picker(let options):
            Picker(item.field.label, selection: stringBinding(item.field)) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .arrivalDatePicker:
            DatePicker(item.field.label,
                       selection: dateBinding(for: "trip.arrivalDate", in: arrivalRange),
                       in: arrivalRange, displayedComponents: .date)
        case .departureDatePicker:
            DatePicker(item.field.label,
                       selection: dateBinding(for: "trip.departureDate", in: departureRange),
                       in: departureRange, displayedComponents: .date)
        }
    }

    // MARK: Bindings

    private func stringBinding(_ field: AdapterPack.PackField) -> Binding<String> {
        Binding(
            get: {
                FieldValueResolver(profile: draftProfile, trip: draftTrip)
                    .resolve(field.valueFrom ?? "") ?? ""
            },
            set: { newValue in
                let (p, t) = ProfileTripWriter.apply(
                    newValue, valueFrom: field.valueFrom ?? "", profile: draftProfile, trip: draftTrip
                )
                draftProfile = p
                draftTrip = t
            }
        )
    }

    private func dateBinding(for path: String, in range: ClosedRange<Date>) -> Binding<Date> {
        Binding(
            get: {
                let s = FieldValueResolver(profile: draftProfile, trip: draftTrip).resolve(path) ?? ""
                return Self.iso.date(from: s) ?? range.lowerBound
            },
            set: { newValue in
                let (p, t) = ProfileTripWriter.apply(
                    Self.iso.string(from: newValue), valueFrom: path, profile: draftProfile, trip: draftTrip
                )
                draftProfile = p
                draftTrip = t
            }
        )
    }

    // MARK: Ranges & keyboards

    private var arrivalRange: ClosedRange<Date> {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        return today...today.addingTimeInterval(2 * 86_400)
    }

    private var departureRange: ClosedRange<Date> {
        let cal = Calendar(identifier: .gregorian)
        let arrival = Self.iso.date(from: draftTrip.arrivalDate) ?? Date()
        let start = cal.startOfDay(for: arrival).addingTimeInterval(86_400)
        return start...start.addingTimeInterval(364 * 86_400)
    }

    private func keyboardType(for field: AdapterPack.PackField) -> UIKeyboardType {
        switch field.valueFrom ?? "" {
        case "profile.email": return .emailAddress
        case "profile.phoneCountryCode", "profile.mobileNumber", "trip.flightNumber": return .numbersAndPunctuation
        default: return .default
        }
    }

    private func autocapitalization(for field: AdapterPack.PackField) -> TextInputAutocapitalization {
        switch field.valueFrom ?? "" {
        case "profile.email": return .never
        case "profile.nationality", "profile.countryOfBirth", "profile.placeOfResidence",
             "trip.lastPortBeforeSG", "trip.nextPortAfterSG", "trip.airlineName", "trip.hotelName":
            return .characters
        default: return .sentences
        }
    }
}
