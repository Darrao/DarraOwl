@testable import DarraOwlCore
import Foundation
import Testing

@Suite struct ClaudeHookConfigTests {
    let port: UInt16 = 52526

    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let existing = Data("""
    {
      "attribution": {"commit": "", "pr": "", "sessionUrl": false},
      "model": "opus",
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
        "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "prettier"}]}]
      }
    }
    """.utf8)

    @Test func installKeepsEverythingElse() throws {
        let out = try ClaudeHookConfig.install(existing, port: port, token: "abc")
        let root = try json(out)
        #expect(root["model"] as? String == "opus")
        #expect((root["attribution"] as? [String: Any])?["sessionUrl"] as? Bool == false)
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "say done")
        #expect((hooks["PostToolUse"] as? [[String: Any]])?.count == 1)
        #expect((hooks["Notification"] as? [[String: Any]])?.count == 1)
        #expect(ClaudeHookConfig.state(out, port: port, token: "abc") == .installed)
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        let once = try ClaudeHookConfig.install(existing, port: port, token: "abc")
        let twice = try ClaudeHookConfig.install(once, port: port, token: "abc")
        #expect(once == twice)
    }

    @Test func aNewTokenReplacesTheOld() throws {
        let old = try ClaudeHookConfig.install(existing, port: port, token: "old")
        #expect(ClaudeHookConfig.state(old, port: port, token: "new") == .outdated)
        let new = try ClaudeHookConfig.install(old, port: port, token: "new")
        #expect(ClaudeHookConfig.state(new, port: port, token: "new") == .installed)
        let stop = try #require((try json(new)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
    }

    @Test func removeGivesBackTheRest() throws {
        let installed = try ClaudeHookConfig.install(existing, port: port, token: "abc")
        let removed = try ClaudeHookConfig.remove(installed, port: port)
        let root = try json(removed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["Notification"] == nil)
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(ClaudeHookConfig.state(removed, port: port, token: "abc") == .absent)
        #expect(root["model"] as? String == "opus")
    }

    @Test func removeFromAFileWithOnlyOursLeavesNoHooksKey() throws {
        let installed = try ClaudeHookConfig.install(Data("{\"model\": \"opus\"}".utf8), port: port, token: "abc")
        let root = try json(try ClaudeHookConfig.remove(installed, port: port))
        #expect(root["hooks"] == nil)
        #expect(root["model"] as? String == "opus")
    }

    @Test func missingOrEmptyFile() throws {
        #expect(ClaudeHookConfig.state(nil, port: port, token: "abc") == .absent)
        let fromNothing = try ClaudeHookConfig.install(nil, port: port, token: "abc")
        #expect(ClaudeHookConfig.state(fromNothing, port: port, token: "abc") == .installed)
        let fromEmpty = try ClaudeHookConfig.install(Data("\n".utf8), port: port, token: "abc")
        #expect(fromEmpty == fromNothing)
    }

    @Test func refusesWhatItCannotRead() {
        #expect(throws: ClaudeHookConfig.ConfigError.unreadable) {
            try ClaudeHookConfig.install(Data("{ // comment\n}".utf8), port: port, token: "abc")
        }
        #expect(throws: ClaudeHookConfig.ConfigError.unreadable) {
            try ClaudeHookConfig.install(Data("[1, 2]".utf8), port: port, token: "abc")
        }
        #expect(throws: ClaudeHookConfig.ConfigError.unexpectedShape("hooks.Stop")) {
            try ClaudeHookConfig.install(Data("{\"hooks\": {\"Stop\": \"x\"}}".utf8), port: port, token: "abc")
        }
    }

    @Test func anotherPortIsNotOurs() throws {
        let other = Data("""
        {"hooks": {"Stop": [{"hooks": [{"type": "http", "url": "http://127.0.0.1:9999/hooks/claude"}]}]}}
        """.utf8)
        let removed = try json(try ClaudeHookConfig.remove(other, port: port))
        #expect(((removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 1)
    }
}
