import CloudKit
import DarraOwlPhoneKit
import DarraOwlShared
import UIKit
import UserNotifications

/// Notifications from the Mac's events, and their +1 h / Arrêter buttons.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var model: PhoneModel? { PhoneRuntime.shared.model }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: MacEvent.extendAction, title: "Prolonger d'1 h", options: [.authenticationRequired])
        let stop = UNNotificationAction(identifier: MacEvent.stopAction, title: "Arrêter la session", options: [.authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: MacEvent.sessionCategory, actions: [extend, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: MacEvent.infoCategory, actions: [], intentIdentifiers: []),
        ])
        application.registerForRemoteNotifications()
        WatchBridge.shared.activate()
        return true
    }

    /// Show the Mac's notifications even while the app is open, at once;
    /// the screen catches up right after.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await AppDelegate.model?.refreshFromCloud() }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let (macID, kind) = Self.eventFields(response.notification.request.content.userInfo)
        await PhoneRuntime.shared.handleNotificationAction(action, eventMacID: macID, eventKind: kind)
    }

    /// Which Mac and which kind of event a notification is about, from the
    /// fields CloudKit adds to it (nil for a notification of an older setup).
    nonisolated static func eventFields(_ userInfo: [AnyHashable: Any]) -> (UUID?, MacEvent.Kind?) {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = note.recordFields
        else { return (nil, nil) }
        return ((fields["macID"] as? String).flatMap(UUID.init(uuidString:)), (fields["kind"] as? String).flatMap(MacEvent.Kind.init(rawValue:)))
    }

    /// Silent part of an event push: refresh what the app shows, from
    /// iCloud even when a direct link looks open (it may be dead).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppDelegate.model?.refreshFromCloud()
        return .newData
    }
}

enum NotificationPermission {
    static func request() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}
