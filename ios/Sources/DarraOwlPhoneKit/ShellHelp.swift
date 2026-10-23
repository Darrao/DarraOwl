import Foundation

/// Shell commands run from this phone, the latest first. Kept on the phone
/// only, never sent anywhere.
public struct CommandHistory: Equatable, Sendable {
    public static let limit = 30
    public private(set) var commands: [String]

    public init(commands: [String] = []) {
        self.commands = Array(commands.prefix(Self.limit))
    }

    /// A command run again moves to the top.
    public mutating func record(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        commands.removeAll { $0 == command }
        commands.insert(command, at: 0)
        if commands.count > Self.limit { commands.removeLast(commands.count - Self.limit) }
    }

    public mutating func clear() {
        commands = []
    }

    /// Stored as JSON; unreadable data is an empty history.
    public init(data: Data) {
        self.init(commands: (try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    public var data: Data {
        (try? JSONEncoder().encode(commands)) ?? Data()
    }
}

/// Ready-made commands for the phone's terminal, by theme. A word in
/// capitals (PROJET, COMMANDE) is for the user to replace.
public enum ShellHelp {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String { command }
        public let title: String
        public let command: String
        public let note: String?

        init(_ title: String, _ command: String, _ note: String? = nil) {
            self.title = title
            self.command = command
            self.note = note
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public var id: String { title }
        public let title: String
        public let items: [Item]
    }

    public static let sections: [Section] = [
        Section(title: "Claude Code", items: [
            Item("Lancer Claude (Remote Control)", "darraowl claude ~/Dev/PROJET",
                 "Ouvre Claude dans une fenêtre Terminal du Mac, puis retrouve la session dans l'app Claude, onglet Code. PROJET : un dossier déjà ouvert une fois avec Claude sur ce Mac."),
            Item("Sessions Claude ouvertes", "claude agents --json", "Celles qui tournent sur le Mac, avec leur dossier."),
            Item("Version de Claude Code", "claude --version"),
            Item("Mettre à jour Claude Code", "claude update"),
        ]),
        Section(title: "Dans le dossier choisi", items: [
            Item("État Git", "git status --short --branch"),
            Item("Derniers commits", "git log --oneline -10"),
            Item("Récupérer les changements", "git pull --ff-only"),
            Item("Fichiers", "ls -la"),
            Item("Scripts npm du projet", "npm run"),
        ]),
        Section(title: "Le Mac", items: [
            Item("Session DarraOwl", "darraowl status"),
            Item("Batterie", "pmset -g batt"),
            Item("Espace disque", "df -h ~"),
            Item("Processus les plus gourmands", "ps -Ao pcpu,pmem,comm -r | head -8"),
            Item("Allumé depuis", "uptime"),
            Item("Adresse IP locale", "ipconfig getifaddr en0"),
        ]),
        Section(title: "Tâches longues", items: [
            // Not on the Desktop: macOS would ask on the Mac whether
            // DarraOwl may write there, and nobody is at the Mac.
            Item("Lancer en arrière-plan", "nohup COMMANDE > ~/sortie.txt 2>&1 &",
                 "Une commande s'arrête au bout de 5 min. En arrière-plan, elle continue, et ce qu'elle affiche va dans ~/sortie.txt."),
            Item("Lire la fin du fichier", "tail -40 ~/sortie.txt"),
            Item("Voir si elle tourne encore", "pgrep -fl COMMANDE"),
        ]),
    ]

    public static let footer = "Aucune saisie n'est possible : une commande qui pose une question (sudo, oui ou non) échoue au lieu d'attendre. Chaque commande demande Face ID."
}
