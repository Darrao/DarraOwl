import Darwin
import Foundation

/// The file this process was started from. An update deletes and replaces
/// it; the running process then no longer matches anything on disk and
/// fails every client's code signing check.
struct BinaryIdentity {
    let path: String
    let inode: ino_t
    let device: dev_t

    static func current() -> BinaryIdentity? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return BinaryIdentity(path: path, inode: st.st_ino, device: st.st_dev)
    }

    /// True when the path now names another file, or nothing.
    func wasReplaced() -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return true }
        return st.st_ino != inode || st.st_dev != device
    }
}
