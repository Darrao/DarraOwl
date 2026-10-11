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
        /// Agent mode: "claude · DarraOwl".
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

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
