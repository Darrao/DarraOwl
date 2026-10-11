import DarraOwlCore
import os

/// Unified log, subsystem `com.darrao.darraowl`. Read with:
/// `log show --last 1h --predicate 'subsystem == "com.darrao.darraowl"'`
public struct OSLogEngineLogger: EngineLogging {
    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: "com.darrao.darraowl", category: category)
    }

    /// `notice`, not `info`: info messages are not kept on disk, and the
    /// helper's history must survive for `log show`.
    public func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
