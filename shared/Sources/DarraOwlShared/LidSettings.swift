import Foundation

/// What a lid close does during a session. Edited from the Mac (and the
/// phone from phase 3); enforced by the Mac.
public struct LidSettings: Codable, Equatable, Sendable {
    /// Display and keyboard backlight to 0, restored at lid open.
    public var darkenDisplay: Bool
    public var mute: Bool
    public var lowPower: Bool
    /// Bundle ids of apps paused (SIGSTOP) while the lid is closed.
    public var pausedApps: [String]
    /// Docker Desktop paused when no container runs.
    public var pauseDocker: Bool

    public init(
        darkenDisplay: Bool = true,
        mute: Bool = true,
        lowPower: Bool = true,
        pausedApps: [String] = LidSettings.defaultPausedApps,
        pauseDocker: Bool = true
    ) {
        self.darkenDisplay = darkenDisplay
        self.mute = mute
        self.lowPower = lowPower
        self.pausedApps = pausedApps
        self.pauseDocker = pauseDocker
    }

    public static let defaultPausedApps = [
        "com.tinyspeck.slackmacgap", // Slack
        "net.whatsapp.WhatsApp",     // WhatsApp
        "com.hnc.Discord",           // Discord
    ]

    public static let maxPausedApps = 30

    public enum ValidationError: Error, Equatable, Sendable {
        case tooManyApps
        case invalidBundleID(String)
        case protectedApp(String)
    }

    public func validate() throws(ValidationError) {
        guard pausedApps.count <= Self.maxPausedApps else { throw .tooManyApps }
        for id in pausedApps {
            guard PausePolicy.isWellFormedBundleID(id) else { throw .invalidBundleID(id) }
            guard !PausePolicy.isProtected(id) else { throw .protectedApp(id) }
        }
    }
}

/// Apps that are never paused, whatever the list says: calls and meetings
/// (a paused call drops), recording and dictation, Apple's own apps, and
/// DarraOwl itself. Docker Desktop has its own rule.
public enum PausePolicy {
    public static let dockerBundleID = "com.docker.docker"

    public static let meetingApps: Set<String> = [
        "us.zoom.xos",                 // Zoom
        "com.microsoft.teams2",        // Microsoft Teams
        "com.microsoft.teams",         // Microsoft Teams classic
        "Cisco-Systems.Spark",         // Webex
        "com.cisco.webexmeetingsapp",  // Webex Meetings
        "com.webex.meetingmanager",
        "com.google.meet",             // Google Meet (installed web app)
        "com.skype.skype",             // Skype
        "com.electron.wispr-flow",     // Wispr Flow
        "com.granola.app",             // Granola
        "com.otterai.desktop",         // Otter
        "com.obsproject.obs-studio",   // OBS
        "com.loom.desktop",            // Loom
        "com.discord.krisp",           // Krisp
        "ai.krisp.krispMac",
    ]

    static let protectedPrefixes = ["com.apple.", "com.darrao.darraowl", "us.zoom.", "com.cisco.webex."]

    public static func isProtected(_ bundleID: String) -> Bool {
        if bundleID == dockerBundleID { return true }
        if meetingApps.contains(bundleID) { return true }
        if meetingApps.contains(where: { bundleID.hasPrefix($0 + ".") }) { return true }
        return protectedPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Reverse-DNS characters only, so a value from the phone can never be a
    /// path or a command.
    public static func isWellFormedBundleID(_ id: String) -> Bool {
        guard (3...155).contains(id.count), id.contains(".") else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}
