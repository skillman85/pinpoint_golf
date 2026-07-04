import SwiftUI
import FirebaseCore

@main
struct PrecisionGolfApp: App {
    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
