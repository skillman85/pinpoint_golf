import Foundation

enum UKGolfAPIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case unauthorized
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "UK Golf API key is missing. Add one to the UK_GOLF_API_KEY build setting."
        case .invalidResponse:
            "UK Golf API returned an unexpected response."
        case .unauthorized:
            "UK Golf API rejected the RapidAPI key."
        case .rateLimited:
            "RapidAPI rate limit reached. Try again shortly."
        }
    }
}

struct UKGolfAPIClient {
    private let baseURL = URL(string: "https://uk-golf-course-data-api.p.rapidapi.com")!
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "UKGolfAPIKey") as? String, session: URLSession = .shared) {
        self.apiKey = apiKey ?? ""
        self.session = session
    }

    func searchCourses(query: String) async throws -> [GolfCourse] {
        let response: UKGolfClubSearchResponse = try await request(
            path: "/clubs",
            queryItems: [URLQueryItem(name: "search", value: query)]
        )

        var courses: [GolfCourse] = []
        for club in response.clubs.prefix(8) {
            let clubCourses = try await fetchCourses(clubID: club.id)
            for courseSummary in clubCourses.prefix(3) {
                if let scorecard = try? await scorecard(courseID: courseSummary.id) {
                    courses.append(scorecard.toGolfCourse(club: club))
                }
            }
        }

        return courses
    }

    func searchCourses(queries: [String], limit: Int) async throws -> [GolfCourse] {
        var courses: [GolfCourse] = []
        var seenKeys = Set<String>()
        var lastError: Error?

        for query in queries {
            do {
                let matches = try await searchCourses(query: query)
                for course in matches where !seenKeys.contains(course.favoriteKey) {
                    courses.append(course)
                    seenKeys.insert(course.favoriteKey)
                    if courses.count >= limit {
                        return courses
                    }
                }
            } catch UKGolfAPIError.rateLimited {
                throw UKGolfAPIError.rateLimited
            } catch UKGolfAPIError.missingAPIKey {
                throw UKGolfAPIError.missingAPIKey
            } catch UKGolfAPIError.unauthorized {
                throw UKGolfAPIError.unauthorized
            } catch {
                lastError = error
            }
        }

        if courses.isEmpty, let lastError {
            throw lastError
        }
        return courses
    }

    func fetchCourses(clubID: String) async throws -> [UKGolfCourseSummary] {
        let response: UKGolfCourseListResponse = try await request(
            path: "/clubs/\(clubID)/courses",
            queryItems: []
        )
        return response.courses
    }

    func scorecard(courseID: String) async throws -> UKGolfScorecard {
        let response: UKGolfScorecardResponse = try await request(
            path: "/courses/\(courseID)",
            queryItems: []
        )
        return response.scorecard
    }

    private func request<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey != "$(UK_GOLF_API_KEY)" else {
            throw UKGolfAPIError.missingAPIKey
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw UKGolfAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue(trimmedKey, forHTTPHeaderField: "X-RapidAPI-Key")
        request.setValue("uk-golf-course-data-api.p.rapidapi.com", forHTTPHeaderField: "X-RapidAPI-Host")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UKGolfAPIError.invalidResponse
        }
        guard httpResponse.statusCode != 401 && httpResponse.statusCode != 403 else {
            throw UKGolfAPIError.unauthorized
        }
        guard httpResponse.statusCode != 429 else {
            throw UKGolfAPIError.rateLimited
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UKGolfAPIError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private enum UKGolfCodingKey: String, CodingKey {
    case club
    case clubs
    case course
    case courses
    case data
    case results
    case id
    case name
    case county
    case postcode
    case latitude
    case lat
    case longitude
    case lng
    case teeSets
    case tee_sets
    case tees
    case holes
    case holeNumber
    case hole_number
    case number
    case par
    case yardage
    case yards
    case strokeIndex
    case stroke_index
    case handicap
    case si
    case slopeRating
    case slope_rating
    case courseRating
    case course_rating
}

struct UKGolfClubSearchResponse: Decodable {
    let clubs: [UKGolfClub]

    init(from decoder: Decoder) throws {
        if let clubs = try? [UKGolfClub](from: decoder) {
            self.clubs = clubs
            return
        }

        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        clubs = try container.decodeFirstPresent([UKGolfClub].self, forKeys: [.data, .clubs, .results])
    }
}

struct UKGolfCourseListResponse: Decodable {
    let courses: [UKGolfCourseSummary]

    init(from decoder: Decoder) throws {
        if let courses = try? [UKGolfCourseSummary](from: decoder) {
            self.courses = courses
            return
        }

        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        courses = try container.decodeFirstPresent([UKGolfCourseSummary].self, forKeys: [.data, .courses, .results])
    }
}

struct UKGolfScorecardResponse: Decodable {
    let scorecard: UKGolfScorecard

    init(from decoder: Decoder) throws {
        if let scorecard = try? UKGolfScorecard(from: decoder) {
            self.scorecard = scorecard
            return
        }

        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        scorecard = try container.decodeFirstPresent(UKGolfScorecard.self, forKeys: [.data, .course])
    }
}

struct UKGolfClub: Decodable {
    let id: String
    let name: String
    let county: String?
    let postcode: String?
    let latitude: Double?
    let longitude: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        id = try container.decodeFlexibleString(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        county = try container.decodeIfPresent(String.self, forKey: .county)
        postcode = try container.decodeIfPresent(String.self, forKey: .postcode)
        latitude = try container.decodeFlexibleDoubleIfPresent(forKeys: [.latitude, .lat])
        longitude = try container.decodeFlexibleDoubleIfPresent(forKeys: [.longitude, .lng])
    }
}

struct UKGolfCourseSummary: Decodable {
    let id: String
    let name: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        id = try container.decodeFlexibleString(forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Course"
    }
}

struct UKGolfScorecard: Decodable {
    let id: String
    let name: String
    let teeSets: [UKGolfTeeSet]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        id = (try? container.decodeFlexibleString(forKey: .id)) ?? UUID().uuidString
        name = (try? container.decode(String.self, forKey: .name)) ?? "Course"
        teeSets = try container.decodeFirstPresent([UKGolfTeeSet].self, forKeys: [.tee_sets, .teeSets, .tees])
    }

    func toGolfCourse(club: UKGolfClub) -> GolfCourse {
        let tees = teeSets.map { $0.toTeeBox() }.filter { !$0.holes.isEmpty }
        let location = [club.county, club.postcode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return GolfCourse(
            name: name == club.name ? club.name : "\(club.name) - \(name)",
            distance: "UK Golf API",
            location: location.isEmpty ? "Verified UK scorecard" : location,
            tees: tees.isEmpty ? [TeeBox(name: "Scorecard needed", yards: 0, par: 0, slope: 0, rating: 0, holes: [])] : tees,
            hasVerifiedScorecard: !tees.isEmpty
        )
    }
}

struct UKGolfTeeSet: Decodable {
    let name: String
    let par: Int?
    let slopeRating: Int?
    let courseRating: Double?
    let holes: [UKGolfHole]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Tee"
        par = try container.decodeFlexibleIntIfPresent(forKey: .par)
        slopeRating = try container.decodeFlexibleIntIfPresent(forKeys: [.slope_rating, .slopeRating])
        courseRating = try container.decodeFlexibleDoubleIfPresent(forKeys: [.course_rating, .courseRating])
        holes = (try? container.decode([UKGolfHole].self, forKey: .holes)) ?? []
    }

    func toTeeBox() -> TeeBox {
        let mappedHoles = holes.map {
            Hole(
                number: $0.holeNumber,
                par: $0.par,
                yards: $0.yardage,
                strokeIndex: $0.strokeIndex
            )
        }

        return TeeBox(
            name: name,
            yards: mappedHoles.reduce(0) { $0 + $1.yards },
            par: par ?? mappedHoles.reduce(0) { $0 + $1.par },
            slope: slopeRating ?? 0,
            rating: courseRating ?? 0,
            holes: mappedHoles.sorted { $0.number < $1.number }
        )
    }
}

struct UKGolfHole: Decodable {
    let holeNumber: Int
    let par: Int
    let yardage: Int
    let strokeIndex: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UKGolfCodingKey.self)
        holeNumber = try container.decodeFlexibleInt(forKeys: [.hole_number, .holeNumber, .number])
        par = try container.decodeFlexibleInt(forKey: .par)
        yardage = try container.decodeFlexibleInt(forKeys: [.yardage, .yards])
        strokeIndex = try container.decodeFlexibleInt(forKeys: [.stroke_index, .strokeIndex, .handicap, .si])
    }
}

private extension KeyedDecodingContainer where Key == UKGolfCodingKey {
    func decodeFirstPresent<T: Decodable>(_ type: T.Type, forKeys keys: [UKGolfCodingKey]) throws -> T {
        for key in keys {
            if let value = try? decode(type, forKey: key) {
                return value
            }
        }
        throw UKGolfAPIError.invalidResponse
    }

    func decodeFlexibleString(forKey key: UKGolfCodingKey) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        throw UKGolfAPIError.invalidResponse
    }

    func decodeFlexibleInt(forKey key: UKGolfCodingKey) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key), let intValue = Int(value) {
            return intValue
        }
        throw UKGolfAPIError.invalidResponse
    }

    func decodeFlexibleInt(forKeys keys: [UKGolfCodingKey]) throws -> Int {
        for key in keys {
            if let value = try? decodeFlexibleInt(forKey: key) {
                return value
            }
        }
        throw UKGolfAPIError.invalidResponse
    }

    func decodeFlexibleIntIfPresent(forKey key: UKGolfCodingKey) throws -> Int? {
        if contains(key) == false {
            return nil
        }
        return try decodeFlexibleInt(forKey: key)
    }

    func decodeFlexibleIntIfPresent(forKeys keys: [UKGolfCodingKey]) throws -> Int? {
        for key in keys where contains(key) {
            return try decodeFlexibleInt(forKey: key)
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKeys keys: [UKGolfCodingKey]) throws -> Double? {
        for key in keys where contains(key) {
            if let value = try? decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? decode(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decode(String.self, forKey: key), let doubleValue = Double(value) {
                return doubleValue
            }
            throw UKGolfAPIError.invalidResponse
        }
        return nil
    }
}
