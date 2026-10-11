import AppKit

/// Remote notifications: CloudKit sends a silent push when the phone writes a
/// command, so the Mac answers without waiting for its next poll.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onCloudPush: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in AppDelegate.onCloudPush?() }
    }
}
