import Foundation

/// Claude Code's conversations on this Mac, from its transcripts
/// (`~/.claude/projects/<folder>/<id>.jsonl`, written by the Claude app and
/// the claude command alike): for `darraowl claude --list`, `--continue` and
/// `--resume`. Only a conversation's folder and title are read, from the
/// start and the end of its transcript, as Claude itself does.
public enum ClaudeConversations {
    public struct Conversation: Equatable, Sendable {
        public let id: String
        /// The folder it belongs to (a conversation can be moved to another one).
        public let folder: String?
        public let title: String?
        /// Its last message (the transcript's date when none is read).
        public let lastActive: Date

        public init(id: String, folder: String?, title: String?, lastActive: Date) {
            self.id = id
            self.folder = folder
            self.title = title
            self.lastActive = lastActive
        }
    }

    /// The latest first, at most `limit`; only the folder's when given.
    public static func recent(in root: URL, folder: String? = nil, limit: Int) -> [Conversation] {
        var found: [Conversation] = []
        var seen: Set<String> = []
        for transcript in latestFirst(transcripts(in: root, folder: folder)) {
            guard found.count < limit else { break }
            // A conversation filed twice (moved): its latest copy only.
            guard seen.insert(transcript.id).inserted else { continue }
            var conversation = read(transcript)
            if let folder {
                // Unread, its folder is the one its transcript is filed under.
                guard conversation.folder == nil || conversation.folder == folder else { continue }
                conversation = Conversation(id: conversation.id, folder: folder, title: conversation.title, lastActive: conversation.lastActive)
            }
            found.append(conversation)
        }
        return found
    }

    public enum Lookup: Equatable, Sendable {
        case found(Conversation)
        case none
        case several
    }

    /// The conversation whose id starts with `prefix` (any case).
    public static func find(_ prefix: String, in root: URL) -> Lookup {
        let start = prefix.lowercased()
        let matches = latestFirst(transcripts(in: root, folder: nil).filter { $0.id.lowercased().hasPrefix(start) })
        // One conversation can sit in two folders (moved): the latest copy.
        guard let first = matches.first else { return .none }
        guard matches.allSatisfy({ $0.id == first.id }) else { return .several }
        return .found(read(first))
    }

    /// What `--resume` accepts: the start of an id, at least 6 characters.
    public static func isIDPrefix(_ text: String) -> Bool {
        text.count >= 6 && text.count <= 36 && text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The id as the listing shows it.
    public static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// Ids of the conversations open on this Mac, from `claude agents --json`.
    public static func openIDs(agentsJSON data: Data) -> Set<String>? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return Set(list.compactMap { $0["sessionId"] as? String })
    }

    // MARK: Listing

    /// Phone-sized: each conversation on three lines, then how to take one up.
    public static func listing(_ conversations: [Conversation], open: Set<String>, home: String, now: Date, calendar: Calendar) -> String {
        var lines = ["Conversations Claude Code, la plus récente en haut :"]
        for c in conversations {
            var head = "\(shortID(c.id)) · \(when(c.lastActive, now: now, calendar: calendar))"
            if open.contains(c.id) { head += " · ouverte" }
            lines += ["", head, c.folder.map { shown($0, home: home) } ?? "dossier inconnu", c.title ?? "(sans titre)"]
        }
        if let first = conversations.first(where: { !open.contains($0.id) }) ?? conversations.first {
            lines += ["", "Reprendre : darraowl claude --resume \(shortID(first.id))"]
        }
        return lines.joined(separator: "\n")
    }

    /// "~/Dev/api"; a conversation the Claude app started without a folder
    /// lives in one of the app's own, named as the app does.
    public static func shown(_ folder: String, home: String) -> String {
        folder.hasPrefix(home + "/Library/Application Support/Claude/scratch-workspaces/")
            ? "app Claude, sans dossier" : TerminalSession.shown(folder, home: home)
    }

    /// "aujourd'hui 14:05", "hier 18:20", "13 oct. 09:12", "13 oct. 2025".
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "fr_FR")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "HH:mm"
        let time = format.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd'hui \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier \(time)"
        }
        format.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM HH:mm" : "d MMM yyyy"
        return format.string(from: date)
    }

    // MARK: Transcripts

    struct Transcript {
        let url: URL
        let id: String
        let lastActive: Date
    }

    /// Claude's folder name for a working directory: every character but a
    /// letter or a digit becomes "-"; a long one is cut, and a hash added.
    static func encoded(_ path: String) -> String {
        // Composed, as Claude takes it (macOS gives "é" decomposed), then by
        // UTF-16 unit, as Claude (JavaScript) counts them.
        let path = path.precomposedStringWithCanonicalMapping
        let name = String(decoding: path.utf16.map { unit -> UInt8 in
            let letterOrDigit = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            return letterOrDigit ? UInt8(unit) : UInt8(ascii: "-")
        }, as: UTF8.self)
        guard name.count > encodedLimit else { return name }
        var hash: Int32 = 0
        for unit in path.utf16 { hash = (hash << 5) &- hash &+ Int32(unit) }
        return "\(name.prefix(encodedLimit))-\(String(hash.magnitude, radix: 36))"
    }

    static let encodedLimit = 200

    /// Dated by the file. With a folder, only those of its transcript folder
    /// (a long name ends with a hash: those starting the same way).
    static func transcripts(in root: URL, folder: String?) -> [Transcript] {
        let files = FileManager.default
        let wanted = folder.map(encoded)
        func accepts(_ name: String) -> Bool {
            guard let wanted else { return true }
            if name == wanted { return true }
            return wanted.count > encodedLimit && name.hasPrefix(String(wanted.prefix(encodedLimit)) + "-")
        }
        guard let folders = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var all: [Transcript] = []
        for folder in folders where accepts(folder.lastPathComponent) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            guard let items = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { continue }
            for item in items where item.pathExtension == "jsonl" {
                guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                let id = item.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                all.append(Transcript(url: item, id: id, lastActive: values.contentModificationDate ?? .distantPast))
            }
        }
        return all
    }

    /// By their last message: the Claude app also writes to old transcripts
    /// (titles), which dates the file itself today.
    static func latestFirst(_ transcripts: [Transcript]) -> [Transcript] {
        transcripts.map { Transcript(url: $0.url, id: $0.id, lastActive: lastMessage($0.url) ?? $0.lastActive) }
            .sorted { $0.lastActive > $1.lastActive }
    }

    /// The date of its last message, read from the end: a few kilobytes, a
    /// whole window when its last lines are long.
    static func lastMessage(_ url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        for span in [UInt64(1 << 16), UInt64(window)] {
            let start = size > span ? size - span : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
            if let date = lastMessage(in: data, cut: start > 0) { return date }
            if start == 0 { return nil }
        }
        return nil
    }

    /// `cut`: the data starts mid-line, its first line is incomplete.
    static func lastMessage(in data: Data, cut: Bool) -> Date? {
        var all = lines(of: data)
        if cut, !all.isEmpty { all.removeFirst() }
        for line in all.reversed() {
            guard line.range(of: Data("\"timestamp\"".utf8)) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  // Not the links Claude adds later (pull request, app), dated when added.
                  ["user", "assistant"].contains(record["type"] as? String),
                  let text = record["timestamp"] as? String,
                  let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                      ?? (try? Date.ISO8601FormatStyle().parse(text)) else { continue }
            return date
        }
        return nil
    }

    /// What is read of a transcript, at each end: a few records, whatever
    /// its size (some reach hundreds of megabytes).
    static let window = 1 << 20

    static func read(_ transcript: Transcript) -> Conversation {
        var head = Data()
        var tail = Data()
        var whole = false
        if let handle = try? FileHandle(forReadingFrom: transcript.url) {
            defer { try? handle.close() }
            head = (try? handle.read(upToCount: window)) ?? Data()
            let size = (try? handle.seekToEnd()) ?? 0
            whole = size <= UInt64(window)
            if !whole {
                try? handle.seek(toOffset: size - UInt64(window))
                tail = (try? handle.read(upToCount: window)) ?? Data()
            }
        }
        let found = summary(head: head, tail: whole ? nil : tail)
        let filed = transcript.url.deletingLastPathComponent().lastPathComponent
        return Conversation(id: transcript.id, folder: folder(of: found.folders, filedUnder: filed), title: found.title, lastActive: transcript.lastActive)
    }

    /// The folder Claude files the conversation under, where it is taken up
    /// again: its records also follow the cd's of its shell, below it or
    /// elsewhere. None when no record leads to it: from another folder,
    /// Claude would not find the conversation.
    static func folder(of folders: [String], filedUnder name: String) -> String? {
        if let named = folders.last(where: { encoded($0) == name }) { return named }
        // Its start unread (a long first message), its shell below it.
        for recorded in folders.reversed() {
            var above = (recorded as NSString).deletingLastPathComponent
            while above.count > 1 {
                if encoded(above) == name { return above }
                above = (above as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    /// The folders the records name, in order (where it started, where it
    /// was moved, where its shell went), and the title: the last one given
    /// wins, the user's over Claude's. `tail` is nil when `head` is the whole
    /// transcript; otherwise its first line, cut, is skipped.
    static func summary(head: Data, tail: Data?) -> (folders: [String], title: String?) {
        let late = tail.map { Array(lines(of: $0).dropFirst()) } ?? []
        // A head cut mid-line: that line is incomplete.
        var early = lines(of: head)
        if tail != nil, head.last != UInt8(ascii: "\n") { early = Array(early.dropLast()) }
        var folders: [String] = []
        func add(_ folder: String) {
            if folders.last != folder { folders.append(folder) }
        }
        var custom: String?
        var automatic: String?
        for line in (early + late) {
            guard line.range(of: Data("\"cwd\"".utf8)) != nil || line.range(of: Data("title\"".utf8)) != nil
                || line.range(of: Data("\"relocated\"".utf8)) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  // A subagent's records: its folder can be a worktree of its own.
                  record["isSidechain"] as? Bool != true else { continue }
            switch record["type"] as? String {
            case "custom-title": if let t = record["customTitle"] as? String { custom = t }
            case "ai-title": if let t = record["aiTitle"] as? String { automatic = t }
            case "relocated": if let to = record["relocatedCwd"] as? String { add(to) }
            default: if let cwd = record["cwd"] as? String { add(cwd) }
            }
        }
        return (folders, (custom ?? automatic).map(oneLine).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    /// A title on one line, without control characters, at most 80 characters.
    static func oneLine(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        line.unicodeScalars.removeAll { [.control, .format].contains($0.properties.generalCategory) }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
