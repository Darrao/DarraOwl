import AppIntents
import DarraOwlShared
import Foundation

// Siri on the watch. Each intent asks the iPhone, which signs and sends.

struct ExtendMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Prolonger le Mac d'une heure"
    static let description = IntentDescription("Le Mac reste éveillé une heure de plus.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.extendSession(minutes: 60))
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Le Mac reste éveillé une heure de plus." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct StopMacSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrêter la session du Mac"
    static let description = IntentDescription("Le Mac retrouve sa veille normale.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.stopSession)
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Session arrêtée." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct StartMacSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Garder le Mac éveillé"
    static let description = IntentDescription("Démarre une session sur le Mac.")

    @Parameter(title: "Heures", default: 2, inclusiveRange: (1, 12))
    var hours: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await WatchModel.shared.send(.startSession(minutes: hours * 60))
        return .result(dialog: IntentDialog(stringLiteral: ok ? "Le Mac reste éveillé \(hours) h." : WatchModel.shared.message ?? "Le Mac n'est pas joignable."))
    }
}

struct MacStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "État du Mac"
    static let description = IntentDescription("Dit si le Mac est éveillé et jusqu'à quand.")

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
        AppShortcut(intent: ExtendMacIntent(), phrases: [
            "Prolonge le Mac d'une heure avec \(.applicationName)",
            "\(.applicationName) prolonge le Mac",
        ], shortTitle: "Prolonger d'1 h", systemImageName: "plus.circle")
        AppShortcut(intent: StopMacSessionIntent(), phrases: [
            "Arrête la session du Mac avec \(.applicationName)",
            "\(.applicationName) arrête le Mac",
        ], shortTitle: "Arrêter", systemImageName: "stop.circle")
        AppShortcut(intent: StartMacSessionIntent(), phrases: [
            "Garde le Mac éveillé avec \(.applicationName)",
        ], shortTitle: "Garder éveillé", systemImageName: "moon.zzz")
        AppShortcut(intent: MacStatusIntent(), phrases: [
            "État du Mac avec \(.applicationName)",
            "\(.applicationName) où en est le Mac",
        ], shortTitle: "État du Mac", systemImageName: "laptopcomputer")
    }
}
