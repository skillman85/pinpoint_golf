import Foundation

enum WatchMissValue: String, Codable, CaseIterable, Identifiable {
    case notTracked
    case hit
    case left
    case right
    case short
    case long

    var id: String { rawValue }
}

enum WatchApproachProximity: String, Codable, CaseIterable, Identifiable {
    case feet0to5 = "0-5 ft"
    case feet6to10 = "6-10 ft"
    case feet11to15 = "11-15 ft"
    case feet16to20 = "16-20 ft"
    case feet21to25 = "21-25 ft"
    case feet26to30 = "26-30 ft"

    var id: String { rawValue }
}

struct WatchHolePayload: Identifiable, Codable, Hashable {
    var id: Int { number }
    let number: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int
    var score: Int
    var putts: Int
    var fairway: WatchMissValue
    var green: WatchMissValue
    var approachProximity: WatchApproachProximity?
}

struct WatchRoundPayload: Codable, Hashable {
    let courseName: String
    let teeName: String
    let courseHandicap: Int
    var currentHoleIndex: Int
    var holes: [WatchHolePayload]

    var grossThroughCurrentHole: Int {
        holes.prefix(currentHoleIndex + 1).reduce(0) { $0 + $1.score }
    }

    var stablefordThroughCurrentHole: Int {
        holes.prefix(currentHoleIndex + 1).reduce(0) { total, hole in
            total + stablefordPoints(for: hole)
        }
    }

    func stablefordPoints(for hole: WatchHolePayload) -> Int {
        guard hole.score > 0 else { return 0 }
        let strokes = courseHandicap / 18 + (hole.strokeIndex <= courseHandicap % 18 ? 1 : 0)
        let netScore = hole.score - strokes
        return max(0, 2 + (hole.par - netScore))
    }
}

struct WatchHoleUpdatePayload: Codable {
    let currentHoleIndex: Int
    let hole: WatchHolePayload
}
