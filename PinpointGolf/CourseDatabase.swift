import Foundation

enum CourseDatabase {
    static let courses: [GolfCourse] = {
        guard let url = Bundle.main.url(forResource: "west_midlands_courses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BundledCourse].self, from: data) else {
            return DemoData.courses
        }

        let importedCourses = decoded.map { $0.toGolfCourse() }.filter { !$0.tees.isEmpty }
        return importedCourses.isEmpty ? DemoData.courses : importedCourses
    }()
}

private struct BundledCourse: Decodable {
    let name: String
    let distance: String
    let location: String
    let tees: [BundledTee]
    let hasVerifiedScorecard: Bool

    func toGolfCourse() -> GolfCourse {
        GolfCourse(
            name: name,
            distance: distance,
            location: location,
            tees: tees.map { $0.toTeeBox() },
            hasVerifiedScorecard: hasVerifiedScorecard
        )
    }
}

private struct BundledTee: Decodable {
    let name: String
    let markerColor: TeeMarkerColor
    let yards: Int
    let par: Int
    let slope: Int
    let rating: Double
    let holes: [BundledHole]

    func toTeeBox() -> TeeBox {
        TeeBox(
            name: name,
            markerColor: markerColor,
            yards: yards,
            par: par,
            slope: slope,
            rating: rating,
            holes: holes.map { $0.toHole() }
        )
    }
}

private struct BundledHole: Decodable {
    let number: Int
    let par: Int
    let yards: Int
    let strokeIndex: Int

    func toHole() -> Hole {
        Hole(number: number, par: par, yards: yards, strokeIndex: strokeIndex)
    }
}
