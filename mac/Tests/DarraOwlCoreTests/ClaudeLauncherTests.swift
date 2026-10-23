@testable import DarraOwlCore
import Foundation
import Testing

/// `darraowl claude`: Claude Code's Remote Control server in a Terminal
/// window, and the PATH the phone's commands run with.
@Suite struct ClaudeLauncherTests {
    @Test func theCommandTakesAFolderOrNone() throws {
        #expect(try CLICommand.parse(["claude"]) == .claude(folder: nil))
        #expect(try CLICommand.parse(["claude", "~/Dev/portfolio"]) == .claude(folder: "~/Dev/portfolio"))
        #expect(throws: CLICommand.ParseError.extraArguments("b")) { try CLICommand.parse(["claude", "a", "b"]) }
        #expect(CLICommand.usage.contains("darraowl claude"))
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
        #expect(wrapped.hasPrefix("cd ~/Dev && ls\n"))
        #expect(wrapped.hasSuffix("exit $__darraowl_status"), "the command's own exit status")
        let (text, folder) = TerminalSession.split("api\nsite\n\n\(TerminalSession.marker)/Users/me/Dev\n")
        #expect(text == "api\nsite\n")
        #expect(folder == "/Users/me/Dev")
        let (bare, none) = TerminalSession.split("exit 3 left early")
        #expect(bare == "exit 3 left early" && none == nil)
        let (late, _) = TerminalSession.split("x\n\(TerminalSession.marker)/tmp\nbackground job\n")
        #expect(late == "x\nbackground job\n")
        let (fake, real) = TerminalSession.split("\n\(TerminalSession.marker)/printed\nok\n\(TerminalSession.marker)/Users/me\n")
        #expect(real == "/Users/me", "the last one is the shell's")
        #expect(fake.contains("/printed"))
    }

    @Test func foldersAreShownFromTheHomeFolder() {
        #expect(TerminalSession.shown("/Users/me", home: "/Users/me") == "~")
        #expect(TerminalSession.shown("/Users/me/Dev/api", home: "/Users/me") == "~/Dev/api")
        #expect(TerminalSession.shown("/Users/meow", home: "/Users/me") == "/Users/meow")
        #expect(TerminalSession.shown("/tmp", home: "/Users/me") == "/tmp")
    }
}
