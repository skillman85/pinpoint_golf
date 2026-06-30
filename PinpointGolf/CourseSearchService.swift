import Foundation
import CoreLocation
import MapKit

enum CourseSearchSource {
    case none
    case onDevice
    case api
    case sessionCache
}

@MainActor
final class CourseSearchViewModel: ObservableObject {
    @Published private(set) var results: [GolfCourse] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?
    @Published private(set) var locationSearchLabel: String?
    @Published private(set) var resultSource: CourseSearchSource = .none

    private let courseAPI = PrecisionCourseAPIClient()
    private let locationProvider = CourseLocationProvider()
    private var cachedLocationSearch: (label: String, date: Date, courses: [GolfCourse])?
    private let locationSearchCacheLifetime: TimeInterval = 10 * 60

    func search(query: String, localCourses: [GolfCourse] = CourseDatabase.courses) async {
        guard !isSearching else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            resultSource = .none
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let localMatches = searchLocalCourses(query: trimmedQuery, in: localCourses)
        if !localMatches.isEmpty {
            results = localMatches
            resultSource = .onDevice
            return
        }

        do {
            let courses = try await courseAPI.searchCourses(query: trimmedQuery)
            if !courses.isEmpty {
                results = courses
                resultSource = .api
                return
            }
        } catch PrecisionCourseAPIError.missingBaseURL {
            errorMessage = "Course API backend is not configured. Falling back to saved courses."
        } catch {
            errorMessage = "Course API search failed. Falling back to saved courses."
        }

        results = []
        resultSource = .none
        errorMessage = "No verified scorecards found. Try course name, town, city or county."
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
                return
            }

            let localMatches = localLocationMatches(for: context, in: localCourses)
            if !localMatches.isEmpty {
                results = localMatches
                resultSource = .onDevice
                cachedLocationSearch = (context.label, Date(), localMatches)
                return
            }

            let nearbyNames = (try? await locationProvider.nearbyGolfCourseNames(near: context.location)) ?? []
            let nearbyQueries = Self.uniqueTerms(
                CourseLocationProvider.regionalCourseSearchHints(near: context.location, label: context.label)
                    + nearbyNames
                    + context.searchTerms
            )
            let courses = (try? await courseAPI.searchNearbyCourses(
                coordinate: context.location.coordinate,
                queries: Array(nearbyQueries.prefix(25)),
                limit: 8
            )) ?? []
            let verifiedCourses = Self.verifiedCourses(courses)
            if !verifiedCourses.isEmpty {
                let mergedCourses = Self.mergedCourses(verifiedCourses)
                results = mergedCourses
                resultSource = .api
                cachedLocationSearch = (context.label, Date(), mergedCourses)
                return
            }

            results = Self.mergedCourses(
                Self.verifiedCourses(context.searchTerms.flatMap { searchLocalCourses(query: $0, in: localCourses) })
            )
            resultSource = results.isEmpty ? .none : .onDevice
            if results.isEmpty {
                errorMessage = "No verified scorecards found nearby. Try searching by course name."
            }
        } catch CourseLocationError.permissionDenied {
            resultSource = .none
            errorMessage = "Location permission is needed to search nearby courses. You can still search by town or county."
        } catch PrecisionCourseAPIError.missingBaseURL {
            resultSource = .none
            errorMessage = "Course API backend is not configured. Search by course name or use favourites."
        } catch {
            resultSource = .none
            errorMessage = "Could not find nearby courses. Search by course name, town, city or county instead."
        }
    }

    private func searchLocalCourses(query: String, in courses: [GolfCourse]) -> [GolfCourse] {
        let normalizedQuery = query.lowercased()
        return Self.mergedCourses(courses.filter { course in
            course.name.lowercased().contains(normalizedQuery)
                || course.location.lowercased().contains(normalizedQuery)
        })
    }

    private func localLocationMatches(for context: CourseSearchContext, in courses: [GolfCourse]) -> [GolfCourse] {
        let searchTerms = Self.uniqueTerms(
            CourseLocationProvider.regionalCourseSearchHints(near: context.location, label: context.label)
                + context.searchTerms
        )
        let matches = searchTerms.flatMap { searchLocalCourses(query: $0, in: courses) }
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
}

enum PrecisionCourseAPIError: LocalizedError {
    case missingBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "Precision course API base URL is missing."
        case .invalidResponse:
            "Precision course API returned an unexpected response."
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
                URLQueryItem(name: "radiusMeters", value: "45000"),
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
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
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
    let distance: String?
    let location: String
    let tees: [PrecisionTee]
    let hasVerifiedScorecard: Bool?

    var golfCourse: GolfCourse {
        GolfCourse(
            name: name,
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

    func nearbyGolfCourseNames(near location: CLLocation) async throws -> [String] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "golf course"
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 45_000,
            longitudinalMeters: 45_000
        )

        let response = try await MKLocalSearch(request: request).start()
        let names = response.mapItems
            .sorted { lhs, rhs in
                let lhsDistance = lhs.placemark.location?.distance(from: location) ?? .greatestFiniteMagnitude
                let rhsDistance = rhs.placemark.location?.distance(from: location) ?? .greatestFiniteMagnitude
                return lhsDistance < rhsDistance
            }
            .compactMap { item -> String? in
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                return name
            }

        var seenNames = Set<String>()
        let uniqueNames = names.filter { name in
            let key = name.lowercased()
            guard !seenNames.contains(key) else { return false }
            seenNames.insert(key)
            return true
        }
        .prefix(25)

        guard !uniqueNames.isEmpty else {
            throw CourseLocationError.noNearbyCourses
        }
        return Array(uniqueNames)
    }

    static func regionalCourseSearchHints(near location: CLLocation, label: String) -> [String] {
        var hints: [String] = []
        let isDudleyLabeled = hasDudleyAreaLabel(label)
        if isDudleyLabeled || isNearDudleyGolfArea(location, label: label) {
            hints += [
                "Penn Golf",
                "Penn Golf Club",
                "Sedgley Golf Centre",
                "Sedgley golf",
                "Dudley Golf Club",
                "Dudley golf course",
                "Sedgley golf course"
            ]
        }
        if !isDudleyLabeled && isNearWolverhamptonGolfArea(location, label: label) {
            hints += [
                "Wergs Golf Club",
                "Perton Park Golf Club",
                "South Staffordshire Golf Club",
                "Wolverhampton golf club"
            ]
        }
        return hints
    }

    private static func isNearWolverhamptonGolfArea(_ location: CLLocation, label: String) -> Bool {
        let normalizedLabel = label.lowercased()
        if ["tettenhall", "wolverhampton", "perton"].contains(where: normalizedLabel.contains) {
            return true
        }

        let wergsArea = CLLocation(latitude: 52.6108, longitude: -2.1905)
        return location.distance(from: wergsArea) <= 12_000
    }

    private static func isNearDudleyGolfArea(_ location: CLLocation, label: String) -> Bool {
        if hasDudleyAreaLabel(label) {
            return true
        }

        let dudleyArea = CLLocation(latitude: 52.5123, longitude: -2.0811)
        return location.distance(from: dudleyArea) <= 18_000
    }

    private static func hasDudleyAreaLabel(_ label: String) -> Bool {
        let normalizedLabel = label.lowercased()
        return ["dudley", "sedgley", "penn", "west midlands"].contains(where: normalizedLabel.contains)
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
