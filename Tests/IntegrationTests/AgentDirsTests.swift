import Exec
import Foundation
import Testing
@testable import Integration

@Suite struct AgentDirsTests {
    let home = URL(fileURLWithPath: "/Users/u")

    @Test func defaultPaths() {
        let p = integrationPaths(home: home, claudeConfigDir: nil, codexHome: nil)
        #expect(p.claude.path == "/Users/u/.claude/settings.json")
        #expect(p.codex.path == "/Users/u/.codex/config.toml")
    }

    @Test func envDirsWin() {
        let p = integrationPaths(home: home, claudeConfigDir: "/x/claude-cfg", codexHome: "/y/codex")
        #expect(p.claude.path == "/x/claude-cfg/settings.json")
        #expect(p.codex.path == "/y/codex/config.toml")
    }

    @Test func emptyOrRelativeIgnored() {
        let p = integrationPaths(home: home, claudeConfigDir: "", codexHome: "rel/dir")
        #expect(p.claude.path == "/Users/u/.claude/settings.json")
        #expect(p.codex.path == "/Users/u/.codex/config.toml")
    }

    @Test func parsesShellOutputAfterNoise() {
        #expect(parseAgentDirs("motd\n__hangar_dirs__/a/c\0/b/x\0") == ("/a/c", "/b/x"))
        #expect(parseAgentDirs("__hangar_dirs__\0/b/x\0") == (nil, "/b/x"))
        #expect(parseAgentDirs("garbage") == (nil, nil))
    }

    @Test func resolvesViaRunner() async {
        let runner = Runner { args, _ in
            #expect(args.prefix(4) == ["/bin/zsh", "-l", "-i", "-c"])
            return RunResult(status: 0, stdout: "hi\n__hangar_dirs__/c\0\0", stderr: "")
        }
        let d = await resolveAgentDirs(runner: runner, shell: "/bin/zsh")
        #expect(d.claude == "/c" && d.codex == nil)
    }

    @Test func hangingShellTimesOut() async {
        let runner = Runner { _, _ in
            try await Task.sleep(for: .seconds(600))
            return RunResult(status: 0, stdout: "__hangar_dirs__/c\0/d\0", stderr: "")
        }
        let start = SuspendingClock.now
        let d = await resolveAgentDirs(runner: runner, shell: "/bin/zsh", timeout: .milliseconds(100))
        #expect(d.claude == nil && d.codex == nil)
        // Long before the 600 s hang: the timer and the cancelled child wait for a busy cooperative pool under load.
        #expect(SuspendingClock.now - start < .seconds(20))
    }
}
