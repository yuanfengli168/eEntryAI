// MARK: - Core domain (Architecture.md layer 5)
// Pure Swift, no UI deps, no storage deps.

import Foundation

// MARK: Identity Profile (we own this schema — additive-only evolution)

enum Sex: String, Codable, CaseIterable {
    case female = "FEMALE"
    case male = "MALE"
    case others = "OTHERS"
}

struct Profile: Codable {
    var schemaVersion: Int = 1

    var fullNameInPassport: String
    var passportNumber: String
    var passportExpiry: String        // ISO-8601 "2030-12-12"
    var sexInPassport: Sex
    var dateOfBirth: String?          // ISO-8601
    var nationality: String           // portal-normalized, e.g. "CHINESE"
    var countryOfBirth: String        // e.g. "HONG KONG SAR"
    var placeOfResidence: String
    var email: String
    var phoneCountryCode: String      // "852"
    var mobileNumber: String

    init(
        schemaVersion: Int = 1,
        fullNameInPassport: String = "",
        passportNumber: String = "",
        passportExpiry: String = "",
        sexInPassport: Sex = .male,
        dateOfBirth: String? = nil,
        nationality: String = "",
        countryOfBirth: String = "",
        placeOfResidence: String = "",
        email: String = "",
        phoneCountryCode: String = "",
        mobileNumber: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.fullNameInPassport = fullNameInPassport
        self.passportNumber = passportNumber
        self.passportExpiry = passportExpiry
        self.sexInPassport = sexInPassport
        self.dateOfBirth = dateOfBirth
        self.nationality = nationality
        self.countryOfBirth = countryOfBirth
        self.placeOfResidence = placeOfResidence
        self.email = email
        self.phoneCountryCode = phoneCountryCode
        self.mobileNumber = mobileNumber
    }
}

// MARK: Trip (per-journey, prefilled from TripDefaults)

enum PurposeOfTravel: String, Codable, CaseIterable {
    case business = "BUSINESS/MEETING/CONFERENCE/CONVENTION/EXHIBITION"
    case education = "EDUCATION/TRAINING"
    case employment = "EMPLOYMENT"
    case official = "OFFICIAL/GOVERNMENT VISIT"
    case holiday = "HOLIDAY/SIGHTSEEING/LEISURE"
}

enum ModeOfTravel: String, Codable, CaseIterable {
    case air = "AIR", land = "LAND", sea = "SEA"
}

enum ModeOfTransport: String, Codable, CaseIterable {
    case commercial = "COMMERCIAL FLIGHT"
    case privateCargo = "PRIVATE/CARGO AIRLINE/OTHERS"
}

enum AccommodationType: String, Codable, CaseIterable {
    case hotel = "HOTEL", residential = "RESIDENTIAL", transit = "TRANSIT", dayTrip = "DAY TRIP"
}

struct Trip: Codable {
    var schemaVersion: Int = 1
    var arrivalDate: String = ""            // ISO-8601, must be within 3-day window
    var departureDate: String = ""          // ISO-8601, must be after arrival
    var lastPortBeforeSG: String = ""
    var nextPortAfterSG: String = ""
    var purpose: PurposeOfTravel = .holiday
    var modeOfTravel: ModeOfTravel = .air
    var modeOfTransport: ModeOfTransport = .commercial
    var airlineName: String = ""            // e.g. "AIR CHINA (CA)" — must match portal option
    var flightNumber: String = ""           // digits only, e.g. "123"
    var accommodationType: AccommodationType = .hotel
    var hotelName: String = ""
    var usedDifferentNamePassport: Bool = false
    var healthYellowFever: Bool = false
    var healthSymptoms: Bool = false
}

// MARK: Submission (history record)

enum SubmissionStatus: String, Codable {
    case draft, filled, submitted, failed
}

struct Submission: Codable, Identifiable {
    var id: UUID = UUID()
    var country: String
    var travelerName: String
    var arrivalDate: String
    var status: SubmissionStatus
    var createdAt: Date
}
