import DarraOwlCore
import Foundation
import IOKit.pwr_mgt

struct PresenceAssertionError: Error, LocalizedError {
    let code: IOReturn
    var errorDescription: String? { "macOS a refusé l'assertion (code \(code))." }
}

/// Public IOKit power assertions, as Caffeine and Amphetamine use them.
final class IOPMPresenceAsserter: PresenceAsserting {
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0

    func hold() throws {
        guard displayAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DarraOwl : mode présence" as CFString,
            &id
        )
        guard r == kIOReturnSuccess else { throw PresenceAssertionError(code: r) }
        displayAssertion = id
    }

    func release() {
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        if activityAssertion != 0 {
            IOPMAssertionRelease(activityAssertion)
            activityAssertion = 0
        }
    }

    func declareActivity() {
        // Passing the previous id back updates that assertion instead of
        // creating a new one each minute.
        _ = IOPMAssertionDeclareUserActivity("DarraOwl : mode présence" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }
}
