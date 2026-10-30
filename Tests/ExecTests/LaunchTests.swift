import Foundation
import Testing
import Workspace
@testable import Exec

@Suite struct LaunchTests {
    let tab = UUID()
    let cwd = NSTemporaryDirectory()
    let wrapper = #"; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#

    func spec(_ leaf: Leaf, config: HangarConfig = HangarConfig(), restoring: Bool = false,
              prompt: String? = nil, shell: String = "/bin/zsh", hookCLI: String? = nil) throws -> LaunchSpec {
        try launchSpec(for: leaf, tabId: tab, config: config, socketPath: "/tmp/h.sock",
                       userShell: shell, restoring: restoring, initialPrompt: prompt, hookCLI: hookCLI)
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
        // A login shell that is gone falls back to $SHELL, then zsh.
        let gone = "/opt/homebrew/bin/hangar-no-such-shell"
        #expect(resolveUserShell(passwd: gone, env: "/bin/bash") == "/bin/bash")
        #expect(resolveUserShell(passwd: gone, env: gone) == "/bin/zsh")
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

    /// #119: only ever the leaf's own conversation; never `--continue` (the folder's latest chat, possibly another tab's).
    @Test func claudeResumesById() throws {
        #expect(try inner(spec(leaf(.claude, id: "abc"), restoring: true)) == "claude --resume abc")
        #expect(try inner(spec(leaf(.claude), restoring: true)) == "claude")
        #expect(try inner(spec(leaf(.claude))) == "claude")
        #expect(try inner(spec(leaf(.claude, id: "abc"), restoring: true, prompt: "hi")) == "claude --resume abc")
        #expect(try inner(spec(leaf(.claude, id: "abc"))) == "claude")  // not a uuid: no `--session-id`
    }

    /// A new conversation is born under the leaf's uuid; resuming one never written (nothing said) starts it under it.
    @Test func claudeSessionIdAtBirth() throws {
        let id = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"
        #expect(try inner(spec(leaf(.claude, id: id), prompt: "fix")) == "claude --session-id \(id) fix")
        let restore = try inner(spec(leaf(.claude, id: id), restoring: true))
        #expect(restore.hasPrefix("sh -c \(shellQuote(resumeOrStartScript)) sh \(id) ") && restore.hasSuffix(" \(shellQuote("/bin/zsh")) \(shellQuote("claude"))"))
    }

    /// The restore command resumes only a conversation whose transcript was recorded in this folder; a chat never written
    /// starts under its id; one recorded in another folder (claude would never find it from here) starts under a new id
    /// with the note. Claude runs through the login shell (aliases, functions); a resumed chat ending with an error is not
    /// followed by a second start.
    @Test func resumeOrStartChoosesByTranscript() throws {
        let dir = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath + "/hg-resume-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/cfg/projects/-any-folder", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/work dir", withIntermediateDirectories: true)
        // The "login shell": records the command it was asked to run, exits like a claude that failed.
        let login = dir + "/login"
        try writeScript("#!/bin/sh\nprintf '%s\\n' \"$4\" >> '\(dir)/ran'\nexit 3\n", to: login)
        let id = "0b9e6c55-1f0e-4c1a-9d65-3f1f2d7a8b90"
        let line = agentCommand(for: leaf(.claude, id: id), agent: { _ in "claude" }, shell: "sh", restoring: true, initialPrompt: nil,
                                loginShell: shellQuote(login), unlinkedNote: "open it from History")
        func run() throws -> (status: Int32, ran: String, out: String) {
            try? FileManager.default.removeItem(atPath: dir + "/ran")
            let r = try sh("cd \(shellQuote(dir + "/work dir")) && CLAUDE_CONFIG_DIR=\(shellQuote(dir + "/cfg")) && export CLAUDE_CONFIG_DIR && \(line)")
            return (r.status, (try? String(contentsOfFile: dir + "/ran", encoding: .utf8)) ?? "", r.out)
        }
        let none = try run()
        #expect(none.status == 3 && none.ran == "claude --session-id \(id)\n" && none.out.isEmpty)
        let transcript = dir + "/cfg/projects/-any-folder/\(id).jsonl"
        try #"{"type":"user","cwd":"/elsewhere"}"#.write(toFile: transcript, atomically: true, encoding: .utf8)
        let foreign = try run()
        #expect(foreign.status == 3 && foreign.out == "open it from History\n")
        #expect(foreign.ran.hasPrefix("claude --session-id ") && !foreign.ran.contains(id))
        try #"{"type":"user","cwd":"\#(dir)/work dir"}"#.write(toFile: transcript, atomically: true, encoding: .utf8)
        let own = try run()
        #expect(own.status == 3 && own.ran == "claude --resume \(id)\n" && own.out.isEmpty)
    }

    /// Hangar's own hooks ride on every claude command line, quoted as one argument; nothing else gets them.
    @Test func claudeGetsTabAgentHooks() throws {
        let cli = "/Apps/My Hangar.app/Contents/Helpers/hangar"
        let line = try inner(spec(leaf(.claude, id: "abc"), restoring: true, hookCLI: cli))
        let words = try sh("for w in \(line.replacingOccurrences(of: "claude", with: "")); do printf '%s\\n' \"$w\"; done").out
            .split(separator: "\n").map(String.init)
        #expect(words.first == "--settings" && words.last == "abc")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(words[1].utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit"])
        let command = try #require(((hooks["SessionStart"]?.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        #expect(command == "h='\(cli)'; [ -x \"$h\" ] && \"$h\" event session-start --tab-agent --agent-pid \"$PPID\"; exit 0")
        #expect(try !inner(spec(leaf(.codex, id: "t"), restoring: true, hookCLI: cli)).contains("--settings"))
        #expect(try !inner(spec(leaf(.shell), hookCLI: cli)).contains("--settings"))
    }

    /// The hook command itself: the agent's pid reaches `hangar event`; a missing CLI is a silent success.
    @Test func tabAgentHookCommandRuns() throws {
        let dir = NSTemporaryDirectory() + "hg-hook-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = dir + "/hangar"
        try writeScript("#!/bin/sh\necho \"$@\" > '\(dir)/argv'\n", to: fake)
        func command(_ cli: String) throws -> String {
            let json = try #require(try JSONSerialization.jsonObject(with: Data(tabAgentSettings(hookCLI: cli).utf8)) as? [String: Any])
            let start = ((json["hooks"] as? [String: [[String: Any]]])?["SessionStart"]?.first?["hooks"] as? [[String: Any]])?.first
            return try #require(start?["command"] as? String)
        }
        let r = try sh("sh -c \(shellQuote(try command(shellQuote(fake)))); echo \"pid=$$\"")
        let argv = try String(contentsOfFile: dir + "/argv", encoding: .utf8)
        let parent = r.out.split(separator: "=").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(argv == "event session-start --tab-agent --agent-pid \(parent)\n")
        #expect(try sh("sh -c \(shellQuote(try command(shellQuote(dir + "/missing"))))").status == 0)
    }

    @Test func initialPromptIsArgument() throws {
        #expect(try inner(spec(leaf(.claude), prompt: "fix it's bug")) == #"claude 'fix it'\''s bug'"#)
        #expect(try inner(spec(leaf(.codex), prompt: "fix it's bug")) == #"codex 'fix it'\''s bug'"#)
    }

    @Test func codexResume() throws {
        #expect(try inner(spec(leaf(.codex, id: "abc"), restoring: true)) == "codex resume abc")
        #expect(try inner(spec(leaf(.codex, id: "abc"))) == "codex")
        #expect(try inner(spec(leaf(.codex), restoring: true)) == "codex")  // never `resume --last` (#119)
        #expect(try inner(spec(leaf(.codex))) == "codex")
    }

    @Test func promptStartingWithDashGetsLeadingSpace() throws {
        #expect(try inner(spec(leaf(.claude), prompt: "--help me")) == "claude ' --help me'")
        #expect(try inner(spec(leaf(.codex), prompt: "-x")) == "codex ' -x'")
    }

    /// The editor is Monaco (#81): an editor leaf never runs a terminal editor, only a shell if it is ever launched.
    @Test func editorLeafRunsNoTerminalEditor() throws {
        #expect(try inner(spec(leaf(.editor, file: "src/a b.ts", line: 3))) == ghosttyZshIntegration + "/bin/zsh -l -i")
    }

    /// A tampered state.json must not turn the id into a flag: an invalid stored id falls back to the no-id mode.
    @Test func invalidStoredIdIsNotOnCommandLine() throws {
        #expect(try inner(spec(leaf(.claude, id: "--dangerously-skip-permissions"), restoring: true)) == "claude")
        #expect(try inner(spec(leaf(.codex, id: "-c"), restoring: true)) == "codex")
        #expect(try inner(spec(leaf(.claude, id: "a;b"), restoring: true)) == "claude")
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

    @Test func restoredResumes() {
        #expect(launchMode(for: claude, .restored) == resume)
    }

    @Test func relaunchNeverResendsPrompt() {
        let first = launchMode(for: claude, .created(prompt: "fix"))
        let next = launchMode(for: claude, .relaunch(previous: first, exitCode: 1))
        #expect(next.initialPrompt == nil)
        #expect(launchMode(for: Leaf(kind: .codex, cwd: "/a"), .relaunch(previous: first, exitCode: 2)).initialPrompt == nil)
    }

    /// #119: a claude resume never fails for a missing chat (its command starts it instead), so any exit of a resumed chat
    /// resumes that same chat again; codex keeps the fresh fallback (else "No conversation found" loops).
    @Test func failedResumeFallsBackOnlyForCodex() {
        let withId = Leaf(kind: .claude, cwd: "/a", agentSessionId: "x")
        #expect(launchMode(for: withId, .relaunch(previous: resume, exitCode: 1)) == resume)
        #expect(launchMode(for: withId, .relaunch(previous: resume, exitCode: -1)) == resume)
        let codex = Leaf(kind: .codex, cwd: "/a", agentSessionId: "x")
        #expect(launchMode(for: codex, .relaunch(previous: resume, exitCode: 1)) == fresh)
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
