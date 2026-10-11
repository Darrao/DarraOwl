import DarraOwlXPC
import Foundation
import ServiceManagement

/// State of the privileged helper registration, in the app's terms.
public enum HelperRegistration: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    /// The plist is missing from the bundle: a broken build.
    case notFound

    var label: String {
        switch self {
        case .notRegistered: "Composant système non installé"
        case .requiresApproval: "Composant système en attente de ton autorisation"
        case .enabled: "Composant système actif"
        case .notFound: "Composant système absent de l'app"
        }
    }
}

/// SMAppService wrappers for the helper daemon and the login item.
@MainActor
enum ServiceRegistration {
    static var helper: SMAppService { .daemon(plistName: HelperConstants.plistName) }

    /// macOS reports `.notFound` for a daemon that was simply never
    /// registered, so it reads as not registered here. Only a failed
    /// `register()` tells a really missing plist apart.
    static func helperState() -> HelperRegistration {
        switch helper.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound, .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    static func registerHelper() throws {
        try helper.register()
    }

    static func isMissingPlist(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "SMAppServiceErrorDomain" && ns.code == Int(kSMErrorJobPlistNotFound)
    }

    static func unregisterHelper() async throws {
        try await helper.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLoginItem(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
