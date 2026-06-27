import SwiftUI

@main
struct PrecisionGolfWatchApp: App {
    @StateObject private var store = WatchRoundStore()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
        }
    }
}
