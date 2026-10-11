import DarraOwlShared
import Foundation

/// Everything the helper changed and must undo, with the value it replaced.
/// Written to disk before each change is applied; an entry is removed only
/// after its undo succeeded. Phase 2 adds the lid-close entries.
public struct Journal: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var session: Session?
    /// Present from just before `disablesleep 1` until the undo succeeded.
    public var sleep: SleepEntry?
    /// Present from just before Low Power Mode is switched on until the undo succeeded.
    public var lowPower: LowPowerEntry?
    /// Processes the helper stopped at lid close. The helper (root) resumes them.
    public var frozen: [FrozenProcess] = []
    /// Brightness and sound the app changed at lid close. Only the app can
    /// put them back (they belong to the user's session).
    public var user = UserChanges()
    public var lastEnd: SessionEndRecord?

    public init() {}

    /// Nothing left that the helper itself must undo.
    public var isClean: Bool { sleep == nil && lowPower == nil && frozen.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case version, session, sleep, lowPower, frozen, user, lastEnd
    }

    /// A journal written by an earlier build lacks the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        session = try c.decodeIfPresent(Session.self, forKey: .session)
        sleep = try c.decodeIfPresent(SleepEntry.self, forKey: .sleep)
        lowPower = try c.decodeIfPresent(LowPowerEntry.self, forKey: .lowPower)
        frozen = try c.decodeIfPresent([FrozenProcess].self, forKey: .frozen) ?? []
        user = try c.decodeIfPresent(UserChanges.self, forKey: .user) ?? UserChanges()
        lastEnd = try c.decodeIfPresent(SessionEndRecord.self, forKey: .lastEnd)
    }
}

/// One output device muted at lid close, with what it had before.
public struct AudioEntry: Codable, Equatable, Sendable {
    public var deviceUID: String
    public var name: String?
    public var volume: Float
    public var muted: Bool

    public init(deviceUID: String, name: String?, volume: Float, muted: Bool) {
        self.deviceUID = deviceUID
        self.name = name
        self.volume = volume
        self.muted = muted
    }
}

/// Values the app saved before darkening and muting at lid close.
public struct UserChanges: Codable, Equatable, Sendable {
    public var displayBrightness: Float?
    public var keyboardBrightness: Float?
    public var audio: [AudioEntry] = []

    public init(displayBrightness: Float? = nil, keyboardBrightness: Float? = nil, audio: [AudioEntry] = []) {
        self.displayBrightness = displayBrightness
        self.keyboardBrightness = keyboardBrightness
        self.audio = audio
    }

    public var isEmpty: Bool { displayBrightness == nil && keyboardBrightness == nil && audio.isEmpty }

    /// Adds what is not saved yet. A value already saved is kept: a second
    /// lid close would otherwise save the 0 the first one set.
    public mutating func merge(_ other: UserChanges) {
        if displayBrightness == nil { displayBrightness = other.displayBrightness }
        if keyboardBrightness == nil { keyboardBrightness = other.keyboardBrightness }
        for entry in other.audio where !audio.contains(where: { $0.deviceUID == entry.deviceUID }) {
            audio.append(entry)
        }
    }
}

public enum UserChangeKind: Codable, Equatable, Hashable, Sendable {
    case display
    case keyboard
    case audio(deviceUID: String)
}

public struct SleepEntry: Codable, Equatable, Sendable {
    /// `SleepDisabled` before the session. When it was already 1, the undo
    /// leaves it at 1: it was not ours to clear.
    public var previouslyDisabled: Bool

    public init(previouslyDisabled: Bool) {
        self.previouslyDisabled = previouslyDisabled
    }
}

public struct LowPowerEntry: Codable, Equatable, Sendable {
    public var previousOnBattery: Bool
    public var previousOnAC: Bool

    public init(previousOnBattery: Bool, previousOnAC: Bool) {
        self.previousOnBattery = previousOnBattery
        self.previousOnAC = previousOnAC
    }
}

public struct SessionEndRecord: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var reason: SessionEndReason
    /// Undo steps that failed at the end; retried until they succeed.
    public var failures: [String]

    public init(sessionID: UUID, startedAt: Date, endedAt: Date, reason: SessionEndReason, failures: [String]) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.failures = failures
    }
}
