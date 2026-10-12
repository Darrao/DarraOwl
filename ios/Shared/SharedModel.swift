import ActivityKit
import Foundation
import WidgetKit

/// The Live Activity: lock screen and Dynamic Island while a session runs.
struct DarraOwlActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endsAt: Date
        var battery: Int?
        var charging: Bool
        var lidClosed: Bool
        var agentsRunning: Int
        var agentsWaiting: Int
        var online: Bool
        /// Agent mode: "tant que claude · DarraOwl tourne".
        var following: String?
    }

    var macName: String
}

/// What the widgets show, written by the app into the shared app group.
struct WidgetSnapshot: Codable, Equatable {
    var macName: String
    /// "En ligne", "En veille depuis 18:42", "Vu à 18:42".
    var presence: String
    var online: Bool
    var sessionEndsAt: Date?
    var battery: Int?
    var charging: Bool
    var agentsRunning: Int
    var agentsWaiting: Int
    var updatedAt: Date
    /// The Mac's cap on a session, for "+1 h" from the lock screen when the
    /// app starts with nothing loaded.
    var maxSessionDuration: TimeInterval? = nil

    static let placeholder = WidgetSnapshot(macName: "Mac", presence: "En ligne", online: true,
                                            sessionEndsAt: Date().addingTimeInterval(5400), battery: 82, charging: false,
                                            agentsRunning: 1, agentsWaiting: 0, updatedAt: Date())
}

enum SharedStore {
    static let group = "group.com.darrao.darraowl"
    static let key = "widgetSnapshot"

    static func save(_ snapshot: WidgetSnapshot) {
        guard let defaults = UserDefaults(suiteName: group), let data = try? JSONEncoder().encode(snapshot) else { return }
        if defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Unpaired: the widgets show the "open DarraOwl" placeholder again.
    static func clear() {
        guard let defaults = UserDefaults(suiteName: group), defaults.data(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
