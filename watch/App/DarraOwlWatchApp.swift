import SwiftUI

@main
struct DarraOwlWatchApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        // Ready for the iPhone's updates and Siri even before a screen shows.
        WatchModel.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: WatchModel.shared)
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await WatchModel.shared.refresh() } }
                }
        }
        .backgroundTask(.watchConnectivity) {
            await WatchModel.shared.drainPending()
        }
    }
}
