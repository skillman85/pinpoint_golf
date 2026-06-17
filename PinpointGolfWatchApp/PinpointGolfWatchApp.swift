import SwiftUI

@main
struct PinpointGolfWatchApp: App {
    @StateObject private var store = WatchRoundStore()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
        }
    }
}
