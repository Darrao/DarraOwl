@testable import DarraOwlCore
import Foundation
import Testing

/// `darraowl claude`: Claude Code's Remote Control server in a Terminal
/// window, and the PATH the phone's commands run with.
@Suite struct ClaudeLauncherTests {
    @Test func theCommandTakesAFolderOrNone() throws {
        #expect(try CLICommand.parse(["claude"]) == .claude(.new(folder: nil)))
        #expect(try CLICommand.parse(["claude", "~/Dev/portfolio"]) == .claude(.new(folder: "~/Dev/portfolio")))
        #expect(throws: CLICommand.ParseError.extraArguments("b")) { try CLICommand.parse(["claude", "a", "b"]) }
        #expect(throws: CLICommand.ParseError.unknownOption("-x")) { try CLICommand.parse(["claude", "-x"]) }
        #expect(CLICommand.usage.contains("darraowl claude"))
    }

    /// Listing, the folder's latest, or one by the start of its id.
    @Test func conversationsAreListedAndTakenUp() throws {
        #expect(try CLICommand.parse(["claude", "--list"]) == .claude(.list(folder: nil)))
        #expect(try CLICommand.parse(["claude", "-l", "~/Dev/api"]) == .claude(.list(folder: "~/Dev/api")))
        #expect(try CLICommand.parse(["claude", "--continue"]) == .claude(.latest(folder: nil)))
        #expect(try CLICommand.parse(["claude", "-c", "."]) == .claude(.latest(folder: ".")))
        #expect(try CLICommand.parse(["claude", "--resume", "3F9A2C1B"]) == .claude(.resume(id: "3F9A2C1B")))
        #expect(throws: CLICommand.ParseError.missingConversation) { try CLICommand.parse(["claude", "--resume"]) }
        #expect(throws: CLICommand.ParseError.badConversation("3f9a")) { try CLICommand.parse(["claude", "-r", "3f9a"]) }
        #expect(throws: CLICommand.ParseError.badConversation("$(rm -rf ~)")) { try CLICommand.parse(["claude", "-r", "$(rm -rf ~)"]) }
        #expect(throws: CLICommand.ParseError.extraArguments("b")) { try CLICommand.parse(["claude", "--list", "a", "b"]) }
        #expect(throws: CLICommand.ParseError.unknownOption("--all")) { try CLICommand.parse(["claude", "--continue", "--all"]) }
        #expect(CLICommand.usage.contains("darraowl claude --resume"))
    }

    /// The conversation goes on in its folder, by its id, under its name.
    @Test func theResumeScriptQuotesWhatItIsGiven() {
        let script = ClaudeLauncher.resumeScript(folder: "/Users/me/Dev/l'appli", claude: "/Users/me/.local/bin/claude",
                                                 id: "3f9a2c1b-0000-4000-8000-000000000000", name: "Fix $(it)")
        #expect(script.contains("cd -- '/Users/me/Dev/l'\\''appli' || exit 1"))
        #expect(script.contains("exec '/Users/me/.local/bin/claude' --resume '3f9a2c1b-0000-4000-8000-000000000000' --remote-control='Fix $(it)'"))
        #expect(script.contains("rm -f -- \"$0\""))
    }

    /// The window goes to the folder and becomes the server, named after
    /// it; any folder name stays one word for the shell.
    @Test func theScriptQuotesWhatItIsGiven() {
        let script = ClaudeLauncher.script(folder: "/Users/me/Dev/l'appli", claude: "/Users/me/.local/bin/claude")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("cd -- '/Users/me/Dev/l'\\''appli' || exit 1"))
        #expect(script.contains("exec '/Users/me/.local/bin/claude' remote-control --name 'l'\\''appli'"))
        #expect(script.contains("rm -f -- \"$0\""), "the script does not stay behind")
        #expect(ClaudeLauncher.quoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(ClaudeLauncher.sessionName(folder: "/") == "Mac")
    }

    /// PATH first, then where Claude Code installs itself: ~/.local/bin is
    /// often only in ~/.zshrc.
    @Test func claudeIsFoundInPathOrItsInstallFolder() {
        let installed: Set<String> = ["/Users/me/.local/bin/claude", "/opt/homebrew/bin/claude"]
        #expect(ClaudeLauncher.findClaude(path: "/usr/bin:/opt/homebrew/bin", home: "/Users/me", isExecutable: installed.contains) == "/opt/homebrew/bin/claude")
        #expect(ClaudeLauncher.findClaude(path: "/usr/bin:/bin", home: "/Users/me", isExecutable: installed.contains) == "/Users/me/.local/bin/claude")
        #expect(ClaudeLauncher.findClaude(path: nil, home: "/Users/other", isExecutable: { _ in false }) == nil)
    }

    /// The PATH line among what a profile prints when it is read.
    @Test func thePathIsReadFromTheProbe() {
        let output = "Loading nvm…\n\n\(TerminalPath.marker)/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin\n"
        #expect(TerminalPath.parse(output) == "/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin")
        #expect(TerminalPath.parse("zsh: command not found: printf") == nil)
        #expect(TerminalPath.parse("\(TerminalPath.marker)\n") == nil)
        #expect(TerminalPath.probe.contains(TerminalPath.marker))
        #expect(TerminalPath.prepending("/A/Helpers", to: "/usr/bin:/A/Helpers::/bin") == "/A/Helpers:/usr/bin:/bin")
    }
}

/// The phone's terminal keeps its folder between commands.
@Suite struct TerminalSessionTests {
    @Test func theFolderComesBackAfterWhatTheCommandPrinted() {
        let wrapped = TerminalSession.wrap("cd ~/Dev && ls")
        #expect(wrapped.hasPrefix("eval 'cd ~/Dev && ls'\n"), "one piece, whatever its last line")
        #expect(TerminalSession.wrap("echo it's \\").hasPrefix("eval 'echo it'\\''s \\'\n"))
        #expect(wrapped.hasSuffix("exit $__darraowl_status"), "the command's own exit status")
        let (text, folder) = TerminalSession.split("api\nsite\n\n\(TerminalSession.marker)/Users/me/Dev\n")
        #expect(text == "api\nsite\n")
        #expect(folder == "/Users/me/Dev")
        let (bare, none) = TerminalSession.split("exit 3 left early")
        #expect(bare == "exit 3 left early" && none == nil)
        let (late, _) = TerminalSession.split("x\n\(TerminalSession.marker)/tmp\nbackground job\n")
        #expect(late == "x\nbackground job\n")
        let (cr, folder2) = TerminalSession.split("abc\r\n\(TerminalSession.marker)/usr\n")
        #expect(folder2 == "/usr", "after a lone CR too")
        #expect(cr.hasPrefix("abc"))
        let (fake, real) = TerminalSession.split("\n\(TerminalSession.marker)/printed\nok\n\(TerminalSession.marker)/Users/me\n")
        #expect(real == "/Users/me", "the last one is the shell's")
        #expect(fake.contains("/printed"))
    }

    @Test func foldersAreShownFromTheHomeFolder() {
        #expect(TerminalSession.shown("/Users/me", home: "/Users/me") == "~")
        #expect(TerminalSession.shown("/Users/me/Dev/api", home: "/Users/me") == "~/Dev/api")
        #expect(TerminalSession.shown("/Users/meow", home: "/Users/me") == "/Users/meow")
        #expect(TerminalSession.shown("/tmp", home: "/Users/me") == "/tmp")
        #expect(TerminalSession.shown("/Users/me/Dev/api", home: "/Users/me", masked: true) == "~/…", "no project name when masked")
        #expect(TerminalSession.shown("/Volumes/Projets/api", home: "/Users/me", masked: true) == "/…")
        #expect(TerminalSession.shown("/Users/me", home: "/Users/me", masked: true) == "~")
    }
}

@Suite struct TerminalFolderGoneTests {
    /// The message says the terminal went home only when it did.
    @Test func goingHomeIsSaidOnlyWhenItHappened() {
        let home = RemoteError.terminalFolderGone("~/x", backHome: true).errorDescription ?? ""
        let elsewhere = RemoteError.terminalFolderGone("~/x", backHome: false).errorDescription ?? ""
        #expect(home.contains("retour au dossier personnel"))
        #expect(!elsewhere.contains("retour au dossier personnel"))
        #expect(elsewhere.contains("~/x") && elsewhere.contains("n'a pas été lancée"))
    }
}
