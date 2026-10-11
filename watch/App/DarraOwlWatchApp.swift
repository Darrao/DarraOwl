import SwiftUI

@main
struct DarraOwlWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView(model: WatchModel.shared)
        }
    }
}
