import Foundation

@MainActor
final class CourseSearchViewModel: ObservableObject {
    @Published private(set) var results: [GolfCourse] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?

    private let ukGolfAPI = UKGolfAPIClient()
    private let golfCourseAPI = GolfCourseAPIClient()

    func search(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            results = []
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let localMatches = searchBundledCourses(query: trimmedQuery)
        if !localMatches.isEmpty {
            results = localMatches
            return
        }

        do {
            let courses = try await ukGolfAPI.searchCourses(query: trimmedQuery)
            results = courses
            if courses.isEmpty {
                errorMessage = "No UK scorecards found. Try the club name, course name or a nearby town."
            }
            return
        } catch UKGolfAPIError.missingAPIKey {
            // Fall through to the secondary provider until a RapidAPI key is added.
        } catch UKGolfAPIError.unauthorized {
            errorMessage = "UK Golf API rejected the RapidAPI key. Falling back to the secondary scorecard provider."
        } catch {
            errorMessage = "UK Golf API search failed. Falling back to the secondary scorecard provider."
        }

        do {
            let courses = try await golfCourseAPI.searchCourses(query: trimmedQuery)
            results = courses
            if courses.isEmpty {
                errorMessage = "No verified scorecards found. Try a more specific club name or use manual entry."
            }
        } catch GolfCourseAPIError.missingAPIKey {
            results = []
            errorMessage = "GolfCourseAPI key is missing. Search the local database or use manual entry."
        } catch GolfCourseAPIError.unauthorized {
            results = []
            errorMessage = "GolfCourseAPI rejected the key. Search the local database or use manual entry."
        } catch DecodingError.dataCorrupted, DecodingError.keyNotFound, DecodingError.typeMismatch, DecodingError.valueNotFound {
            results = []
            errorMessage = "GolfCourseAPI returned scorecard data in an unexpected shape. Search the local database or use manual entry."
        } catch {
            results = []
            errorMessage = "Verified scorecard search failed. Search the local database or use manual entry."
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
