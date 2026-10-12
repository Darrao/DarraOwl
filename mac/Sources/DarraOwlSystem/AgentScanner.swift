import Darwin
import DarraOwlCore
import Foundation

/// Finds claude, codex and gemini processes of the current user: name from
/// the process table, arguments (KERN_PROCARGS2) for node-based CLIs, and
/// the working directory (PROC_PIDVNODEPATHINFO). Reads only.
public enum AgentScanner {
    public static func scan() -> [AgentProcess] {
        let uid = getuid()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride

        var candidates: [AgentDetector.Candidate] = []
        for e in entries.prefix(count) where e.kp_proc.p_stat != UInt8(SZOMB) {
            let name = withUnsafeBytes(of: e.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let pid = e.kp_proc.p_pid
            let versioned = AgentDetector.isVersionName(name)
            let interesting = AgentDetector.tools.contains(name) || name.hasPrefix("node") || name == "bun" || versioned
            guard interesting else { continue }
            let args = AgentDetector.tools.contains(name) ? [] : arguments(pid)
            let started = Date(timeIntervalSince1970: TimeInterval(e.kp_proc.p_starttime.tv_sec))
            candidates.append(.init(pid: pid, ppid: e.kp_eproc.e_ppid, name: name, arguments: args, cwd: cwd(pid),
                                    startedAt: started, path: versioned ? executablePath(pid) : nil))
        }
        return AgentDetector.agents(in: candidates)
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The executable's path (proc_pidpath).
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// argv of a process, argv[0] first: KERN_PROCARGS2 is argc, the
    /// executable path, then NUL-separated arguments.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var parts: [String] = []
        var current: [UInt8] = []
        var skippedPath = false
        for byte in buffer[4..<size] {
            if byte == 0 {
                if !current.isEmpty {
                    if skippedPath { parts.append(String(decoding: current, as: UTF8.self)) } else { skippedPath = true }
                    current = []
                    if parts.count == Int(argc) { break }
                }
            } else {
                current.append(byte)
            }
        }
        return parts
    }
}

/// Bearer token of the local hook endpoint, kept in the Keychain.
@MainActor
public enum HookToken {
    static let service = "com.darrao.darraowl.hooks"

    /// The token, created the first time. nil when the Keychain does not
    /// answer (locked, error): a token that could not be saved would make
    /// every hook fail with 401 after the next launch.
    public static func current() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "claude",
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) {
            return s
        }
        guard status == errSecItemNotFound else { return nil }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { return nil }
        return token
    }

    public static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }
}
