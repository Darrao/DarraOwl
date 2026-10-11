import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import DarraOwlShared
#endif

// Buttons on the Live Activity and the widget, and Siri phrases. They run in
// the app's process (LiveActivityIntent), where the signing keys are.

struct ExtendSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Prolonger la session d'une heure"
    static let description = IntentDescription("Garde l'ordinateur éveillé une heure de plus.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        let sent = await PhoneRuntime.shared.fire(.extendSession(minutes: 60))
        return .result(dialog: sent ? "Le Mac reste éveillé une heure de plus." : "Le Mac n'est pas joignable.")
        #endif
    }
}

struct StopSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter la session"
    static let description = IntentDescription("L'ordinateur retrouve sa veille normale.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        let sent = await PhoneRuntime.shared.fire(.stopSession)
        return .result(dialog: sent ? "Session arrêtée." : "Le Mac n'est pas joignable.")
        #endif
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Démarrer une session"
    static let description = IntentDescription("Garde l'ordinateur éveillé quelques heures.")

    @Parameter(title: "Heures", default: 2, inclusiveRange: (1, 12))
    var hours: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        let sent = await PhoneRuntime.shared.fire(.startSession(minutes: hours * 60))
        return .result(dialog: sent ? "Le Mac reste éveillé \(hours) h." : "Le Mac n'est pas joignable.")
        #endif
    }
}

struct SessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "État de la session"
    static let description = IntentDescription("Dit si l'ordinateur est éveillé et jusqu'à quand.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        return .result(dialog: IntentDialog(stringLiteral: await PhoneRuntime.shared.spokenStatus()))
        #endif
    }
}

struct DarraOwlShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExtendSessionIntent(), phrases: [
            "Prolonge la session avec \(.applicationName)",
            "\(.applicationName) prolonge la session",
        ], shortTitle: "Prolonger d'1 h", systemImageName: "plus.circle")
        AppShortcut(intent: StopSessionIntent(), phrases: [
            "Arrête la session avec \(.applicationName)",
            "\(.applicationName) arrête la session",
        ], shortTitle: "Arrêter la session", systemImageName: "stop.circle")
        AppShortcut(intent: StartSessionIntent(), phrases: [
            "Démarre une session avec \(.applicationName)",
            "\(.applicationName) garde l'ordinateur éveillé",
        ], shortTitle: "Garder éveillé", systemImageName: "moon.zzz")
        AppShortcut(intent: SessionStatusIntent(), phrases: [
            "État de la session avec \(.applicationName)",
            "\(.applicationName) où en est la session",
        ], shortTitle: "État de la session", systemImageName: "laptopcomputer")
    }
}
