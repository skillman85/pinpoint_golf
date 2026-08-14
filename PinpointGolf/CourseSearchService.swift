import Foundation
import CoreLocation

enum CourseSearchSource {
    case none
    case onDevice
    case api
    case sessionCache
}

struct CourseSearchDiagnostics {
    let source: CourseSearchSource
    let searchLabel: String
    let queryCount: Int
    let radiusMeters: Int?
    let resultCount: Int
    let verifiedCount: Int
    let searchedAt: Date
}

@MainActor
final class CourseSearchViewModel: ObservableObject {
    @Published private(set) var results: [GolfCourse] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?
    @Published private(set) var locationSearchLabel: String?
    @Published private(set) var resultSource: CourseSearchSource = .none
    @Published private(set) var diagnostics: CourseSearchDiagnostics?

    private let courseAPI = PrecisionCourseAPIClient()
    private let locationProvider = CourseLocationProvider()
    private var cachedLocationSearch: (label: String, date: Date, courses: [GolfCourse])?
    private let locationSearchCacheLifetime: TimeInterval = 10 * 60
    private let nearbySearchRadiusMeters = 8_047

    func search(query: String, localCourses: [GolfCourse] = CourseDatabase.courses) async {
        guard !isSearching else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            resultSource = .none
            diagnostics = nil
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        var failedErrorMessage: String?
        do {
            let courses = try await courseAPI.searchCourses(query: trimmedQuery)
            if !courses.isEmpty {
                results = courses
                resultSource = .api
                diagnostics = makeDiagnostics(source: .api, label: trimmedQuery, queryCount: 1, radiusMeters: nil, courses: courses)
                return
            }
        } catch PrecisionCourseAPIError.missingBaseURL {
            failedErrorMessage = "Course API backend is not configured."
        } catch PrecisionCourseAPIError.rateLimited {
            failedErrorMessage = "Course search is busy. Wait a moment and try again."
        } catch {
            failedErrorMessage = "Course API search failed."
        }

        let localMatches = searchLocalCourses(query: trimmedQuery, in: localCourses)
        if !localMatches.isEmpty {
            results = localMatches
            resultSource = .onDevice
            diagnostics = makeDiagnostics(source: .onDevice, label: trimmedQuery, queryCount: 1, radiusMeters: nil, courses: localMatches)
            errorMessage = failedErrorMessage.map { "\($0) Showing saved scorecards." }
            return
        }

        results = []
        resultSource = .none
        diagnostics = makeDiagnostics(source: .none, label: trimmedQuery, queryCount: 1, radiusMeters: nil, courses: [])
        errorMessage = failedErrorMessage ?? "No verified scorecards found. Try course name, town, city or county."
    }

    func searchNearCurrentLocation(localCourses: [GolfCourse] = CourseDatabase.courses) async {
        guard !isSearching else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let context = try await locationProvider.currentSearchContext()
            locationSearchLabel = context.label

            if let cachedLocationSearch,
               cachedLocationSearch.label == context.label,
               Date().timeIntervalSince(cachedLocationSearch.date) < locationSearchCacheLifetime {
                results = cachedLocationSearch.courses
                resultSource = .sessionCache
                diagnostics = makeDiagnostics(source: .sessionCache, label: context.label, queryCount: context.searchTerms.count, radiusMeters: nearbySearchRadiusMeters, courses: cachedLocationSearch.courses)
                return
            }

            let nearbyQueries = Self.uniqueTerms(
                context.searchTerms
            )
            let apiQueries = Array(nearbyQueries.prefix(2))
            let courses = try await courseAPI.searchNearbyCourses(
                coordinate: context.location.coordinate,
                queries: apiQueries,
                limit: 3
            )
            let verifiedCourses = Self.verifiedCourses(courses)
            if !verifiedCourses.isEmpty {
                let mergedCourses = Self.mergedCourses(verifiedCourses)
                results = mergedCourses
                resultSource = .api
                diagnostics = makeDiagnostics(source: .api, label: context.label, queryCount: apiQueries.count, radiusMeters: nearbySearchRadiusMeters, courses: mergedCourses)
                cachedLocationSearch = (context.label, Date(), mergedCourses)
                return
            }

            results = []
            resultSource = .none
            diagnostics = makeDiagnostics(source: .none, label: context.label, queryCount: context.searchTerms.count, radiusMeters: nearbySearchRadiusMeters, courses: [])
            errorMessage = "No verified scorecards found nearby. Try searching by course name."
        } catch CourseLocationError.permissionDenied {
            resultSource = .none
            diagnostics = nil
            errorMessage = "Location permission is needed to search nearby courses. You can still search by town or county."
        } catch PrecisionCourseAPIError.missingBaseURL {
            resultSource = .none
            diagnostics = nil
            errorMessage = "Course API backend is not configured."
        } catch PrecisionCourseAPIError.rateLimited {
            resultSource = .none
            diagnostics = nil
            let localMatches = localLocationMatches(label: locationSearchLabel, in: localCourses)
            if !localMatches.isEmpty {
                results = localMatches
                resultSource = .onDevice
                diagnostics = makeDiagnostics(source: .onDevice, label: locationSearchLabel ?? "current location", queryCount: 1, radiusMeters: nearbySearchRadiusMeters, courses: localMatches)
                cachedLocationSearch = (locationSearchLabel ?? "current location", Date(), localMatches)
                errorMessage = "Course search is busy. Showing saved scorecards."
            } else {
                errorMessage = "Course search is busy. Wait a moment and try again."
            }
        } catch {
            resultSource = .none
            diagnostics = nil
            errorMessage = "Could not find nearby courses. Search by course name, town, city or county instead."
        }
    }

    private func searchLocalCourses(query: String, in courses: [GolfCourse]) -> [GolfCourse] {
        let normalizedQuery = query.lowercased()
        return Self.mergedCourses(Self.verifiedCourses(courses.filter { course in
            course.name.lowercased().contains(normalizedQuery)
                || course.location.lowercased().contains(normalizedQuery)
                || course.distance.lowercased().contains(normalizedQuery)
        }))
    }

    private func localLocationMatches(label: String?, in courses: [GolfCourse]) -> [GolfCourse] {
        let terms = Self.uniqueTerms([
            label ?? "",
            "dudley",
            "staffordshire",
            "wolverhampton",
            "tettenhall"
        ])
        let matches = terms.flatMap { searchLocalCourses(query: $0, in: courses) }
        return Self.mergedCourses(Self.verifiedCourses(matches))
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seenTerms = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { term in
                let key = term.lowercased()
                guard !seenTerms.contains(key) else { return false }
                seenTerms.insert(key)
                return true
            }
    }

    private static func verifiedCourses(_ courses: [GolfCourse]) -> [GolfCourse] {
        courses.filter { $0.hasVerifiedScorecard && !$0.tees.isEmpty }
    }

    private static func mergedCourses(_ courses: [GolfCourse]) -> [GolfCourse] {
        var seenCourses = Set<String>()
        return courses.filter { course in
            let key = course.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seenCourses.contains(key) else { return false }
            seenCourses.insert(key)
            return true
        }
    }

    private func makeDiagnostics(source: CourseSearchSource, label: String, queryCount: Int, radiusMeters: Int?, courses: [GolfCourse]) -> CourseSearchDiagnostics {
        CourseSearchDiagnostics(
            source: source,
            searchLabel: label,
            queryCount: max(0, queryCount),
            radiusMeters: radiusMeters,
            resultCount: courses.count,
            verifiedCount: Self.verifiedCourses(courses).count,
            searchedAt: Date()
        )
    }
}

enum PrecisionCourseAPIError: LocalizedError {
    case missingBaseURL
    case invalidResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "Precision course API base URL is missing."
        case .invalidResponse:
            "Precision course API returned an unexpected response."
        case .rateLimited:
            "Precision course API is rate limited."
        }
    }
}

struct PrecisionCourseAPIClient {
    private let session: URLSession
    private let baseURLString: String

    init(baseURLString: String? = nil, session: URLSession = .shared) {
        self.baseURLString = baseURLString
            ?? Bundle.main.object(forInfoDictionaryKey: "PrecisionCourseAPIBaseURL") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "PinpointCourseAPIBaseURL") as? String
            ?? ""
        self.session = session
    }

    func searchCourses(query: String, limit: Int = 8) async throws -> [GolfCourse] {
        let response: PrecisionCourseSearchResponse = try await request(
            path: "/api/courses/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return response.courses.map(\.golfCourse)
    }

    func searchNearbyCourses(coordinate: CLLocationCoordinate2D, queries: [String], limit: Int = 4) async throws -> [GolfCourse] {
        let response: PrecisionCourseSearchResponse = try await request(
            path: "/api/courses/near",
            queryItems: [
                URLQueryItem(name: "lat", value: String(format: "%.5f", coordinate.latitude)),
                URLQueryItem(name: "lng", value: String(format: "%.5f", coordinate.longitude)),
                URLQueryItem(name: "queries", value: queries.joined(separator: "|")),
                URLQueryItem(name: "radiusMeters", value: "8047"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return response.courses.map(\.golfCourse)
    }

    private func request<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        let trimmedBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty,
              !trimmedBaseURL.hasPrefix("$("),
              var components = URLComponents(string: trimmedBaseURL) else {
            throw PrecisionCourseAPIError.missingBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw PrecisionCourseAPIError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PrecisionCourseAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 429 {
                throw PrecisionCourseAPIError.rateLimited
            }
            throw PrecisionCourseAPIError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct PrecisionCourseSearchResponse: Decodable {
    let courses: [PrecisionCourse]
}

private struct PrecisionCourse: Decodable {
    let name: String
    let clubName: String?
    let distance: String?
    let location: String
    let tees: [PrecisionTee]
    let hasVerifiedScorecard: Bool?

    private var displayName: String {
        guard let clubName,
              !clubName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clubName.caseInsensitiveCompare(name) != .orderedSame else {
            return name
        }
        return "\(clubName) - \(name)"
    }

    var golfCourse: GolfCourse {
        GolfCourse(
            name: displayName,
            distance: distance ?? "Precision API",
            location: location,
            tees: tees.map(\.teeBox),
            hasVerifiedScorecard: hasVerifiedScorecard ?? !tees.isEmpty
        )
    }
}

private struct PrecisionTee: Decodable {
    let name: String
    let yards: Int
    let par: Int
    let slope: Int
    let rating: Double
    let holes: [PrecisionHole]

    var teeBox: TeeBox {
        TeeBox(
            name: name,
            yards: yards,
            par: par,
            slope: slope,
            rating: rating,
            holes: holes.map(\.hole).sorted { $0.number < $1.number }
        )
    }
}

private struct PrecisionHole: Decodable {
    let number: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int

    var hole: Hole {
        Hole(number: number, par: par, yards: yards, strokeIndex: strokeIndex)
    }
}

struct CourseSearchContext {
    let location: CLLocation
    let label: String
    let searchTerms: [String]
}

enum CourseLocationError: Error {
    case permissionDenied
    case noLocation
    case noPlacemark
    case noNearbyCourses
}

final class CourseLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentSearchContext() async throws -> CourseSearchContext {
        let location = try await currentLocation()
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw CourseLocationError.noPlacemark
        }

        let parts = [
            placemark.locality,
            placemark.subLocality,
            placemark.subAdministrativeArea,
            placemark.administrativeArea
        ]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let place = parts.first else {
            throw CourseLocationError.noPlacemark
        }
        return CourseSearchContext(location: location, label: place, searchTerms: parts)
    }

    private func currentLocation() async throws -> CLLocation {
        switch manager.authorizationStatus {
        case .notDetermined:
            try await requestAuthorization()
        case .denied, .restricted:
            throw CourseLocationError.permissionDenied
        default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let authorizationContinuation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationContinuation.resume()
            self.authorizationContinuation = nil
        case .denied, .restricted:
            authorizationContinuation.resume(throwing: CourseLocationError.permissionDenied)
            self.authorizationContinuation = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else {
            continuation?.resume(throwing: CourseLocationError.noLocation)
            continuation = nil
            return
        }
        continuation?.resume(returning: location)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
