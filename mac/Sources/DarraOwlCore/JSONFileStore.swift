import Foundation

public enum StoreError: Error, Equatable, Sendable, LocalizedError {
    /// The file exists but cannot be read or decoded.
    case unreadable(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(m): "fichier illisible : \(m)"
        case let .writeFailed(m): "écriture impossible : \(m)"
        }
    }
}

/// Where a JSON value lives on disk. `InMemoryStore` in tests.
public protocol ValueStoring<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    /// nil when there is no file yet. Throws `StoreError.unreadable` when the
    /// file is there but cannot be decoded.
    func load() throws(StoreError) -> Value?
    func save(_ value: Value) throws(StoreError)
    /// Renames an unreadable file aside (never deletes it) and returns the new path.
    func quarantine() throws(StoreError) -> String?
    func remove() throws(StoreError)
}

/// One JSON file, owner-only (0600) in an owner-only directory (0700),
/// replaced atomically on every write.
public struct JSONFileStore<Value: Codable & Sendable>: ValueStoring {
    public let url: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, fileName: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = directory.appending(path: fileName)
        self.now = now
    }

    public func load() throws(StoreError) -> Value? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func save(_ value: Value) throws(StoreError) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try Self.encoder.encode(value)
            let tmp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            try Self.writeDurably(data, to: tmp.path)
            // rename(2) replaces the destination atomically.
            guard rename(tmp.path, url.path) == 0 else {
                let code = errno
                try? fm.removeItem(at: tmp)
                throw StoreError.writeFailed("rename: \(String(cString: strerror(code)))")
            }
            // The rename itself reaches the disk too.
            let dfd = open(dir.path, O_RDONLY)
            if dfd >= 0 {
                _ = fsync(dfd)
                close(dfd)
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw .writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Writes and flushes to the disk (F_FULLFSYNC) before the rename: after
    /// a power loss the journal is the old one or the new one, never empty.
    static func writeDurably(_ data: Data, to path: String) throws(StoreError) {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw .writeFailed("création : \(String(cString: strerror(errno)))") }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += n
            }
        }
        let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        close(fd)
        guard ok, synced else {
            unlink(path)
            throw .writeFailed("écriture sur le disque")
        }
    }

    public func quarantine() throws(StoreError) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        var target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)-\(n)")
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw .writeFailed("mise de côté de \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return target.path
    }

    public func remove() throws(StoreError) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw .writeFailed("suppression de \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
