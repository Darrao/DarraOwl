import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import DarraOwlShared
#endif

// Buttons on the Live Activity and the widget, and Siri phrases. They run in
// the app's process (LiveActivityIntent), where the signing keys are.

struct ExtendMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Prolonger le Mac d'une heure"
    static let description = IntentDescription("Le Mac reste éveillé une heure de plus.")

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

struct StopMacSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter la session du Mac"
    static let description = IntentDescription("Le Mac retrouve sa veille normale.")

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

struct StartMacSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Garder le Mac éveillé"
    static let description = IntentDescription("Démarre une session sur le Mac.")

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

struct MacStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "État du Mac"
    static let description = IntentDescription("Dit si le Mac est éveillé et jusqu'à quand.")

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
        AppShortcut(intent: ExtendMacIntent(), phrases: [
            "Prolonge le Mac d'une heure avec \(.applicationName)",
            "\(.applicationName) prolonge le Mac",
        ], shortTitle: "Prolonger d'1 h", systemImageName: "plus.circle")
        AppShortcut(intent: StopMacSessionIntent(), phrases: [
            "Arrête la session du Mac avec \(.applicationName)",
            "\(.applicationName) arrête le Mac",
        ], shortTitle: "Arrêter la session", systemImageName: "stop.circle")
        AppShortcut(intent: StartMacSessionIntent(), phrases: [
            "Garde le Mac éveillé avec \(.applicationName)",
            "\(.applicationName) garde le Mac éveillé",
        ], shortTitle: "Garder éveillé", systemImageName: "moon.zzz")
        AppShortcut(intent: MacStatusIntent(), phrases: [
            "État du Mac avec \(.applicationName)",
            "\(.applicationName) où en est le Mac",
        ], shortTitle: "État du Mac", systemImageName: "laptopcomputer")
    }
}
