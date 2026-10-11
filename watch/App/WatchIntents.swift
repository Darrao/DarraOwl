import AppIntents
import DarraOwlShared
import Foundation

// Siri on the watch. Each intent asks the iPhone, which signs and sends.

struct ExtendSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Prolonger la session d'une heure"
    static let description = IntentDescription("Garde l'ordinateur éveillé une heure de plus.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.extendSession(minutes: 60))
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Le Mac reste éveillé une heure de plus." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct StopSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrêter la session"
    static let description = IntentDescription("L'ordinateur retrouve sa veille normale.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.stopSession)
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Session arrêtée." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Démarrer une session"
    static let description = IntentDescription("Garde l'ordinateur éveillé quelques heures.")

    @Parameter(title: "Heures", default: 2, inclusiveRange: (1, 12))
    var hours: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.startSession(minutes: hours * 60))
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Le Mac reste éveillé \(hours) h." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct SessionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "État de la session"
    static let description = IntentDescription("Dit si l'ordinateur est éveillé et jusqu'à quand.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = WatchModel.shared
        await model.refresh()
        guard let state = model.state else {
            return .result(dialog: "Je ne trouve pas le Mac pour le moment.")
        }
        var text = state.session.map { session in
            session.watchingText.map { "\(state.macName) reste éveillé tant que \($0) tourne." }
                ?? "\(state.macName) reste éveillé jusqu'à \(DurationText.clock(session.endsAt))."
        } ?? "\(state.macName) n'a pas de session en cours."
        if let percent = state.powerSnapshot?.battery.percent { text += " Batterie à \(percent) %." }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct DarraOwlWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExtendSessionIntent(), phrases: [
            "Prolonge la session avec \(.applicationName)",
            "\(.applicationName) prolonge la session",
        ], shortTitle: "Prolonger d'1 h", systemImageName: "plus.circle")
        AppShortcut(intent: StopSessionIntent(), phrases: [
            "Arrête la session avec \(.applicationName)",
            "\(.applicationName) arrête la session",
        ], shortTitle: "Arrêter", systemImageName: "stop.circle")
        AppShortcut(intent: StartSessionIntent(), phrases: [
            "Démarre une session avec \(.applicationName)",
        ], shortTitle: "Garder éveillé", systemImageName: "moon.zzz")
        AppShortcut(intent: SessionStatusIntent(), phrases: [
            "État de la session avec \(.applicationName)",
            "\(.applicationName) où en est la session",
        ], shortTitle: "État de la session", systemImageName: "laptopcomputer")
    }
}
