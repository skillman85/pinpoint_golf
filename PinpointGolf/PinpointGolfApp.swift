import SwiftUI
import FirebaseCore

@main
struct PrecisionGolfApp: App {
    @UIApplicationDelegateAdaptor(PrecisionGolfAppDelegate.self) private var appDelegate

    init() {
        FirebaseApp.configure()
        PushNotificationService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
