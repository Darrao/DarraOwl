import DarraOwlPhoneKit
import SwiftUI
import UIKit

@main
struct DarraOwlPhoneApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var model = PhoneModel(.init(
        store: KeychainPhoneStore(deviceName: UIDevice.current.name),
        direct: NWDirectLink(),
        cloud: CloudKitPhoneLink(),
        pairing: NWPairingDirect()
    ))

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    Task { await model.pair(url: url) }
                }
                .task { await model.start() }
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
