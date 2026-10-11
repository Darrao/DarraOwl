import DarraOwlPhoneKit
import SwiftUI
import UIKit

@main
struct DarraOwlPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @State private var model = PhoneRuntime.shared.model

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    Task { await model.pair(url: url) }
                }
                .task { await PhoneRuntime.shared.start() }
                .onChange(of: model.mac != nil) { _, paired in
                    if paired { Task { await NotificationPermission.request() } }
                }
                .task(id: phase) {
                    // Refresh while the app is on screen.
                    while phase == .active, !Task.isCancelled {
                        await model.tick()
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
        }
    }
}
