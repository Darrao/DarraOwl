import DarraOwlCore
import Foundation
import IOKit.pwr_mgt

struct PresenceAssertionError: Error, LocalizedError {
    let code: IOReturn
    var errorDescription: String? { "macOS a refusé l'assertion (code \(code))." }
}

/// Public IOKit power assertions, as Caffeine and Amphetamine use them.
final class IOPMPresenceAsserter: PresenceAsserting {
    /// The display or the system-only assertion, whichever is held.
    private var held: (id: IOPMAssertionID, display: Bool)?
    private var activityAssertion: IOPMAssertionID = 0

    func hold(display: Bool) throws {
        if let held, held.display == display { return }
        var id: IOPMAssertionID = 0
        let type = display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        let r = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DarraOwl : mode présence" as CFString,
            &id
        )
        guard r == kIOReturnSuccess else { throw PresenceAssertionError(code: r) }
        if let held { IOPMAssertionRelease(held.id) }
        held = (id, display)
        // The display may sleep now: no declared activity keeps it lit.
        if !display { releaseActivity() }
    }

    func release() {
        if let held {
            IOPMAssertionRelease(held.id)
            self.held = nil
        }
        releaseActivity()
    }

    func declareActivity() {
        // Passing the previous id back updates that assertion instead of
        // creating a new one each minute.
        _ = IOPMAssertionDeclareUserActivity("DarraOwl : mode présence" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    private func releaseActivity() {
        if activityAssertion != 0 {
            IOPMAssertionRelease(activityAssertion)
            activityAssertion = 0
        }
    }
}
