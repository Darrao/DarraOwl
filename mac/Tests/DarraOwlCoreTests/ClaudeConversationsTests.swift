@testable import DarraOwlCore
import Foundation
import Testing

/// `darraowl claude --list`, `--continue`, `--resume`: Claude Code's
/// conversations, read from transcripts in a temporary folder.
@Suite struct ClaudeConversationsTests {
    /// As Claude names a folder's transcripts: by UTF-16 unit, a long name
    /// cut and followed by a hash.
    @Test func foldersAreNamedAsClaudeDoes() {
        #expect(ClaudeConversations.encoded("/Users/elio/.gemini/antigravity/scratch/HoneyGiRead") == "-Users-elio--gemini-antigravity-scratch-HoneyGiRead")
        #expect(ClaudeConversations.encoded("/Users/me/Dev/café 🦉") == "-Users-me-Dev-caf----")
        #expect(ClaudeConversations.encoded("/Users/me/Projets/Cafe\u{301}") == "-Users-me-Projets-Caf-", "composed, as Claude names it")
        let long = ClaudeConversations.encoded("/Users/me/" + String(repeating: "projet-", count: 40))
        #expect(long.count == 207)
        #expect(long.hasSuffix("-m8mtr5"))
    }

    /// The last folder and the last title given win; a subagent's records
    /// and a cut line are left out.
    @Test func folderAndTitleComeFromTheRecords() {
        let head = lines([
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"Premier titre","sessionId":"s"}"#,
            #"{"type":"user","cwd":"/Users/me/Dev/api","sessionId":"s","message":{"content":"secret prompt"}}"#,
        ])
        let tail = lines([
            #"t":"cut line"}"#,
            #"{"type":"custom-title","customTitle":"Revue\nde l'API\u0007","sessionId":"s"}"#,
            #"{"type":"relocated","relocatedCwd":"/Users/me/Dev/api-v2","sessionId":"s"}"#,
            #"{"type":"user","cwd":"/Users/me/Dev/api-v2/.claude/worktrees/x","isSidechain":true,"sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"Titre automatique","sessionId":"s"}"#,
        ])
        let found = ClaudeConversations.summary(head: head, tail: tail)
        #expect(found.folders == ["/Users/me/Dev/api", "/Users/me/Dev/api-v2"])
        #expect(found.title == "Revue de l'API", "a title the user gave beats Claude's")
        let automatic = ClaudeConversations.summary(head: head, tail: nil)
        #expect(automatic.folders == ["/Users/me/Dev/api"])
        #expect(automatic.title == "Premier titre")
        let empty = ClaudeConversations.summary(head: Data("{}\n".utf8), tail: nil)
        #expect(empty.folders.isEmpty && empty.title == nil)
    }

    /// Where Claude files it: not where its shell went last, nor where it
    /// was before being moved.
    @Test func theFolderIsTheOneItIsFiledUnder() {
        let api = ClaudeConversations.encoded("/Users/me/Dev/api")
        #expect(ClaudeConversations.folder(of: ["/Users/me/Dev/api", "/Users/me/Dev/api/ios", "/tmp"], filedUnder: api) == "/Users/me/Dev/api")
        let moved = ClaudeConversations.encoded("/Users/me/Dev/api-v2")
        #expect(ClaudeConversations.folder(of: ["/Users/me/Dev/api", "/Users/me/Dev/api-v2", "/Users/me/Dev/api-v2/x"], filedUnder: moved) == "/Users/me/Dev/api-v2")
        // Its start unread, its shell below it then elsewhere: the folder above.
        #expect(ClaudeConversations.folder(of: ["/Users/me/Dev/api/ios/App", "/tmp"], filedUnder: api) == "/Users/me/Dev/api")
        #expect(ClaudeConversations.folder(of: ["/a", "/b"], filedUnder: "-elsewhere") == nil, "never a folder Claude would not find it from")
        #expect(ClaudeConversations.folder(of: [], filedUnder: api) == nil)
        #expect(ClaudeConversations.oneLine(String(repeating: "a", count: 90)).count == 80)
    }

    @Test func theLatestComeFirstAndAFolderKeepsItsOwn() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try write(root, "/Users/me/Dev/api", id: Self.ids[0], title: "Ancienne", at: now.addingTimeInterval(-7200))
        try write(root, "/Users/me/Dev/api", id: Self.ids[1], title: "Récente", at: now.addingTimeInterval(-60))
        try write(root, "/Users/me/Dev/site", id: Self.ids[2], title: "Site", at: now.addingTimeInterval(-600))
        // Not a conversation: another name, a subagent's folder.
        try Data("{}".utf8).write(to: root.appending(path: ClaudeConversations.encoded("/Users/me/Dev/api")).appending(path: "notes.jsonl"))
        try FileManager.default.createDirectory(at: root.appending(path: ClaudeConversations.encoded("/Users/me/Dev/api")).appending(path: Self.ids[1]),
                                                withIntermediateDirectories: true)

        let all = ClaudeConversations.recent(in: root, limit: 10)
        #expect(all.map(\.title) == ["Récente", "Site", "Ancienne"])
        #expect(all.first?.folder == "/Users/me/Dev/api")
        #expect(ClaudeConversations.recent(in: root, limit: 2).count == 2)
        #expect(ClaudeConversations.recent(in: root, folder: "/Users/me/Dev/api", limit: 10).map(\.id) == [Self.ids[1], Self.ids[0]])
        #expect(ClaudeConversations.recent(in: root, folder: "/Users/me/Dev/rien", limit: 10).isEmpty)
        #expect(ClaudeConversations.recent(in: root.appending(path: "absent"), limit: 10).isEmpty)
    }

    /// Dated by its last message, not by the file: the Claude app writes
    /// titles into old transcripts. Filed twice, listed once.
    @Test func theLastMessageDatesAConversation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try write(root, "/Users/me/Dev/old", id: Self.ids[0], title: "Juin", at: now, message: "2026-06-02T09:30:00.250Z")
        try write(root, "/Users/me/Dev/new", id: Self.ids[2], title: "Hier", at: now.addingTimeInterval(-3600), message: "2026-10-22T18:00:00Z")
        try write(root, "/Users/me/Dev/moved", id: Self.ids[2], title: "Hier", at: now.addingTimeInterval(-7200), message: "2026-10-22T17:00:00Z")
        let all = ClaudeConversations.recent(in: root, limit: 10)
        #expect(all.map(\.title) == ["Hier", "Juin"])
        #expect(all.first?.folder == "/Users/me/Dev/new", "the copy used last")
        #expect(all.last?.lastActive == Date(timeIntervalSince1970: 1_780_392_600.25))
        let cut = Data(#"p":"2020-01-01T00:00:00Z"}"#.utf8) + Data("\n".utf8)
            + Data(#"{"type":"user","timestamp":"2026-10-23T08:00:00Z"}"#.utf8) + Data("\n".utf8)
            + Data(#"{"type":"custom-title","customTitle":"x"}"#.utf8) + Data("\n".utf8)
        #expect(ClaudeConversations.lastMessage(in: cut, cut: true) == Date(timeIntervalSince1970: 1_792_742_400))
        #expect(ClaudeConversations.lastMessage(in: Data(#"{"type":"mode"}"#.utf8), cut: false) == nil)
        let linked = Data(#"{"type":"assistant","timestamp":"2026-10-23T08:00:00Z"}"#.utf8) + Data("\n".utf8)
            + Data(#"{"type":"pr-link","timestamp":"2026-10-30T08:00:00Z"}"#.utf8) + Data("\n".utf8)
        #expect(ClaudeConversations.lastMessage(in: linked, cut: false) == Date(timeIntervalSince1970: 1_792_742_400), "a link added later is no message")
    }

    /// By the start of its id, in any case; too short to tell is no choice.
    @Test func aConversationIsFoundByTheStartOfItsID() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (i, id) in Self.ids.enumerated() {
            try write(root, "/Users/me/Dev/p\(i)", id: id, title: "T\(i)", at: Date().addingTimeInterval(Double(-i * 60)))
        }
        guard case let .found(conversation) = ClaudeConversations.find("3F9A2C1B", in: root) else {
            Issue.record("not found")
            return
        }
        #expect(conversation.id == Self.ids[0] && conversation.folder == "/Users/me/Dev/p0")
        #expect(ClaudeConversations.find("3f9a2c", in: root) == .several)
        #expect(ClaudeConversations.find("ffffff", in: root) == .none)
        #expect(ClaudeConversations.isIDPrefix("3f9a2c") && ClaudeConversations.isIDPrefix(Self.ids[0]))
        #expect(!ClaudeConversations.isIDPrefix("3f9a2") && !ClaudeConversations.isIDPrefix("zzzzzz") && !ClaudeConversations.isIDPrefix(Self.ids[0] + "0"))
    }

    @Test func theListingFitsAPhone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_756_800) // 2026-10-23 12:00 UTC
        let conversations = [
            ClaudeConversations.Conversation(id: Self.ids[0], folder: "/Users/me/Dev/api", title: "Revue", lastActive: now.addingTimeInterval(-3600)),
            ClaudeConversations.Conversation(id: Self.ids[2], folder: nil, title: nil, lastActive: now.addingTimeInterval(-86_400)),
            ClaudeConversations.Conversation(id: Self.ids[3], folder: "/opt/x", title: "Vieille", lastActive: now.addingTimeInterval(-400 * 86_400)),
        ]
        let text = ClaudeConversations.listing(conversations, open: [Self.ids[0]], home: "/Users/me", now: now, calendar: calendar)
        #expect(text.contains("3f9a2c1b · aujourd'hui 11:00 · ouverte\n~/Dev/api\nRevue"))
        #expect(text.contains("a1cd24d5 · hier 12:00\ndossier inconnu\n(sans titre)"))
        #expect(text.contains("2025"))
        #expect(ClaudeConversations.shown("/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b", home: "/Users/me") == "app Claude, sans dossier")
        #expect(text.hasSuffix("Reprendre : darraowl claude --resume a1cd24d5"), "the first one not open")
        #expect(ClaudeConversations.openIDs(agentsJSON: Data(#"[{"pid":1,"sessionId":"a","kind":"interactive"},{"pid":2}]"#.utf8)) == ["a"])
        #expect(ClaudeConversations.openIDs(agentsJSON: Data("oops".utf8)) == nil)
    }

    // MARK: Helpers

    static let ids = [
        "3f9a2c1b-0000-4000-8000-000000000001",
        "3f9a2c1c-0000-4000-8000-000000000002",
        "a1cd24d5-0000-4000-8000-000000000003",
        "55901c51-0000-4000-8000-000000000004",
    ]

    private func lines(_ records: [String]) -> Data {
        Data(records.map { $0 + "\n" }.joined().utf8)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "darraowl-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ folder: String, id: String, title: String, at date: Date, message: String? = nil) throws {
        let dir = root.appending(path: ClaudeConversations.encoded(folder))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(id).jsonl")
        try lines([
            #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id)"}"#,
            #"{"type":"user","cwd":"\#(folder)","sessionId":"\#(id)"}"#,
            #"{"type":"user","cwd":"\#(folder)/sub","sessionId":"\#(id)"}"#,
        ] + (message.map { [#"{"type":"assistant","cwd":"\#(folder)","timestamp":"\#($0)","sessionId":"\#(id)"}"#] } ?? [])).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }
}
