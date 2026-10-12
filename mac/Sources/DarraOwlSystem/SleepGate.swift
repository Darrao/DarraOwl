import Foundation
import IOKit
import IOKit.pwr_mgt

/// Holds a system sleep a few seconds, so the last state and events reach
/// the phone before the Mac sleeps: the session that just ended with the
/// lid closed, a battery floor, a stop from the phone. IOKit's power
/// notifications wait for the answer (30 s at most); nothing is vetoed.
@MainActor
public final class SleepGate {
    /// Called when the Mac is about to sleep; `done` must be called (soon).
    public var willSleep: ((_ done: @escaping @MainActor () -> Void) -> Void)?

    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// IOKit's message values (iokit_common_msg), not imported into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280

    public init() {}

    /// False when IOKit refused: sleeps then come unannounced.
    @discardableResult
    public func start() -> Bool {
        guard root == 0 else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(context, &port, { context, _, messageType, argument in
            guard let context else { return }
            let gate = Unmanaged<SleepGate>.fromOpaque(context).takeUnretainedValue()
            let notification = Int(bitPattern: argument)
            MainActor.assumeIsolated { gate.handle(messageType, notification) }
        }, &notifier)
        guard root != 0, let port else { return false }
        IONotificationPortSetDispatchQueue(port, .main)
        return true
    }

    private func handle(_ message: UInt32, _ notification: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(root, notification)
        case Self.systemWillSleep:
            guard let willSleep else {
                IOAllowPowerChange(root, notification)
                return
            }
            let answer = Answer()
            let allow: @MainActor () -> Void = { [weak self] in
                guard let self, !answer.given else { return }
                answer.given = true
                IOAllowPowerChange(self.root, notification)
            }
            willSleep(allow)
            // Whatever happens, the Mac sleeps within a few seconds.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                allow()
            }
        default:
            break
        }
    }
}

/// Whether the system already got its answer for one sleep.
@MainActor
private final class Answer {
    var given = false
}
