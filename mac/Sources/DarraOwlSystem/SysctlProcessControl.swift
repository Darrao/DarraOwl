// Process table reads adapted from Insomnia (https://github.com/krishhgg/Insomnia),
// MIT License, Copyright (c) 2026 Krish Garg. See THIRD_PARTY_NOTICES.md.

import Darwin
import DarraOwlCore
import Foundation

/// The kernel process table (sysctl KERN_PROC, as `ps` reads it) and kill(2).
/// Answers for every user's processes.
public struct SysctlProcessControl: ProcessControlling {
    public init() {}

    /// `kern.bootsessionuuid`: a fresh UUID per boot.
    public static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    public func lookup(_ pid: Int32) -> ProcessLookup {
        guard pid > 0 else { return .absent }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &entry, &size, nil, 0) == 0 else { return .unreadable(errno) }
        guard size == MemoryLayout<kinfo_proc>.stride, entry.kp_proc.p_pid == pid else { return .absent }
        guard entry.kp_proc.p_stat != UInt8(SZOMB) else { return .absent }
        return .present(Self.state(of: entry))
    }

    public func signal(_ pid: Int32, _ signal: Int32) -> Int32 {
        guard pid > 1 else { return EINVAL }
        return kill(pid, signal) == 0 ? 0 : errno
    }

    /// Every process of the system, keyed by pid. Used by the app to find an
    /// app's whole tree before asking the helper to pause it.
    public static func snapshot() -> [Int32: ProcessState] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        // Room for processes started between the two calls.
        size += size / 8
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var result: [Int32: ProcessState] = [:]
        for entry in entries.prefix(count) where entry.kp_proc.p_stat != UInt8(SZOMB) {
            result[entry.kp_proc.p_pid] = state(of: entry)
        }
        return result
    }

    /// Whether a process with this command name runs (the kernel keeps
    /// its first 16 characters).
    public static func isRunning(command: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
        size += size / 8
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return entries.prefix(count).contains { entry in
            guard entry.kp_proc.p_stat != UInt8(SZOMB) else { return false }
            var comm = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return name == command
        }
    }

    private static func state(of entry: kinfo_proc) -> ProcessState {
        let started = entry.kp_proc.p_starttime
        return ProcessState(
            ppid: entry.kp_eproc.e_ppid,
            uid: entry.kp_eproc.e_ucred.cr_uid,
            stopped: entry.kp_proc.p_stat == UInt8(SSTOP),
            identity: ProcessIdentity(
                startSeconds: Int64(started.tv_sec),
                startMicros: Int32(truncatingIfNeeded: started.tv_usec),
                bootSession: bootSession
            )
        )
    }
}
