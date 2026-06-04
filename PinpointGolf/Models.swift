import Foundation
import SwiftUI

struct GolfCourse: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let distance: String
    let location: String
    let tees: [TeeBox]
    let hasVerifiedScorecard: Bool

    init(name: String, distance: String, location: String, tees: [TeeBox], hasVerifiedScorecard: Bool = true) {
        self.name = name
        self.distance = distance
        self.location = location
        self.tees = tees
        self.hasVerifiedScorecard = hasVerifiedScorecard
    }

    var favoriteKey: String {
        "\(name.lowercased())|\(location.lowercased())"
    }
}

final class CourseFavorites: ObservableObject {
    @Published private(set) var favoriteKeys: Set<String>

    private let storageKey = "pinpoint.favoriteCourses"
    private let database = PinpointDatabase.shared

    init() {
        let storedKeys = database.loadFavoriteKeys()
        if storedKeys.isEmpty,
           !database.isMigrationComplete("favorite_courses") {
            let legacyKeys = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
            favoriteKeys = legacyKeys
            database.setFavoriteKeys(legacyKeys)
            database.markMigrationComplete("favorite_courses")
        } else {
            favoriteKeys = storedKeys
        }
    }

    func isFavorite(_ course: GolfCourse) -> Bool {
        favoriteKeys.contains(course.favoriteKey)
    }

    func toggle(_ course: GolfCourse) {
        if favoriteKeys.contains(course.favoriteKey) {
            favoriteKeys.remove(course.favoriteKey)
        } else {
            favoriteKeys.insert(course.favoriteKey)
        }
        persist()
    }

    func sorted(_ courses: [GolfCourse]) -> [GolfCourse] {
        courses.sorted { first, second in
            let firstFavorite = isFavorite(first)
            let secondFavorite = isFavorite(second)
            if firstFavorite != secondFavorite {
                return firstFavorite && !secondFavorite
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
    }

    private func persist() {
        database.setFavoriteKeys(favoriteKeys)
    }
}

struct TeeBox: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let markerColor: TeeMarkerColor
    let yards: Int
    let par: Int
    let slope: Int
    let rating: Double
    let holes: [Hole]

    init(name: String, markerColor: TeeMarkerColor? = nil, yards: Int, par: Int, slope: Int, rating: Double, holes: [Hole]) {
        self.name = name
        self.markerColor = markerColor ?? TeeMarkerColor.inferred(from: name)
        self.yards = yards
        self.par = par
        self.slope = slope
        self.rating = rating
        self.holes = holes
    }
}

enum TeeMarkerColor: String, CaseIterable, Identifiable, Codable, Hashable {
    case black = "Black"
    case blue = "Blue"
    case white = "White"
    case yellow = "Yellow"
    case red = "Red"
    case green = "Green"
    case gold = "Gold"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .black:
            Color.black
        case .blue:
            Color(red: 0.18, green: 0.48, blue: 0.95)
        case .white:
            Color.white
        case .yellow:
            Color(red: 0.98, green: 0.82, blue: 0.20)
        case .red:
            Color(red: 0.93, green: 0.22, blue: 0.25)
        case .green:
            Color(red: 0.22, green: 0.72, blue: 0.38)
        case .gold:
            AppTheme.gold
        }
    }

    static func inferred(from teeName: String) -> TeeMarkerColor {
        let name = teeName.lowercased()
        if name.contains("black") { return .black }
        if name.contains("blue") { return .blue }
        if name.contains("yellow") { return .yellow }
        if name.contains("red") { return .red }
        if name.contains("green") { return .green }
        if name.contains("gold") { return .gold }
        return .white
    }
}

struct Hole: Identifiable, Hashable {
    let id = UUID()
    let number: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
}

enum MissDirection: String, CaseIterable, Identifiable, Codable {
    case notTracked = "Not tracked"
    case hit = "Hit"
    case left = "Left"
    case right = "Right"
    case short = "Short"
    case long = "Long"

    var id: String { rawValue }
}

enum TeeClub: String, CaseIterable, Identifiable, Codable {
    case driver = "Driver"
    case threeWood = "3 Wood"
    case hybrid = "Hybrid"
    case longIron = "Long Iron"
    case iron = "Iron"
    case other = "Other"

    var id: String { rawValue }
}

enum ApproachRange: String, CaseIterable, Identifiable, Codable {
    case inside100 = "<100"
    case yards100to150 = "100-150"
    case yards150to200 = "150-200"
    case over200 = "200+"

    var id: String { rawValue }
}

enum FirstPuttDistance: String, CaseIterable, Identifiable, Codable {
    case inside3 = "<3 ft"
    case feet3to6 = "3-6 ft"
    case feet6to10 = "6-10 ft"
    case feet10to20 = "10-20 ft"
    case over20 = "20+ ft"

    var id: String { rawValue }
}

enum PenaltyType: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case water = "Water"
    case outOfBounds = "OB"
    case lostBall = "Lost"
    case unplayable = "Unplayable"

    var id: String { rawValue }
}

struct RoundHoleEntry: Identifiable, Equatable {
    let id = UUID()
    let hole: Hole
    var score: Int
    var putts: Int
    var fairway: MissDirection
    var green: MissDirection
    var teeClub: TeeClub
    var approachRange: ApproachRange
    var firstPuttDistance: FirstPuttDistance
    var penalties: Int
    var penaltyType: PenaltyType
    var bunker: Bool
    var upAndDown: Bool
    var sandSave: Bool
    var recovery: Bool
    var note: String
}

struct RoundSummary: Identifiable, Hashable {
    let id = UUID()
    let courseName: String
    let dateLabel: String
    let teeName: String
    let score: Int
    let par: Int
    let fairwaysHit: Int
    let fairwaysTotal: Int
    let greensInRegulation: Int
    let putts: Int
    let stablefordPoints: Int?
    let note: String

    var scoreToPar: Int { score - par }

    var scoreToParLabel: String {
        scoreToPar == 0 ? "E" : scoreToPar > 0 ? "+\(scoreToPar)" : "\(scoreToPar)"
    }
}

struct SavedRound: Identifiable, Codable {
    let id: UUID
    let date: Date
    let courseName: String
    let location: String
    let teeName: String
    let teeMarkerColor: TeeMarkerColor?
    let teeYards: Int
    let teeRating: Double
    let teeSlope: Int
    let handicap: Double?
    let holes: [SavedHoleEntry]

    var totalScore: Int { holes.reduce(0) { $0 + $1.score } }
    var totalPar: Int { holes.reduce(0) { $0 + $1.par } }
    var totalPutts: Int { holes.reduce(0) { $0 + $1.putts } }
    var fairwaysHit: Int { holes.filter { $0.par > 3 && $0.fairway == .hit }.count }
    var fairwaysTotal: Int { holes.filter { $0.par > 3 && $0.fairway != .notTracked }.count }
    var greensInRegulation: Int { holes.filter { $0.green == .hit }.count }
    var greensTracked: Int { holes.filter { $0.green != .notTracked }.count }
    var onePutts: Int { holes.filter { $0.putts == 1 }.count }
    var twoPutts: Int { holes.filter { $0.putts == 2 }.count }
    var threePutts: Int { holes.filter { $0.putts >= 3 }.count }
    var scramblingOpportunities: Int { holes.filter { $0.green != .hit && $0.green != .notTracked }.count }
    var scrambles: Int { holes.filter { $0.green != .hit && $0.green != .notTracked && $0.score <= $0.par }.count }
    var penalties: Int { holes.reduce(0) { $0 + $1.penalties } }
    var holeInOnes: Int { holes.filter { $0.par == 3 && $0.score == 1 }.count }
    var eaglesOrBetter: Int { holes.filter { $0.score - $0.par <= -2 }.count }
    var birdies: Int { holes.filter { $0.score - $0.par == -1 }.count }
    var pars: Int { holes.filter { $0.score == $0.par }.count }
    var bogeys: Int { holes.filter { $0.score - $0.par == 1 }.count }
    var doublesOrWorse: Int { holes.filter { $0.score - $0.par >= 2 }.count }
    var stablefordPoints: Int? {
        guard let handicap else { return nil }
        return stablefordPoints(using: handicap)
    }

    func courseHandicap(using handicapIndex: Double) -> Int {
        let adjusted = (handicapIndex * Double(teeSlope) / 113.0) + (teeRating - Double(totalPar))
        return max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
    }

    func stablefordPoints(using handicap: Double) -> Int {
        let adjustedHandicap = courseHandicap(using: handicap)
        return holes.reduce(0) { $0 + $1.stablefordPoints(using: Double(adjustedHandicap)) }
    }

    var summary: RoundSummary {
        RoundSummary(
            courseName: courseName,
            dateLabel: Self.shortDateFormatter.string(from: date),
            teeName: teeName,
            score: totalScore,
            par: totalPar,
            fairwaysHit: fairwaysHit,
            fairwaysTotal: fairwaysTotal,
            greensInRegulation: greensInRegulation,
            putts: totalPutts,
            stablefordPoints: stablefordPoints,
            note: holes.first { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.note ?? "Round saved with full hole-by-hole data."
        )
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct SavedHoleEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let holeNumber: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
    let score: Int
    let putts: Int
    let fairway: MissDirection
    let green: MissDirection
    let teeClub: TeeClub?
    let approachRange: ApproachRange?
    let firstPuttDistance: FirstPuttDistance?
    let penalties: Int
    let penaltyType: PenaltyType?
    let bunker: Bool?
    let upAndDown: Bool?
    let sandSave: Bool?
    let recovery: Bool?
    let note: String

    func stablefordPoints(using handicap: Double) -> Int {
        let strokes = handicapStrokes(using: handicap)
        let netScore = score - strokes
        return max(0, 2 + (par - netScore))
    }

    func handicapStrokes(using handicap: Double) -> Int {
        let roundedHandicap = max(0, Int(handicap.rounded()))
        let baseStrokes = roundedHandicap / 18
        let extraStrokes = strokeIndex <= roundedHandicap % 18 ? 1 : 0
        return baseStrokes + extraStrokes
    }
}

struct CustomGoal: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var isComplete: Bool
    let createdAt: Date
}

struct PinpointBackup: Codable {
    let version: Int
    let exportedAt: Date
    let handicap: Double
    let rounds: [SavedRound]
    let favoriteCourseKeys: [String]
    let customGoals: [CustomGoal]
    let clubYardages: [ClubYardage]
}

final class GoalArchive: ObservableObject {
    @Published private(set) var customGoals: [CustomGoal]

    private let database = PinpointDatabase.shared

    init() {
        customGoals = database.loadCustomGoals()
    }

    func add(title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let goal = CustomGoal(id: UUID(), title: trimmedTitle, isComplete: false, createdAt: Date())
        customGoals.insert(goal, at: 0)
        database.saveCustomGoal(goal)
    }

    func toggle(_ goal: CustomGoal) {
        guard let index = customGoals.firstIndex(where: { $0.id == goal.id }) else { return }
        customGoals[index].isComplete.toggle()
        database.saveCustomGoal(customGoals[index])
    }

    func delete(_ goal: CustomGoal) {
        customGoals.removeAll { $0.id == goal.id }
        database.deleteCustomGoal(id: goal.id)
    }
}

final class PlayerSettings: ObservableObject {
    @Published var handicap: Double {
        didSet {
            database.saveHandicap(handicap)
        }
    }

    private let storageKey = "pinpoint.playerHandicap"
    private let database = PinpointDatabase.shared

    init() {
        if let stored = database.loadHandicap() {
            handicap = stored
        } else {
            let legacyStored = UserDefaults.standard.double(forKey: storageKey)
            let migratedHandicap = legacyStored == 0 ? 18.0 : legacyStored
            handicap = migratedHandicap
            database.saveHandicap(migratedHandicap)
        }
    }
}

struct ClubYardage: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var isInBag: Bool
    var yards: Int?

    var yardageText: String {
        yards.map(String.init) ?? ""
    }
}

final class ClubYardageStore: ObservableObject {
    @Published var clubs: [ClubYardage] {
        didSet {
            database.saveClubYardages(clubs)
        }
    }

    private let database = PinpointDatabase.shared

    init() {
        let stored = database.loadClubYardages()
        clubs = Self.mergedDefaults(with: stored)
    }

    static let defaultClubs: [ClubYardage] = [
        ClubYardage(id: "dr", name: "Dr", isInBag: true, yards: nil),
        ClubYardage(id: "3w", name: "3W", isInBag: true, yards: nil),
        ClubYardage(id: "hybrid", name: "Hybrid", isInBag: true, yards: nil),
        ClubYardage(id: "di", name: "DI", isInBag: true, yards: nil),
        ClubYardage(id: "3", name: "3", isInBag: true, yards: nil),
        ClubYardage(id: "4", name: "4", isInBag: true, yards: nil),
        ClubYardage(id: "5", name: "5", isInBag: true, yards: nil),
        ClubYardage(id: "6", name: "6", isInBag: true, yards: nil),
        ClubYardage(id: "7", name: "7", isInBag: true, yards: nil),
        ClubYardage(id: "8", name: "8", isInBag: true, yards: nil),
        ClubYardage(id: "9", name: "9", isInBag: true, yards: nil),
        ClubYardage(id: "pw", name: "PW", isInBag: true, yards: nil),
        ClubYardage(id: "gw", name: "GW", isInBag: true, yards: nil),
        ClubYardage(id: "56", name: "56", isInBag: true, yards: nil),
        ClubYardage(id: "60", name: "60", isInBag: true, yards: nil)
    ]

    private static func mergedDefaults(with stored: [ClubYardage]) -> [ClubYardage] {
        guard !stored.isEmpty else { return defaultClubs }
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        var merged = defaultClubs.map { storedByID[$0.id] ?? $0 }
        let newDefaultIDs = Set(defaultClubs.map(\.id))
        merged.append(contentsOf: stored.filter { !newDefaultIDs.contains($0.id) })
        return merged
    }
}

final class RoundArchive: ObservableObject {
    @Published private(set) var rounds: [SavedRound]

    private let storageKey = "pinpoint.savedRounds"
    private let database = PinpointDatabase.shared

    init() {
        let storedRounds = database.loadRounds()
        if storedRounds.isEmpty,
           !database.isMigrationComplete("saved_rounds"),
           let data = UserDefaults.standard.data(forKey: storageKey),
           let legacyRounds = try? JSONDecoder().decode([SavedRound].self, from: data) {
            legacyRounds.forEach(database.saveRound)
            database.markMigrationComplete("saved_rounds")
            rounds = database.loadRounds()
        } else {
            if !database.isMigrationComplete("saved_rounds") {
                database.markMigrationComplete("saved_rounds")
            }
            rounds = storedRounds
        }
    }

    var roundSummaries: [RoundSummary] {
        rounds.map(\.summary)
    }

    func save(course: GolfCourse, tee: TeeBox, handicap: Double?, entries: [RoundHoleEntry]) {
        let savedRound = SavedRound(
            id: UUID(),
            date: Date(),
            courseName: course.name,
            location: course.location,
            teeName: tee.name,
            teeMarkerColor: tee.markerColor,
            teeYards: tee.yards,
            teeRating: tee.rating,
            teeSlope: tee.slope,
            handicap: handicap,
            holes: entries.map { entry in
                SavedHoleEntry(
                    id: UUID(),
                    holeNumber: entry.hole.number,
                    par: entry.hole.par,
                    yards: entry.hole.yards,
                    strokeIndex: entry.hole.strokeIndex,
                    score: entry.score,
                    putts: entry.putts,
                    fairway: entry.fairway,
                    green: entry.green,
                    teeClub: entry.teeClub,
                    approachRange: entry.approachRange,
                    firstPuttDistance: entry.firstPuttDistance,
                    penalties: entry.penalties,
                    penaltyType: entry.penaltyType,
                    bunker: entry.bunker,
                    upAndDown: entry.upAndDown,
                    sandSave: entry.sandSave,
                    recovery: entry.recovery,
                    note: entry.note
                )
            }
        )

        rounds.insert(savedRound, at: 0)
        database.saveRound(savedRound)
    }

    func delete(roundID: UUID) {
        rounds.removeAll { $0.id == roundID }
        database.deleteRound(id: roundID)
    }
}

struct DemoData {
    static let wergsWhiteHoles: [Hole] = [
        .init(number: 1, par: 4, yards: 291, strokeIndex: 17),
        .init(number: 2, par: 5, yards: 521, strokeIndex: 3),
        .init(number: 3, par: 4, yards: 309, strokeIndex: 15),
        .init(number: 4, par: 4, yards: 334, strokeIndex: 13),
        .init(number: 5, par: 3, yards: 220, strokeIndex: 9),
        .init(number: 6, par: 4, yards: 393, strokeIndex: 1),
        .init(number: 7, par: 5, yards: 573, strokeIndex: 5),
        .init(number: 8, par: 5, yards: 455, strokeIndex: 11),
        .init(number: 9, par: 3, yards: 195, strokeIndex: 7),
        .init(number: 10, par: 4, yards: 407, strokeIndex: 6),
        .init(number: 11, par: 3, yards: 162, strokeIndex: 18),
        .init(number: 12, par: 4, yards: 299, strokeIndex: 14),
        .init(number: 13, par: 4, yards: 366, strokeIndex: 16),
        .init(number: 14, par: 4, yards: 366, strokeIndex: 12),
        .init(number: 15, par: 5, yards: 511, strokeIndex: 4),
        .init(number: 16, par: 4, yards: 417, strokeIndex: 2),
        .init(number: 17, par: 4, yards: 402, strokeIndex: 8),
        .init(number: 18, par: 4, yards: 423, strokeIndex: 10)
    ]

    static let wergsYellowHoles: [Hole] = [
        .init(number: 1, par: 4, yards: 273, strokeIndex: 17),
        .init(number: 2, par: 5, yards: 484, strokeIndex: 3),
        .init(number: 3, par: 4, yards: 301, strokeIndex: 15),
        .init(number: 4, par: 4, yards: 318, strokeIndex: 13),
        .init(number: 5, par: 3, yards: 175, strokeIndex: 9),
        .init(number: 6, par: 4, yards: 372, strokeIndex: 1),
        .init(number: 7, par: 5, yards: 478, strokeIndex: 5),
        .init(number: 8, par: 5, yards: 429, strokeIndex: 11),
        .init(number: 9, par: 3, yards: 195, strokeIndex: 7),
        .init(number: 10, par: 4, yards: 379, strokeIndex: 6),
        .init(number: 11, par: 3, yards: 145, strokeIndex: 18),
        .init(number: 12, par: 4, yards: 281, strokeIndex: 14),
        .init(number: 13, par: 4, yards: 305, strokeIndex: 16),
        .init(number: 14, par: 4, yards: 358, strokeIndex: 12),
        .init(number: 15, par: 5, yards: 496, strokeIndex: 4),
        .init(number: 16, par: 4, yards: 379, strokeIndex: 2),
        .init(number: 17, par: 4, yards: 397, strokeIndex: 8),
        .init(number: 18, par: 4, yards: 412, strokeIndex: 10)
    ]

    static let holes: [Hole] = [
        .init(number: 1, par: 4, yards: 392, strokeIndex: 7),
        .init(number: 2, par: 5, yards: 518, strokeIndex: 11),
        .init(number: 3, par: 3, yards: 168, strokeIndex: 15),
        .init(number: 4, par: 4, yards: 421, strokeIndex: 1),
        .init(number: 5, par: 4, yards: 366, strokeIndex: 9),
        .init(number: 6, par: 3, yards: 184, strokeIndex: 13),
        .init(number: 7, par: 5, yards: 547, strokeIndex: 5),
        .init(number: 8, par: 4, yards: 402, strokeIndex: 3),
        .init(number: 9, par: 4, yards: 378, strokeIndex: 17),
        .init(number: 10, par: 4, yards: 410, strokeIndex: 4),
        .init(number: 11, par: 5, yards: 531, strokeIndex: 10),
        .init(number: 12, par: 3, yards: 176, strokeIndex: 16),
        .init(number: 13, par: 4, yards: 438, strokeIndex: 2),
        .init(number: 14, par: 4, yards: 387, strokeIndex: 12),
        .init(number: 15, par: 3, yards: 155, strokeIndex: 18),
        .init(number: 16, par: 5, yards: 559, strokeIndex: 6),
        .init(number: 17, par: 4, yards: 399, strokeIndex: 8),
        .init(number: 18, par: 4, yards: 444, strokeIndex: 14)
    ]

    static let courses: [GolfCourse] = [
        GolfCourse(
            name: "Wergs Golf Club",
            distance: "Verified local",
            location: "Tettenhall, Staffordshire",
            tees: [
                TeeBox(name: "White", yards: 6644, par: 73, slope: 124, rating: 71.5, holes: wergsWhiteHoles),
                TeeBox(name: "Yellow", markerColor: .yellow, yards: 6177, par: 73, slope: 119, rating: 69.2, holes: wergsYellowHoles)
            ]
        ),
        GolfCourse(
            name: "Moorland Pines",
            distance: "0.8 mi",
            location: "Rickmansworth",
            tees: [
                TeeBox(name: "White", yards: 6875, par: 72, slope: 134, rating: 73.8, holes: holes),
                TeeBox(name: "Yellow", yards: 6342, par: 72, slope: 128, rating: 71.2, holes: holes.map { Hole(number: $0.number, par: $0.par, yards: max($0.yards - 26, 118), strokeIndex: $0.strokeIndex) }),
                TeeBox(name: "Red", yards: 5621, par: 72, slope: 122, rating: 72.1, holes: holes.map { Hole(number: $0.number, par: $0.par, yards: max($0.yards - 64, 96), strokeIndex: $0.strokeIndex) })
            ]
        ),
        GolfCourse(
            name: "Batchworth Heath",
            distance: "2.1 mi",
            location: "Northwood",
            tees: [
                TeeBox(name: "White", yards: 6410, par: 71, slope: 130, rating: 72.4, holes: holes),
                TeeBox(name: "Yellow", yards: 5988, par: 71, slope: 124, rating: 70.3, holes: holes)
            ]
        ),
        GolfCourse(
            name: "Sandy Lodge",
            distance: "3.4 mi",
            location: "Middlesex",
            tees: [
                TeeBox(name: "Blue", yards: 7015, par: 72, slope: 138, rating: 74.6, holes: holes),
                TeeBox(name: "White", yards: 6620, par: 72, slope: 131, rating: 72.9, holes: holes)
            ]
        )
    ]

    static let recentRounds: [RoundSummary] = [
        RoundSummary(
            courseName: "Moorland Pines",
            dateLabel: "Yesterday",
            teeName: "White",
            score: 78,
            par: 72,
            fairwaysHit: 9,
            fairwaysTotal: 14,
            greensInRegulation: 11,
            putts: 32,
            stablefordPoints: nil,
            note: "Sharp iron play, two loose drives on the back nine."
        ),
        RoundSummary(
            courseName: "Batchworth Heath",
            dateLabel: "Tue",
            teeName: "Yellow",
            score: 81,
            par: 71,
            fairwaysHit: 7,
            fairwaysTotal: 13,
            greensInRegulation: 8,
            putts: 31,
            stablefordPoints: nil,
            note: "Scrambling held up. Approach misses finished short."
        ),
        RoundSummary(
            courseName: "Sandy Lodge",
            dateLabel: "Sat",
            teeName: "White",
            score: 76,
            par: 72,
            fairwaysHit: 10,
            fairwaysTotal: 14,
            greensInRegulation: 12,
            putts: 30,
            stablefordPoints: nil,
            note: "Best driving round of the month."
        )
    ]
}
