import Foundation

/// Adds DarraOwl's hooks to Claude Code's settings.json and takes them out
/// again, leaving everything else as it was. Works on the file's bytes. Pure.
public enum ClaudeHookConfig {
    /// Stop ends the main agent's turn only; SubagentStop, a subagent's.
    public static let events = ["Stop", "SubagentStop", "Notification", "PermissionRequest"]
    /// A permission request waits for the phone, an hour at most; the
    /// others are answered at once.
    public static let permissionTimeout = 3600

    public enum State: Equatable, Sendable {
        case absent
        case installed
        /// Present with another token, or not for every event (an earlier
        /// version's).
        case outdated
    }

    public enum ConfigError: Error, Equatable, Sendable, LocalizedError {
        case unreadable
        case unexpectedShape(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "settings.json n'est pas un JSON lisible : rien n'a été modifié."
            case let .unexpectedShape(key): "settings.json : « \(key) » n'a pas la forme attendue, rien n'a été modifié."
            }
        }
    }

    public static func url(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/hooks/claude"
    }

    static func entry(port: UInt16, token: String, event: String) -> [String: Any] {
        let timeout = event == "PermissionRequest" ? permissionTimeout : 5
        return ["type": "http", "url": url(port: port), "timeout": timeout, "headers": ["Authorization": "Bearer \(token)"]]
    }

    public static func state(_ data: Data?, port: UInt16, token: String) -> State {
        guard let data, let root = try? object(data), let hooks = root["hooks"] as? [String: Any] else { return .absent }
        var found = 0
        var current = 0
        for event in events {
            for group in hooks[event] as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isOurs(hook, port: port) {
                    found += 1
                    let auth = (hook["headers"] as? [String: Any])?["Authorization"] as? String
                    if auth == "Bearer \(token)" { current += 1 }
                }
            }
        }
        if found == 0 { return .absent }
        return found == events.count && current == events.count ? .installed : .outdated
    }

    /// The file with our hooks, replacing any earlier copy of them.
    public static func install(_ data: Data?, port: UInt16, token: String) throws(ConfigError) -> Data {
        var root = try data.map { d throws(ConfigError) in try object(d) } ?? [:]
        try strip(&root, port: port)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [entry(port: port, token: token, event: event)]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encode(root)
    }

    /// The file without our hooks. Empty lists we leave behind are removed.
    public static func remove(_ data: Data, port: UInt16) throws(ConfigError) -> Data {
        var root = try object(data)
        try strip(&root, port: port)
        return try encode(root)
    }

    /// One of our hooks is in the file, whatever its token.
    public static func hasOurs(_ data: Data, port: UInt16) -> Bool {
        state(data, port: port, token: "") != .absent
    }

    static func isOurs(_ hook: [String: Any], port: UInt16) -> Bool {
        hook["type"] as? String == "http" && hook["url"] as? String == url(port: port)
    }

    private static func strip(_ root: inout [String: Any], port: UInt16) throws(ConfigError) {
        guard let value = root["hooks"] else { return }
        guard var hooks = value as? [String: Any] else { throw .unexpectedShape("hooks") }
        for event in events {
            guard let value = hooks[event] else { continue }
            guard let groups = value as? [[String: Any]] else { throw .unexpectedShape("hooks.\(event)") }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let list = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)
                    continue
                }
                let others = list.filter { !isOurs($0, port: port) }
                if others.isEmpty, !list.isEmpty { continue }
                group["hooks"] = others
                kept.append(group)
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
    }

    private static func object(_ data: Data) throws(ConfigError) -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data), let root = parsed as? [String: Any] else {
            throw .unreadable
        }
        return root
    }

    private static func encode(_ root: [String: Any]) throws(ConfigError) -> Data {
        guard var data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw .unreadable
        }
        data.append(0x0A)
        return data
    }
}
