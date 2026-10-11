import DarraOwlCore
import DarraOwlShared
import Foundation

/// Names shared by the app, the helper and the launchd plist.
public enum HelperConstants {
    public static let machServiceName = "com.darrao.darraowl.mac.helper"
    public static let plistName = "com.darrao.darraowl.mac.helper.plist"
    public static let appIdentifier = "com.darrao.darraowl.mac"
    public static let helperIdentifier = "com.darrao.darraowl.mac.helper"
    /// The CLI of phase 5 talks to the helper too.
    public static let cliIdentifier = "com.darrao.darraowl.mac.cli"
    /// Bumped when the request or response shape changes.
    public static let protocolVersion = 2
}

/// The XPC surface. Requests and responses travel as JSON so the Objective-C
/// interface stays two methods wide and every value is validated by Codable.
@objc public protocol HelperXPCProtocol {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Everything a client may ask. A closed list: no free-form command.
public enum HelperRequest: Codable, Equatable, Sendable {
    case status
    case start(seconds: TimeInterval, origin: SessionOrigin)
    case extend(seconds: TimeInterval)
    case stop(reason: SessionEndReason)
    case updateSettings(PowerSettings)
    case prepareUninstall
    /// Journal brightness and sound values before the app changes them.
    case recordUserChanges(UserChanges)
    /// The app restored these values.
    case clearUserChanges([UserChangeKind])
    /// Pause these processes (lid close). Only the client's own processes.
    case freeze([FreezeGroup])
    /// Resume paused processes: all (nil) or one app's.
    case resume(bundleID: String?)
    /// The lid opened or closed: re-evaluate Low Power Mode now.
    case lidChanged
    /// End the session, then sleep now.
    case sleepNow
    /// Asks an idle helper to exit so launchd starts the updated binary.
    case restartIfIdle
}

public struct HelperResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// The helper's build (CFBundleVersion of the app that embeds it).
    public var helperBuild: String
    public var status: EngineStatus?
    /// French message when the request was refused.
    public var error: String?

    public init(protocolVersion: Int = HelperConstants.protocolVersion, helperBuild: String, status: EngineStatus?, error: String?) {
        self.protocolVersion = protocolVersion
        self.helperBuild = helperBuild
        self.status = status
        self.error = error
    }
}

public enum HelperCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: data)
    }
}
