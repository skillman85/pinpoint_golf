import Foundation
import SQLite3

final class PinpointDatabase {
    static let shared = PinpointDatabase()

    private var db: OpaquePointer?

    private init() {
        do {
            let documentsURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let databaseURL = documentsURL.appendingPathComponent("PinpointGolf.sqlite")

            guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
                throw DatabaseError.open(message: lastErrorMessage)
            }

            try execute("PRAGMA foreign_keys = ON;")
            try migrate()
        } catch {
            assertionFailure("Pinpoint database failed to open: \(error)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func loadHandicap() -> Double? {
        querySingleDouble("SELECT value FROM settings WHERE key = ?;", bindings: [.text("player_handicap")])
    }

    func saveHandicap(_ handicap: Double) {
        try? execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);",
            bindings: [.text("player_handicap"), .text(String(handicap))]
        )
    }

    func loadClubYardages() -> [ClubYardage] {
        guard let json = querySingleString("SELECT value FROM settings WHERE key = ?;", bindings: [.text("club_yardages")]),
              let data = json.data(using: .utf8),
              let clubs = try? JSONDecoder().decode([ClubYardage].self, from: data) else {
            return []
        }
        return clubs
    }

    func saveClubYardages(_ clubs: [ClubYardage]) {
        guard let data = try? JSONEncoder().encode(clubs),
              let json = String(data: data, encoding: .utf8) else { return }
        try? execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);",
            bindings: [.text("club_yardages"), .text(json)]
        )
    }

    func isMigrationComplete(_ name: String) -> Bool {
        querySingleString("SELECT value FROM settings WHERE key = ?;", bindings: [.text("migration_\(name)")]) == "complete"
    }

    func markMigrationComplete(_ name: String) {
        try? execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);",
            bindings: [.text("migration_\(name)"), .text("complete")]
        )
    }

    func loadFavoriteKeys() -> Set<String> {
        Set(queryStrings("SELECT favorite_key FROM favorite_courses ORDER BY favorite_key;"))
    }

    func setFavoriteKeys(_ keys: Set<String>) {
        do {
            try transaction {
                try execute("DELETE FROM favorite_courses;")
                for key in keys.sorted() {
                    try execute(
                        "INSERT INTO favorite_courses (favorite_key, created_at) VALUES (?, ?);",
                        bindings: [.text(key), .double(Date().timeIntervalSince1970)]
                    )
                }
            }
        } catch {
            assertionFailure("Failed saving favourites: \(error)")
        }
    }

    func loadRounds() -> [SavedRound] {
        var rounds: [SavedRound] = []
        let sql = """
        SELECT id, date, course_name, location, tee_name, tee_marker_color, tee_yards, tee_rating, tee_slope, handicap
        FROM rounds
        ORDER BY date DESC;
        """

        query(sql) { statement in
            guard
                let id = UUID(uuidString: columnText(statement, 0)),
                let teeColor = optionalColumnText(statement, 5).flatMap(TeeMarkerColor.init(rawValue:))
            else {
                if let id = UUID(uuidString: columnText(statement, 0)) {
                    rounds.append(
                        SavedRound(
                            id: id,
                            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                            courseName: columnText(statement, 2),
                            location: columnText(statement, 3),
                            teeName: columnText(statement, 4),
                            teeMarkerColor: nil,
                            teeYards: Int(sqlite3_column_int(statement, 6)),
                            teeRating: sqlite3_column_double(statement, 7),
                            teeSlope: Int(sqlite3_column_int(statement, 8)),
                            handicap: optionalColumnDouble(statement, 9),
                            holes: loadHoles(roundID: id)
                        )
                    )
                }
                return
            }

            rounds.append(
                SavedRound(
                    id: id,
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    courseName: columnText(statement, 2),
                    location: columnText(statement, 3),
                    teeName: columnText(statement, 4),
                    teeMarkerColor: teeColor,
                    teeYards: Int(sqlite3_column_int(statement, 6)),
                    teeRating: sqlite3_column_double(statement, 7),
                    teeSlope: Int(sqlite3_column_int(statement, 8)),
                    handicap: optionalColumnDouble(statement, 9),
                    holes: loadHoles(roundID: id)
                )
            )
        }

        return rounds
    }

    func saveRound(_ round: SavedRound) {
        do {
            try transaction {
                try execute("DELETE FROM round_holes WHERE round_id = ?;", bindings: [.text(round.id.uuidString)])
                try execute(
                    """
                    INSERT OR REPLACE INTO rounds
                    (id, date, course_name, location, tee_name, tee_marker_color, tee_yards, tee_rating, tee_slope, handicap)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(round.id.uuidString),
                        .double(round.date.timeIntervalSince1970),
                        .text(round.courseName),
                        .text(round.location),
                        .text(round.teeName),
                        .nullableText(round.teeMarkerColor?.rawValue),
                        .int(round.teeYards),
                        .double(round.teeRating),
                        .int(round.teeSlope),
                        .nullableDouble(round.handicap)
                    ]
                )

                for hole in round.holes {
                    try execute(
                        """
                        INSERT INTO round_holes
                        (id, round_id, hole_number, par, yards, stroke_index, score, putts, fairway, green, tee_club, approach_range, first_putt_distance, penalties, penalty_type, bunker, up_and_down, sand_save, recovery, note)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            .text(hole.id.uuidString),
                            .text(round.id.uuidString),
                            .int(hole.holeNumber),
                            .int(hole.par),
                            .int(hole.yards),
                            .int(hole.strokeIndex),
                            .int(hole.score),
                            .int(hole.putts),
                            .text(hole.fairway.rawValue),
                            .text(hole.green.rawValue),
                            .nullableText(hole.teeClub?.rawValue),
                            .nullableText(hole.approachRange?.rawValue),
                            .nullableText(hole.firstPuttDistance?.rawValue),
                            .int(hole.penalties),
                            .nullableText(hole.penaltyType?.rawValue),
                            .nullableBool(hole.bunker),
                            .nullableBool(hole.upAndDown),
                            .nullableBool(hole.sandSave),
                            .nullableBool(hole.recovery),
                            .text(hole.note)
                        ]
                    )
                }
            }
        } catch {
            assertionFailure("Failed saving round: \(error)")
        }
    }

    func deleteRound(id: UUID) {
        try? execute("DELETE FROM rounds WHERE id = ?;", bindings: [.text(id.uuidString)])
    }

    func loadCustomGoals() -> [CustomGoal] {
        var goals: [CustomGoal] = []
        query("SELECT id, title, is_complete, created_at FROM custom_goals ORDER BY created_at DESC;") { statement in
            guard let id = UUID(uuidString: columnText(statement, 0)) else { return }
            goals.append(
                CustomGoal(
                    id: id,
                    title: columnText(statement, 1),
                    isComplete: sqlite3_column_int(statement, 2) == 1,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            )
        }
        return goals
    }

    func saveCustomGoal(_ goal: CustomGoal) {
        try? execute(
            """
            INSERT OR REPLACE INTO custom_goals (id, title, is_complete, created_at)
            VALUES (?, ?, ?, ?);
            """,
            bindings: [
                .text(goal.id.uuidString),
                .text(goal.title),
                .int(goal.isComplete ? 1 : 0),
                .double(goal.createdAt.timeIntervalSince1970)
            ]
        )
    }

    func deleteCustomGoal(id: UUID) {
        try? execute("DELETE FROM custom_goals WHERE id = ?;", bindings: [.text(id.uuidString)])
    }

    var hasRounds: Bool {
        (querySingleDouble("SELECT COUNT(*) FROM rounds;") ?? 0) > 0
    }

    private func loadHoles(roundID: UUID) -> [SavedHoleEntry] {
        var holes: [SavedHoleEntry] = []
        let sql = """
        SELECT id, hole_number, par, yards, stroke_index, score, putts, fairway, green, tee_club, approach_range, first_putt_distance, penalties, penalty_type, bunker, up_and_down, sand_save, recovery, note
        FROM round_holes
        WHERE round_id = ?
        ORDER BY hole_number;
        """

        query(sql, bindings: [.text(roundID.uuidString)]) { statement in
            guard
                let id = UUID(uuidString: columnText(statement, 0)),
                let fairway = MissDirection(rawValue: columnText(statement, 7)),
                let green = MissDirection(rawValue: columnText(statement, 8))
            else { return }

            holes.append(
                SavedHoleEntry(
                    id: id,
                    holeNumber: Int(sqlite3_column_int(statement, 1)),
                    par: Int(sqlite3_column_int(statement, 2)),
                    yards: Int(sqlite3_column_int(statement, 3)),
                    strokeIndex: Int(sqlite3_column_int(statement, 4)),
                    score: Int(sqlite3_column_int(statement, 5)),
                    putts: Int(sqlite3_column_int(statement, 6)),
                    fairway: fairway,
                    green: green,
                    teeClub: optionalColumnText(statement, 9).flatMap(TeeClub.init(rawValue:)),
                    approachRange: optionalColumnText(statement, 10).flatMap(ApproachRange.init(rawValue:)),
                    firstPuttDistance: optionalColumnText(statement, 11).flatMap(FirstPuttDistance.init(rawValue:)),
                    penalties: Int(sqlite3_column_int(statement, 12)),
                    penaltyType: optionalColumnText(statement, 13).flatMap(PenaltyType.init(rawValue:)),
                    bunker: optionalColumnBool(statement, 14),
                    upAndDown: optionalColumnBool(statement, 15),
                    sandSave: optionalColumnBool(statement, 16),
                    recovery: optionalColumnBool(statement, 17),
                    note: columnText(statement, 18)
                )
            )
        }

        return holes
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS favorite_courses (
            favorite_key TEXT PRIMARY KEY,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS rounds (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            course_name TEXT NOT NULL,
            location TEXT NOT NULL,
            tee_name TEXT NOT NULL,
            tee_marker_color TEXT,
            tee_yards INTEGER NOT NULL,
            tee_rating REAL NOT NULL,
            tee_slope INTEGER NOT NULL,
            handicap REAL
        );

        CREATE TABLE IF NOT EXISTS round_holes (
            id TEXT PRIMARY KEY,
            round_id TEXT NOT NULL,
            hole_number INTEGER NOT NULL,
            par INTEGER NOT NULL,
            yards INTEGER NOT NULL,
            stroke_index INTEGER NOT NULL,
            score INTEGER NOT NULL,
            putts INTEGER NOT NULL,
            fairway TEXT NOT NULL,
            green TEXT NOT NULL,
            tee_club TEXT,
            approach_range TEXT,
            first_putt_distance TEXT,
            penalties INTEGER NOT NULL,
            penalty_type TEXT,
            bunker INTEGER,
            up_and_down INTEGER,
            sand_save INTEGER,
            recovery INTEGER,
            note TEXT NOT NULL DEFAULT '',
            FOREIGN KEY(round_id) REFERENCES rounds(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS custom_goals (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            is_complete INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS round_holes_round_id_index ON round_holes(round_id);
        CREATE INDEX IF NOT EXISTS rounds_date_index ON rounds(date DESC);
        """)
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try work()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        if bindings.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.execute(sql: sql, message: lastErrorMessage)
            }
            return
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(sql: sql, message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execute(sql: sql, message: lastErrorMessage)
        }
    }

    private func query(_ sql: String, bindings: [SQLiteValue] = [], row: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bind(bindings, to: statement)

        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private func queryStrings(_ sql: String, bindings: [SQLiteValue] = []) -> [String] {
        var values: [String] = []
        query(sql, bindings: bindings) { statement in
            values.append(columnText(statement, 0))
        }
        return values
    }

    private func querySingleDouble(_ sql: String, bindings: [SQLiteValue] = []) -> Double? {
        var value: Double?
        query(sql, bindings: bindings) { statement in
            value = Double(columnText(statement, 0))
        }
        return value
    }

    private func querySingleString(_ sql: String, bindings: [SQLiteValue] = []) -> String? {
        var value: String?
        query(sql, bindings: bindings) { statement in
            value = columnText(statement, 0)
        }
        return value
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let int):
                sqlite3_bind_int(statement, position, Int32(int))
            case .double(let double):
                sqlite3_bind_double(statement, position, double)
            case .text(let string):
                sqlite3_bind_text(statement, position, string, -1, SQLITE_TRANSIENT)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    private var lastErrorMessage: String {
        guard let message = sqlite3_errmsg(db) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

private enum SQLiteValue {
    case int(Int)
    case double(Double)
    case text(String)
    case null

    static func nullableText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    static func nullableDouble(_ value: Double?) -> SQLiteValue {
        value.map(SQLiteValue.double) ?? .null
    }

    static func nullableBool(_ value: Bool?) -> SQLiteValue {
        value.map { .int($0 ? 1 : 0) } ?? .null
    }
}

private enum DatabaseError: Error {
    case open(message: String)
    case prepare(sql: String, message: String)
    case execute(sql: String, message: String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
}

private func optionalColumnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return columnText(statement, index)
}

private func optionalColumnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

private func optionalColumnBool(_ statement: OpaquePointer?, _ index: Int32) -> Bool? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int(statement, index) == 1
}
