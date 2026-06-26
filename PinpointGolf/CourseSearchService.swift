import Foundation
import CoreLocation
import MapKit

@MainActor
final class CourseSearchViewModel: ObservableObject {
    @Published private(set) var results: [GolfCourse] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?
    @Published private(set) var locationSearchLabel: String?

    private let courseAPI = PinpointCourseAPIClient()
    private let locationProvider = CourseLocationProvider()
    private var cachedLocationSearch: (label: String, date: Date, courses: [GolfCourse])?
    private let locationSearchCacheLifetime: TimeInterval = 10 * 60

    func search(query: String) async {
        guard !isSearching else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let courses = try await courseAPI.searchCourses(query: trimmedQuery)
            if !courses.isEmpty {
                results = courses
                return
            }
        } catch PinpointCourseAPIError.missingBaseURL {
            errorMessage = "Course API backend is not configured. Falling back to saved courses."
        } catch {
            errorMessage = "Course API search failed. Falling back to saved courses."
        }

        let localMatches = searchBundledCourses(query: trimmedQuery)
        if !localMatches.isEmpty {
            results = localMatches
            return
        }

        results = []
        errorMessage = "No verified scorecards found. Try course name, town, city or county."
    }

    func searchNearCurrentLocation() async {
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
                return
            }

            let nearbyNames = try await locationProvider.nearbyGolfCourseNames(near: context.location)
            let courses = try await courseAPI.searchNearbyCourses(
                coordinate: context.location.coordinate,
                queries: Array(nearbyNames.prefix(3)),
                limit: 4
            )
            if !courses.isEmpty {
                results = courses
                cachedLocationSearch = (context.label, Date(), courses)
                return
            }

            let fallbackCourses = try await courseAPI.searchCourses(query: context.label, limit: 4)
            if !fallbackCourses.isEmpty {
                results = fallbackCourses
                cachedLocationSearch = (context.label, Date(), fallbackCourses)
                return
            }

            results = searchBundledCourses(query: context.label)
            if results.isEmpty {
                errorMessage = "No verified scorecards found nearby. Try searching by course name."
            }
        } catch CourseLocationError.permissionDenied {
            errorMessage = "Location permission is needed to search nearby courses. You can still search by town or county."
        } catch PinpointCourseAPIError.missingBaseURL {
            errorMessage = "Course API backend is not configured. Search by course name or use favourites."
        } catch {
            errorMessage = "Could not find nearby courses. Search by course name, town, city or county instead."
        }
    }

    private func searchBundledCourses(query: String) -> [GolfCourse] {
        let normalizedQuery = query.lowercased()
        return CourseDatabase.courses.filter { course in
            course.name.lowercased().contains(normalizedQuery)
                || course.location.lowercased().contains(normalizedQuery)
        }
    }
}

enum PinpointCourseAPIError: LocalizedError {
    case missingBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            "Pinpoint course API base URL is missing."
        case .invalidResponse:
            "Pinpoint course API returned an unexpected response."
        }
    }
}

struct PinpointCourseAPIClient {
    private let session: URLSession
    private let baseURLString: String

    init(
        baseURLString: String? = Bundle.main.object(forInfoDictionaryKey: "PinpointCourseAPIBaseURL") as? String,
        session: URLSession = .shared
    ) {
        self.baseURLString = baseURLString ?? ""
        self.session = session
    }

    func searchCourses(query: String, limit: Int = 8) async throws -> [GolfCourse] {
        let response: PinpointCourseSearchResponse = try await request(
            path: "/api/courses/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return response.courses.map(\.golfCourse)
    }

    func searchNearbyCourses(coordinate: CLLocationCoordinate2D, queries: [String], limit: Int = 4) async throws -> [GolfCourse] {
        let response: PinpointCourseSearchResponse = try await request(
            path: "/api/courses/near",
            queryItems: [
                URLQueryItem(name: "lat", value: String(format: "%.5f", coordinate.latitude)),
                URLQueryItem(name: "lng", value: String(format: "%.5f", coordinate.longitude)),
                URLQueryItem(name: "queries", value: queries.joined(separator: "|")),
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
            throw PinpointCourseAPIError.missingBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? path : "/\(basePath)\(path)"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw PinpointCourseAPIError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PinpointCourseAPIError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct PinpointCourseSearchResponse: Decodable {
    let courses: [PinpointCourse]
}

private struct PinpointCourse: Decodable {
    let name: String
    let distance: String?
    let location: String
    let tees: [PinpointTee]
    let hasVerifiedScorecard: Bool?

    var golfCourse: GolfCourse {
        GolfCourse(
            name: name,
            distance: distance ?? "Pinpoint API",
            location: location,
            tees: tees.map(\.teeBox),
            hasVerifiedScorecard: hasVerifiedScorecard ?? !tees.isEmpty
        )
    }
}

private struct PinpointTee: Decodable {
    let name: String
    let yards: Int
    let par: Int
    let slope: Int
    let rating: Double
    let holes: [PinpointHole]

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

private struct PinpointHole: Decodable {
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
            placemark.subAdministrativeArea,
            placemark.administrativeArea
        ]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let place = parts.first else {
            throw CourseLocationError.noPlacemark
        }
        return CourseSearchContext(location: location, label: place)
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
        .prefix(5)

        guard !uniqueNames.isEmpty else {
            throw CourseLocationError.noNearbyCourses
        }
        return Array(uniqueNames)
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
