import AppKit

/// Remote notifications: CloudKit sends a silent push when the phone writes a
/// command, so the Mac answers without waiting for its next poll.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onCloudPush: (() -> Void)?
    /// Ends the running session, if any; set by the app.
    @MainActor static var stopSessionBeforeQuitting: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in AppDelegate.onCloudPush?() }
    }

    /// Quits from the app itself (menu, update): the session is stopped
    /// first, then the app quits at once. Called from a task on the main
    /// actor, `terminate` would otherwise wait in a nested loop for an
    /// answer that the same main actor can never give, for good.
    @MainActor
    static func quit() {
        Task { @MainActor in
            if let stop = stopSessionBeforeQuitting {
                stopSessionBeforeQuitting = nil
                await stop()
            }
            NSApp.terminate(nil)
        }
    }

    /// However the app is quit (menu, Apple Event, logout), the session ends
    /// with it, as the menu promises.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stop = AppDelegate.stopSessionBeforeQuitting else { return .terminateNow }
        AppDelegate.stopSessionBeforeQuitting = nil
        Task { @MainActor in
            await stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
