import DarraOwlPhoneKit
import SwiftUI
import UIKit

@main
struct DarraOwlPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    private let runtime = PhoneRuntime.shared
    private var model: PhoneModel { runtime.model }

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime)
                // A link can come from anywhere: it is shown and confirmed
                // before any pairing (see RootView).
                .onOpenURL { url in
                    if let problem = runtime.model.linkProblem(url) {
                        runtime.linkError = problem
                    } else {
                        runtime.pendingLink = url
                    }
                }
                .task { await PhoneRuntime.shared.start() }
                // initial: the paired Mac is known from launch now.
                .onChange(of: model.mac != nil, initial: true) { _, paired in
                    if paired, !runtime.isDemo { Task { await NotificationPermission.request() } }
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
