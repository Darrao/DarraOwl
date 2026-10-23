import DarraOwlShared
import Foundation

/// What `darraowl` was asked, parsed from its arguments. Pure.
public enum CLICommand: Equatable, Sendable {
    /// `darraowl run [durée] [--] commande…`: awake while the command runs,
    /// at most `seconds` (the cap when nil).
    case run(seconds: TimeInterval?, command: [String])
    case start(seconds: TimeInterval)
    case extend(seconds: TimeInterval)
    case stop
    case status
    /// `darraowl claude …`: Claude Code with Remote Control, in a Terminal window.
    case claude(Claude)
    case help
    case version

    public enum Claude: Equatable, Sendable {
        /// A new conversation, in the folder (the current one when nil).
        case new(folder: String?)
        /// The latest conversations; only the folder's when given.
        case list(folder: String?)
        /// The folder's latest conversation, taken up again.
        case latest(folder: String?)
        /// That conversation (the start of its id), in its own folder.
        case resume(id: String)
    }

    public enum ParseError: Error, Equatable, Sendable, LocalizedError {
        case unknown(String)
        case unknownOption(String)
        case missingConversation
        case badConversation(String)
        case missingCommand
        case missingDuration(String)
        case badDuration(String)
        case extraArguments(String)

        public var errorDescription: String? {
            switch self {
            case let .unknown(s): "commande inconnue : \(s)"
            case let .unknownOption(s): "option inconnue : \(s)"
            case .missingConversation: "indique la conversation, par exemple : darraowl claude --resume 3f9a2c1b (darraowl claude --list les montre)"
            case let .badConversation(s): "conversation illisible : \(s) (au moins les 6 premiers caractères que montre darraowl claude --list)"
            case .missingCommand: "indique la commande à lancer, par exemple : darraowl run 3h -- claude"
            case let .missingDuration(verb): "indique une durée, par exemple : darraowl \(verb) 2h"
            case let .badDuration(s): "durée illisible : \(s) (exemples : 45m, 2h, 1h30)"
            case let .extraArguments(s): "argument en trop : \(s)"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws(ParseError) -> CLICommand {
        guard let verb = arguments.first else { return .status }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "run":
            return try parseRun(rest)
        case "claude":
            return .claude(try parseClaude(rest))
        case "start", "extend":
            guard let text = rest.first else { throw .missingDuration(verb) }
            guard rest.count == 1 else { throw .extraArguments(rest[1]) }
            guard let seconds = duration(text) else { throw .badDuration(text) }
            return verb == "start" ? .start(seconds: seconds) : .extend(seconds: seconds)
        case "stop", "status", "help", "-h", "--help", "version", "--version":
            guard rest.isEmpty else { throw .extraArguments(rest[0]) }
            switch verb {
            case "stop": return .stop
            case "status": return .status
            case "version", "--version": return .version
            default: return .help
            }
        default:
            throw .unknown(verb)
        }
    }

    /// `[dossier]`, `--list [dossier]`, `--continue [dossier]`, `--resume id`.
    private static func parseClaude(_ args: [String]) throws(ParseError) -> Claude {
        /// At most one folder after the option, never an option itself.
        func folder(after count: Int) throws(ParseError) -> String? {
            let rest = args.dropFirst(count)
            guard rest.count <= 1 else { throw .extraArguments(rest[rest.startIndex + 1]) }
            if let folder = rest.first, folder.hasPrefix("-") { throw .unknownOption(folder) }
            return rest.first
        }
        switch args.first {
        case "--list", "-l":
            return .list(folder: try folder(after: 1))
        case "--continue", "-c":
            return .latest(folder: try folder(after: 1))
        case "--resume", "-r":
            guard args.count >= 2 else { throw .missingConversation }
            guard args.count == 2 else { throw .extraArguments(args[2]) }
            guard ClaudeConversations.isIDPrefix(args[1]) else { throw .badConversation(args[1]) }
            return .resume(id: args[1])
        default:
            return .new(folder: try folder(after: 0))
        }
    }

    /// `[durée] [--] commande…`. darraowl's `--` is only right after `run` or
    /// right after the duration: a `--` further on belongs to the command
    /// (`npm test -- --watch`). Without `--`, a first word that reads as a
    /// duration is one.
    private static func parseRun(_ args: [String]) throws(ParseError) -> CLICommand {
        var rest = args[...]
        var seconds: TimeInterval?
        if rest.first == "--" {
            rest = rest.dropFirst()
        } else if let first = rest.first, let s = duration(first) {
            guard rest.count >= 2 else { throw .missingCommand }
            seconds = s
            rest = rest.dropFirst()
            if rest.first == "--" { rest = rest.dropFirst() }
        } else if let first = rest.first, rest.dropFirst().first == "--", duration(first) == nil, looksLikeDuration(first) {
            throw .badDuration(first)
        }
        let command = Array(rest)
        guard !command.isEmpty, !command[0].isEmpty else { throw .missingCommand }
        return .run(seconds: seconds, command: command)
    }

    /// Digits followed by a unit: meant as a duration even if unreadable.
    static func looksLikeDuration(_ s: String) -> Bool {
        guard let first = s.first, first.isNumber else { return false }
        return s.allSatisfy { $0.isNumber || "hmjd:".contains($0.lowercased()) || $0 == " " }
    }

    /// The menu's formats, plus days: "2j", "2d", "1j12h".
    public static func duration(_ text: String) -> TimeInterval? {
        let s = text.lowercased()
        guard let dayMark = s.firstIndex(where: { $0 == "j" || $0 == "d" }) else { return DurationText.parse(s) }
        guard let days = Int(s[..<dayMark]), days >= 0, days <= 30 else { return nil }
        let rest = s[s.index(after: dayMark)...]
        let extra: TimeInterval
        if rest.isEmpty {
            extra = 0
        } else {
            guard let parsed = DurationText.parse(String(rest)) else { return nil }
            extra = parsed
        }
        let total = TimeInterval(days * 86_400) + extra
        return total > 0 ? total : nil
    }

    public static let usage = """
    darraowl : garde le Mac éveillé, capot fermé compris.

    Utilisation :
      darraowl run [durée] [--] commande…   éveillé tant que la commande tourne,
                                            au plus la durée (sinon la durée maximale)
      darraowl start <durée>                session minutée
      darraowl extend <durée>               prolonge la session en cours
      darraowl stop                         arrête la session
      darraowl status                       état de la session (par défaut)
      darraowl claude [dossier]             nouvelle conversation Claude Code avec Remote
                                            Control, dans une fenêtre Terminal (le dossier
                                            courant par défaut)
      darraowl claude --list [dossier]      les dernières conversations, avec leur identifiant
      darraowl claude --continue [dossier]  reprend la dernière conversation du dossier
      darraowl claude --resume <id>         reprend cette conversation, dans son dossier

    Durées : 45m, 90, 2h, 1h30, 1j. Au plus la durée maximale des
    Réglages de DarraOwl (12 h par défaut).
    Exemples :
      darraowl run 3h -- claude
      darraowl run -- npm test
    """
}
