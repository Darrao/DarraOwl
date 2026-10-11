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
    public var lastEnd: SessionEndRecord?

    public init() {}

    /// No change left to undo.
    public var isClean: Bool { sleep == nil && lowPower == nil }
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
