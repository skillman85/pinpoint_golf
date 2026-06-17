import Foundation
import WatchConnectivity

enum WatchMissValue: String, Codable, CaseIterable, Identifiable {
    case notTracked
    case hit
    case left
    case right
    case short
    case long

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

final class WatchRoundSession: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var isReachable = false

    var applyUpdate: ((WatchHoleUpdatePayload) -> Void)?

    private let session: WCSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func publish(round: WatchRoundPayload?) {
        guard let session else { return }
        let payload: [String: Any]
        if let round, let data = try? encoder.encode(round) {
            payload = ["activeRound": data]
        } else {
            payload = ["activeRoundCleared": true]
        }

        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    private func handle(_ payload: [String: Any]) {
        guard let data = payload["holeUpdate"] as? Data,
              let update = try? decoder.decode(WatchHoleUpdatePayload.self, from: data) else {
            return
        }
        DispatchQueue.main.async {
            self.applyUpdate?(update)
        }
    }
}

#if os(iOS)
extension WatchMissValue {
    init(_ direction: MissDirection) {
        switch direction {
        case .notTracked: self = .notTracked
        case .hit: self = .hit
        case .left: self = .left
        case .right: self = .right
        case .short: self = .short
        case .long: self = .long
        }
    }

    var appDirection: MissDirection {
        switch self {
        case .notTracked: .notTracked
        case .hit: .hit
        case .left: .left
        case .right: .right
        case .short: .short
        case .long: .long
        }
    }
}

extension WatchRoundPayload {
    init(course: GolfCourse, tee: TeeBox, handicap: Double, currentHoleIndex: Int, entries: [RoundHoleEntry]) {
        let adjusted = (handicap * Double(tee.slope) / 113.0) + (tee.rating - Double(tee.par))
        let courseHandicap = max(0, Int(adjusted.rounded(.toNearestOrAwayFromZero)))
        self.init(
            courseName: course.name,
            teeName: tee.name,
            courseHandicap: courseHandicap,
            currentHoleIndex: currentHoleIndex,
            holes: entries.map { entry in
                WatchHolePayload(
                    number: entry.hole.number,
                    par: entry.hole.par,
                    yards: entry.hole.yards,
                    strokeIndex: entry.hole.strokeIndex,
                    score: entry.score,
                    putts: entry.putts,
                    fairway: WatchMissValue(entry.fairway),
                    green: WatchMissValue(entry.green)
                )
            }
        )
    }
}
#endif
