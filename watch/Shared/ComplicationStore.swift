import Foundation
import WidgetKit

/// What the complications show, written by the watch app into the app group.
struct ComplicationSnapshot: Codable, Equatable {
    var macName: String
    var online: Bool
    var sessionStartedAt: Date?
    var sessionEndsAt: Date?
    /// Agent mode: "tant que claude · DarraOwl tourne".
    var following: String?
    var battery: Int?
    var charging: Bool
    var updatedAt: Date

    static let placeholder = ComplicationSnapshot(
        macName: "Mac", online: true, sessionStartedAt: Date().addingTimeInterval(-1800), sessionEndsAt: Date().addingTimeInterval(5400),
        following: nil, battery: 82, charging: false, updatedAt: Date()
    )
}

enum ComplicationStore {
    static let group = "group.com.darrao.darraowl"
    static let key = "complicationSnapshot"

    static func save(_ snapshot: ComplicationSnapshot) {
        guard let defaults = UserDefaults(suiteName: group), let data = try? JSONEncoder().encode(snapshot) else { return }
        if defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func load() -> ComplicationSnapshot? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }
}
