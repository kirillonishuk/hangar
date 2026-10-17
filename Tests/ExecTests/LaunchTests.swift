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

    func leaf(_ kind: LeafKind, id: String? = nil, file: String? = nil) -> Leaf {
        Leaf(kind: kind, cwd: cwd, agentSessionId: id, openFile: file)
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
        #expect(s.command == #"/bin/zsh -l -i -c 'claude; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c'"#)
        #expect(s.cwd == cwd)
        #expect(try inner(spec(leaf(.shell))) == "/bin/zsh -l -i")
        #expect(try inner(s) == "claude")
    }

    @Test func exitCodeWrapperPresent() throws {
        let s = try spec(leaf(.claude))
        #expect(s.command.contains(#"c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c"#))
        #expect(!s.command.contains("exec"))
    }

    @Test func claudeResumesById() throws {
        #expect(try inner(spec(leaf(.claude, id: "abc"))) == "claude --resume abc")
        #expect(try inner(spec(leaf(.claude), restoring: true)) == "claude --continue")
        #expect(try inner(spec(leaf(.claude))) == "claude")
        #expect(try inner(spec(leaf(.claude, id: "abc"), prompt: "hi")) == "claude --resume abc")
    }

    @Test func initialPromptIsArgument() throws {
        #expect(try inner(spec(leaf(.claude), prompt: "fix it's bug")) == #"claude 'fix it'\''s bug'"#)
        #expect(try inner(spec(leaf(.codex), prompt: "fix it's bug")) == #"codex 'fix it'\''s bug'"#)
    }

    @Test func codexResume() throws {
        #expect(try inner(spec(leaf(.codex, id: "abc"))) == "codex resume abc")
        #expect(try inner(spec(leaf(.codex), restoring: true)) == "codex resume --last")
        #expect(try inner(spec(leaf(.codex))) == "codex")
    }

    @Test func editorOpensFile() throws {
        #expect(try inner(spec(leaf(.editor, file: "src/a b.ts"))) == "hx 'src/a b.ts'")
        #expect(try inner(spec(leaf(.editor))) == "hx")
    }

    @Test func argumentsAreShellQuoted() throws {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("") == "''")
        #expect(shellQuote("abc-1.2/x") == "abc-1.2/x")
        #expect(try inner(spec(leaf(.claude, id: "a;b"))) == "claude --resume 'a;b'")
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
        #expect(sl.command.contains("/opt/homebrew/bin/fish -l -i"))
        #expect(try spec(leaf(.claude), shell: "/bin/bash").command.hasPrefix("/bin/bash -l -i -c '"))
    }
}
