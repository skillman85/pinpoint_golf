import Foundation

enum GolfCourseAPIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "GolfCourseAPI key is missing. Add one to the GOLFCOURSE_API_KEY build setting."
        case .invalidResponse:
            "GolfCourseAPI returned an unexpected response."
        case .unauthorized:
            "GolfCourseAPI rejected the API key."
        }
    }
}

struct GolfCourseAPIClient {
    private let baseURL = URL(string: "https://api.golfcourseapi.com")!
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String? = Bundle.main.object(forInfoDictionaryKey: "GolfCourseAPIKey") as? String, session: URLSession = .shared) {
        self.apiKey = apiKey ?? ""
        self.session = session
    }

    func searchCourses(query: String) async throws -> [GolfCourse] {
        let searchResponse: GolfCourseAPISearchResponse = try await request(
            path: "/v1/search",
            queryItems: [URLQueryItem(name: "search_query", value: query)]
        )

        var courses: [GolfCourse] = []
        for course in searchResponse.courses.prefix(8) {
            if let courseID = course.id, let fullCourse = try? await courseDetails(id: courseID) {
                courses.append(fullCourse.toGolfCourse())
            } else {
                courses.append(course.toGolfCourse())
            }
        }
        return courses
    }

    func courseDetails(id: Int) async throws -> GolfCourseAPIResponseCourse {
        try await request(path: "/v1/courses/\(id)", queryItems: [])
    }

    private func request<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey != "$(GOLFCOURSE_API_KEY)" else {
            throw GolfCourseAPIError.missingAPIKey
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw GolfCourseAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Key \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GolfCourseAPIError.invalidResponse
        }
        guard httpResponse.statusCode != 401 else {
            throw GolfCourseAPIError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GolfCourseAPIError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct GolfCourseAPISearchResponse: Decodable {
    let courses: [GolfCourseAPIResponseCourse]
}

struct GolfCourseAPIResponseCourse: Decodable {
    let id: Int?
    let clubName: String?
    let courseName: String?
    let location: GolfCourseAPILocation?
    let tees: GolfCourseAPITees?

    enum CodingKeys: String, CodingKey {
        case id
        case clubName = "club_name"
        case courseName = "course_name"
        case location
        case tees
    }

    func toGolfCourse() -> GolfCourse {
        let courseTees = tees?.allTeeBoxes.map { $0.toTeeBox() }.filter { !$0.holes.isEmpty } ?? []
        let club = clubName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let course = courseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: String
        if club.isEmpty {
            title = course.isEmpty ? "Golf Course" : course
        } else if course.isEmpty || course == club {
            title = club
        } else {
            title = "\(club) - \(course)"
        }

        return GolfCourse(
            name: title,
            distance: "GolfCourseAPI",
            location: location?.displayName ?? "Verified scorecard",
            tees: courseTees.isEmpty ? [TeeBox(name: "Scorecard needed", yards: 0, par: 0, slope: 0, rating: 0, holes: [])] : courseTees,
            hasVerifiedScorecard: !courseTees.isEmpty
        )
    }
}

struct GolfCourseAPILocation: Decodable {
    let address: String?
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?

    var displayName: String {
        let parts = [city, countyOrState, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: ", ")
        }
        return address ?? "Verified scorecard"
    }

    private var countyOrState: String? {
        guard let state, !state.isEmpty else { return nil }
        return state
    }
}

struct GolfCourseAPITees: Decodable {
    let female: [GolfCourseAPITeeBox]?
    let male: [GolfCourseAPITeeBox]?

    var allTeeBoxes: [GolfCourseAPITeeBox] {
        (male ?? []) + (female ?? [])
    }
}

struct GolfCourseAPITeeBox: Decodable {
    let teeName: String?
    let courseRating: Double?
    let slopeRating: Int?
    let totalYards: Int?
    let numberOfHoles: Int?
    let parTotal: Int?
    let holes: [GolfCourseAPIHole]?

    enum CodingKeys: String, CodingKey {
        case teeName = "tee_name"
        case courseRating = "course_rating"
        case slopeRating = "slope_rating"
        case totalYards = "total_yards"
        case numberOfHoles = "number_of_holes"
        case parTotal = "par_total"
        case holes
    }

    func toTeeBox() -> TeeBox {
        let mappedHoles = (holes ?? []).enumerated().compactMap { index, apiHole -> Hole? in
            guard let par = apiHole.par, let yardage = apiHole.yardage else {
                return nil
            }
            return Hole(
                number: index + 1,
                par: par,
                yards: yardage,
                strokeIndex: apiHole.handicap ?? index + 1
            )
        }

        return TeeBox(
            name: cleanTeeName,
            markerColor: TeeMarkerColor.inferred(from: cleanTeeName),
            yards: totalYards ?? mappedHoles.reduce(0) { $0 + $1.yards },
            par: parTotal ?? mappedHoles.reduce(0) { $0 + $1.par },
            slope: slopeRating ?? 0,
            rating: courseRating ?? 0,
            holes: mappedHoles
        )
    }

    private var cleanTeeName: String {
        let cleaned = teeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? "Tee" : cleaned
    }
}

struct GolfCourseAPIHole: Decodable {
    let par: Int?
    let yardage: Int?
    let handicap: Int?
}
