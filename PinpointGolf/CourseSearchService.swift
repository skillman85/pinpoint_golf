import Foundation
import CoreLocation
import MapKit

@MainActor
final class CourseSearchViewModel: ObservableObject {
    @Published private(set) var results: [GolfCourse] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?
    @Published private(set) var locationSearchLabel: String?

    private let ukGolfAPI = UKGolfAPIClient()
    private let locationProvider = CourseLocationProvider()

    func search(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let courses = try await ukGolfAPI.searchCourses(query: trimmedQuery)
            if !courses.isEmpty {
                results = courses
                return
            }
        } catch UKGolfAPIError.missingAPIKey {
            errorMessage = "RapidAPI key is missing. Falling back to saved courses."
        } catch UKGolfAPIError.unauthorized {
            errorMessage = "RapidAPI rejected the key. Falling back to saved courses."
        } catch UKGolfAPIError.rateLimited {
            errorMessage = "RapidAPI is rate limited. Try again shortly, or search by course name."
        } catch {
            errorMessage = "RapidAPI course search failed. Falling back to saved courses."
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
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let context = try await locationProvider.currentSearchContext()
            locationSearchLabel = context.label

            let nearbyNames = try await locationProvider.nearbyGolfCourseNames(near: context.location)
            let courses = try await ukGolfAPI.searchCourses(queries: nearbyNames, limit: 10)
            if !courses.isEmpty {
                results = courses
                return
            }

            let fallbackCourses = try await ukGolfAPI.searchCourses(query: context.label)
            if !fallbackCourses.isEmpty {
                results = fallbackCourses
                return
            }

            results = searchBundledCourses(query: context.label)
            if results.isEmpty {
                errorMessage = "No verified scorecards found nearby. Try searching by course name."
            }
        } catch CourseLocationError.permissionDenied {
            errorMessage = "Location permission is needed to search nearby courses. You can still search by town or county."
        } catch UKGolfAPIError.rateLimited {
            errorMessage = "RapidAPI is rate limited. Try again shortly, or search by course name."
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
        .prefix(8)

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
