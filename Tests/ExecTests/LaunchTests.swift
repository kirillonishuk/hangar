import Foundation
import Testing
import Workspace
@testable import Exec

@Suite struct LaunchTests {
    let tab = UUID()
    let cwd = NSTemporaryDirectory()
    let wrapper = #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#

    func spec(_ leaf: Leaf, config: HangarConfig = HangarConfig(), restoring: Bool = false,
              prompt: String? = nil, shell: String = "/bin/zsh") throws -> LaunchSpec {
        try launchSpec(for: leaf, tabId: tab, config: config, socketPath: "/tmp/h.sock",
                       userShell: shell, restoring: restoring, initialPrompt: prompt)
    }

    func leaf(_ kind: LeafKind, id: String? = nil, file: String? = nil, line: Int? = nil) -> Leaf {
        Leaf(kind: kind, cwd: cwd, agentSessionId: id, openFile: file, openLine: line)
    }

    /// Evaluates the shell-quoted `-c` argument of the command and returns the script text.
    func script(_ s: LaunchSpec, shell: String = "/bin/zsh") throws -> String {
        let prefix = "\(shell) -l -i -c "
        #expect(s.command.hasPrefix(prefix))
        return try sh("printf %s " + s.command.dropFirst(prefix.count)).out
    }

    func inner(_ s: LaunchSpec) throws -> String {
        let full = try script(s)
        #expect(full.hasSuffix(wrapper))
        return String(full.dropLast(wrapper.count))
    }

    func sh(_ cmd: String) throws -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    @Test func launchUsesLoginShell() throws {
        let s = try spec(leaf(.claude))
        // Backslashes sit outside the single quotes (shellQuote, fish-safe).
        #expect(s.command == #"/bin/zsh -l -i -c 'claude; c=$?; printf "'\\'e]133;C'\\'a'\\'e]133;D;%d'\\'a" $c; exit $c'"#)
        #expect(s.cwd == cwd)
        #expect(try inner(spec(leaf(.shell))) == ghosttyZshIntegration + "/bin/zsh -l -i")
        #expect(try inner(s) == "claude")
    }

    /// The tab's shell is the account's login shell, as in Ghostty.app and login(1); `$SHELL` is the launcher's (#71).
    @Test func userShellPrefersPasswd() {
        #expect(resolveUserShell(passwd: "/bin/zsh", env: "/bin/bash") == "/bin/zsh")
        #expect(resolveUserShell(passwd: nil, env: "/bin/bash") == "/bin/bash")
        #expect(resolveUserShell(passwd: "", env: nil) == "/bin/zsh")
        #expect(resolveUserShell(passwd: nil, env: "") == "/bin/zsh")
    }

    /// Ghostty injects its zsh integration into the outer `-c` shell only; the tab's interactive zsh gets it too.
    @Test func zshShellTabGetsGhosttyIntegration() throws {
        #expect(try script(spec(leaf(.shell), shell: "/bin/bash"), shell: "/bin/bash") == "/bin/bash -l -i" + wrapper)
        let fish = try spec(leaf(.shell), shell: "/opt/homebrew/bin/fish")
        #expect(!fish.command.contains("ZDOTDIR"))
        #expect(try inner(spec(leaf(.shell), prompt: "make setup")) == "make setup\n" + ghosttyZshIntegration + "/bin/zsh -l -i")
    }

    func zsh(_ pre: String) throws -> String {
        try sh("/bin/zsh -f -c " + shellQuote(pre + "; " + ghosttyZshIntegration + #"print -r -- "Z=${ZDOTDIR-unset} G=${GHOSTTY_ZSH_ZDOTDIR-unset}""#)).out
    }

    @Test func ghosttyIntegrationOnlyWhenOuterShellHasIt() throws {
        // `_ghostty_state` is set by Ghostty's integration in the outer zsh; without it nothing changes.
        #expect(try zsh("unset ZDOTDIR; export GHOSTTY_RESOURCES_DIR=/R") == "Z=unset G=unset\n")
        #expect(try zsh("unset ZDOTDIR; export GHOSTTY_RESOURCES_DIR=/R; typeset -gi _ghostty_state")
                == "Z=/R/shell-integration/zsh G=unset\n")
        // The user's own ZDOTDIR is handed over: Ghostty's .zshenv restores it.
        #expect(try zsh("export ZDOTDIR=/u GHOSTTY_RESOURCES_DIR=/R; typeset -gi _ghostty_state")
                == "Z=/R/shell-integration/zsh G=/u\n")
    }

    @Test func exitCodeWrapperPresent() throws {
        let s = try spec(leaf(.claude))
        #expect(try script(s).contains(#"c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#))
        #expect(!s.command.contains("exec"))
    }

    @Test func claudeResumesById() throws {
        #expect(try inner(spec(leaf(.claude, id: "abc"), restoring: true)) == "claude --resume abc")
        #expect(try inner(spec(leaf(.claude), restoring: true)) == "claude --continue")
        #expect(try inner(spec(leaf(.claude))) == "claude")
        #expect(try inner(spec(leaf(.claude, id: "abc"), restoring: true, prompt: "hi")) == "claude --resume abc")
        // Fresh start (a failed resume fell back): the id is ignored.
        #expect(try inner(spec(leaf(.claude, id: "abc"))) == "claude")
    }

    @Test func initialPromptIsArgument() throws {
        #expect(try inner(spec(leaf(.claude), prompt: "fix it's bug")) == #"claude 'fix it'\''s bug'"#)
        #expect(try inner(spec(leaf(.codex), prompt: "fix it's bug")) == #"codex 'fix it'\''s bug'"#)
    }

    @Test func codexResume() throws {
        #expect(try inner(spec(leaf(.codex, id: "abc"), restoring: true)) == "codex resume abc")
        #expect(try inner(spec(leaf(.codex, id: "abc"))) == "codex")
        #expect(try inner(spec(leaf(.codex), restoring: true)) == "codex resume --last")
        #expect(try inner(spec(leaf(.codex))) == "codex")
    }

    @Test func promptStartingWithDashGetsLeadingSpace() throws {
        #expect(try inner(spec(leaf(.claude), prompt: "--help me")) == "claude ' --help me'")
        #expect(try inner(spec(leaf(.codex), prompt: "-x")) == "codex ' -x'")
    }

    @Test func editorOpensFile() throws {
        #expect(try inner(spec(leaf(.editor, file: "src/a b.ts"))) == "hx 'src/a b.ts'")
        #expect(try inner(spec(leaf(.editor, file: "-c.ts"))) == "hx ./-c.ts")
        #expect(try inner(spec(leaf(.editor, file: "/tmp/-x"))) == "hx /tmp/-x")
        #expect(try inner(spec(leaf(.editor))) == "hx")
    }

    @Test func editorWithLine() throws {
        func cmd(_ editor: String, _ file: String, _ line: Int?) throws -> String {
            var c = HangarConfig(); c.editor = editor
            return try inner(spec(leaf(.editor, file: file, line: line), config: c))
        }
        #expect(try cmd("hx", "/r/a b.txt", 7) == "hx '/r/a b.txt:7'")
        #expect(try cmd("nvim", "/r/a b.txt", 7) == "nvim +7 '/r/a b.txt'")
        #expect(try cmd("code", "/r/a b.txt", 7) == "code '/r/a b.txt'")
        #expect(try cmd("hx", "-x", nil) == "hx ./-x")
        #expect(try cmd("hx", "-x", 3) == "hx ./-x:3")
        #expect(try cmd("nvim", "-x", 3) == "nvim +3 ./-x")
        // state.json is editable: a line below 1 is ignored instead of reaching the editor.
        #expect(try cmd("hx", "/r/a.txt", 0) == "hx /r/a.txt")
        #expect(try cmd("nvim", "/r/a.txt", -2) == "nvim /r/a.txt")
    }

    @Test func helixDetection() {
        for e in ["hx", "/opt/homebrew/bin/hx --config x", "helix"] { #expect(isHelix(e)) }
        for e in ["nvim", "hxx", ""] { #expect(!isHelix(e)) }
    }

    /// A tampered state.json must not turn the id into a flag: an invalid stored id falls back to the no-id mode.
    @Test func invalidStoredIdIsNotOnCommandLine() throws {
        #expect(try inner(spec(leaf(.claude, id: "--dangerously-skip-permissions"), restoring: true)) == "claude --continue")
        #expect(try inner(spec(leaf(.codex, id: "-c"), restoring: true)) == "codex resume --last")
        #expect(try inner(spec(leaf(.claude, id: "a;b"), restoring: true)) == "claude --continue")
    }

    @Test func argumentsAreShellQuoted() throws {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("") == "''")
        #expect(shellQuote("abc-1.2/x") == "abc-1.2/x")
    }

    @Test func quotingRoundTripsThroughShellAndReportsExitCode() throws {
        var config = HangarConfig()
        config.agentCommands[.claude] = "sh -c 'echo \"$1\"; exit 3' --"
        let s = try spec(leaf(.claude), config: config, prompt: "it's a;b", shell: "/bin/sh")
        let r = try sh(s.command)
        #expect(r.out.contains("it's a;b\n"))
        #expect(r.out.contains("\u{1b}]133;D;3\u{07}"))
        #expect(r.out.contains("\u{1b}]133;C\u{07}"))
        #expect(r.status == 3)
    }

    @Test func envHasLeafId() throws {
        let l = leaf(.claude)
        let s = try spec(l)
        #expect(s.env == ["HANGAR_TAB_ID": tab.uuidString, "HANGAR_LEAF_ID": l.id.uuidString, "HANGAR_SOCKET": "/tmp/h.sock"])
    }

    @Test func envHasTaskPort() throws {
        let s = try launchSpec(for: leaf(.shell), tabId: tab, config: HangarConfig(), socketPath: "/tmp/h.sock",
                               userShell: "/bin/zsh", restoring: false, initialPrompt: nil, port: 41234)
        #expect(s.env["HANGAR_PORT"] == "41234")
    }

    @Test func envHasTabAndSocket() throws {
        let s = try spec(leaf(.shell))
        #expect(s.env["HANGAR_TAB_ID"] == tab.uuidString)
        #expect(s.env["HANGAR_SOCKET"] == "/tmp/h.sock")
    }

    @Test func missingCwdIsReported() {
        let bad = Leaf(kind: .shell, cwd: "/nonexistent/dir/xyz")
        #expect(throws: LaunchError.missingCwd("/nonexistent/dir/xyz")) { try spec(bad) }
    }

    @Test func nonPosixShellUsesZshWrapper() throws {
        let fish = "/opt/homebrew/bin/fish"
        let c = try spec(leaf(.claude), shell: fish)
        #expect(c.command.hasPrefix("/bin/zsh -l -i -c '"))
        let sl = try spec(leaf(.shell), shell: fish)
        #expect(sl.command.hasPrefix("/bin/zsh -l -i -c '"))
        #expect(try script(sl).hasPrefix("/opt/homebrew/bin/fish -l -i;"))
        #expect(try spec(leaf(.claude), shell: "/bin/bash").command.hasPrefix("/bin/bash -l -i -c '"))
    }
}

/// One rule for how an agent leaf is (re)launched (decision #41).
@Suite struct LaunchModeTests {
    let claude = Leaf(kind: .claude, cwd: "/a")
    let fresh = LaunchMode(restoring: false, initialPrompt: nil)
    let resume = LaunchMode(restoring: true, initialPrompt: nil)

    @Test func createdUsesPromptOnce() {
        #expect(launchMode(for: claude, .created(prompt: "fix")) == LaunchMode(restoring: false, initialPrompt: "fix"))
        #expect(launchMode(for: claude, .created(prompt: nil)) == fresh)
    }

    @Test func restoredFollowsResumeSet() {
        #expect(launchMode(for: claude, .restored(inResumeSet: true)) == resume)
        #expect(launchMode(for: claude, .restored(inResumeSet: false)) == fresh)
    }

    @Test func relaunchNeverResendsPrompt() {
        let first = launchMode(for: claude, .created(prompt: "fix"))
        let next = launchMode(for: claude, .relaunch(previous: first, exitCode: 1))
        #expect(next.initialPrompt == nil)
        #expect(launchMode(for: Leaf(kind: .codex, cwd: "/a"), .relaunch(previous: first, exitCode: 2)).initialPrompt == nil)
    }

    @Test func failedContinueFallsBackToFresh() {
        #expect(launchMode(for: claude, .relaunch(previous: resume, exitCode: 1)) == fresh)
        let withId = Leaf(kind: .claude, cwd: "/a", agentSessionId: "x")
        #expect(launchMode(for: withId, .relaunch(previous: resume, exitCode: -1)) == fresh)
        // The fallback then crashing resumes again: no endless fresh starts, no endless failed resumes.
        #expect(launchMode(for: claude, .relaunch(previous: fresh, exitCode: 1)) == resume)
    }

    @Test func relaunchAfterCrashResumes() {
        let first = LaunchMode(restoring: false, initialPrompt: "fix")
        #expect(launchMode(for: claude, .relaunch(previous: first, exitCode: 137)) == resume)
        let codex = Leaf(kind: .codex, cwd: "/a", agentSessionId: "x")
        #expect(launchMode(for: codex, .relaunch(previous: fresh, exitCode: 1)) == resume)
    }

    @Test func surfaceNeverStartedRetriesSameLaunch() {
        let first = LaunchMode(restoring: false, initialPrompt: "fix")
        #expect(launchMode(for: claude, .relaunch(previous: first, exitCode: nil)) == first)
        #expect(launchMode(for: claude, .relaunch(previous: resume, exitCode: nil)) == resume)
    }
}

/// Launched from inside a Claude Code / Codex session, the app would pass those markers to every tab's agent.
@Test func inheritedAgentEnvScrubbed() {
    let env = ["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SSE_PORT": "1234",
               "CODEX_SANDBOX": "seatbelt", "CODEX_SANDBOX_NETWORK_DISABLED": "1",
               "CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/h", "PATH": "/bin", "CLAUDECODEX": "x", "MY_CLAUDECODE": "y"]
    #expect(inheritedAgentEnvToScrub(env).sorted() == ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                                                       "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED"])
    #expect(inheritedAgentEnvToScrub([:]).isEmpty)
}
