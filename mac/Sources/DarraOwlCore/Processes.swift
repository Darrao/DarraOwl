import Foundation

/// Recognises the same process later: a pid alone can be reused.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var startSeconds: Int64
    public var startMicros: Int32
    /// `kern.bootsessionuuid`: a fresh value per boot.
    public var bootSession: String

    public init(startSeconds: Int64, startMicros: Int32, bootSession: String) {
        self.startSeconds = startSeconds
        self.startMicros = startMicros
        self.bootSession = bootSession
    }
}

public struct ProcessState: Equatable, Sendable {
    public var ppid: Int32
    public var uid: UInt32
    public var stopped: Bool
    public var identity: ProcessIdentity

    public init(ppid: Int32, uid: UInt32, stopped: Bool, identity: ProcessIdentity) {
        self.ppid = ppid
        self.uid = uid
        self.stopped = stopped
        self.identity = identity
    }
}

public enum ProcessLookup: Equatable, Sendable {
    case absent
    /// The kernel did not answer; nothing can be concluded.
    case unreadable(Int32)
    case present(ProcessState)
}

/// Kernel process table and signals. Live: sysctl and kill(2). Tests: a fake.
public protocol ProcessControlling: Sendable {
    func lookup(_ pid: Int32) -> ProcessLookup
    /// 0 on success, the errno otherwise.
    func signal(_ pid: Int32, _ signal: Int32) -> Int32
}

/// One process the app asks the helper to pause, with the identity it read.
public struct FreezeTarget: Codable, Equatable, Sendable {
    public var pid: Int32
    public var identity: ProcessIdentity

    public init(pid: Int32, identity: ProcessIdentity) {
        self.pid = pid
        self.identity = identity
    }
}

/// An app and every process it started.
public struct FreezeGroup: Codable, Equatable, Sendable {
    /// Bundle id, or `PausePolicy.dockerBundleID` for Docker Desktop.
    public var bundleID: String
    public var name: String
    public var targets: [FreezeTarget]

    public init(bundleID: String, name: String, targets: [FreezeTarget]) {
        self.bundleID = bundleID
        self.name = name
        self.targets = targets
    }
}

/// A process the helper stopped, journaled before the SIGSTOP.
public struct FrozenProcess: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var identity: ProcessIdentity
    public var bundleID: String
    public var name: String

    public init(pid: Int32, identity: ProcessIdentity, bundleID: String, name: String) {
        self.pid = pid
        self.identity = identity
        self.bundleID = bundleID
        self.name = name
    }
}

public enum ProcessTree {
    /// `root` followed by every descendant, breadth first, from a pid → ppid map.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parents where pid != ppid {
            children[ppid, default: []].append(pid)
        }
        var result: [Int32] = []
        var queue = [root]
        var seen: Set<Int32> = []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: (children[pid] ?? []).sorted())
        }
        return result
    }
}
