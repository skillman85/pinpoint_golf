import SwiftUI

@main
struct PrecisionGolfApp: App {
    @UIApplicationDelegateAdaptor(PrecisionGolfAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
