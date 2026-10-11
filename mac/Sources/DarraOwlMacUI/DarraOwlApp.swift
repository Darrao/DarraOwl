import AppKit
import SwiftUI

struct DarraOwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
                .task {
                    AppDelegate.onCloudPush = { [model] in model.remote.cloudChanged() }
                    model.start()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

        Window("iPhone", id: "pairing") {
            PairingView(model: model, remote: model.remote)
        }
        .windowResizability(.contentSize)
    }
}

/// Entry point shared by the Xcode app target and `swift build`.
public enum DarraOwlEntry {
    @MainActor
    public static func main() {
        if CommandLine.arguments.contains("--self-check") {
            Task { @MainActor in exit(await SelfCheck.run()) }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--uninstall") {
            Task { @MainActor in
                let code = await Uninstaller.run()
                exit(code)
            }
            RunLoop.main.run()
        }
        DarraOwlApp.main()
    }
}
