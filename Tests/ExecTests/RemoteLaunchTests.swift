import Foundation
import Testing
import Workspace
@testable import Exec
import TestSupport

/// Remote tabs (#47) against a fake ssh that runs the remote command locally; tmux is the real one on an isolated
/// `TMUX_TMPDIR` whose server is killed at the end. Never a real host.
@Suite struct RemoteLaunchTests {
    static let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A short root (tmux socket path), a fake login shell (skips /etc/profile) and a fake ssh.
    final class Fixture: @unchecked Sendable {
        let root: String, home: String, ssh: String, login: String
        var env: [String: String]

        /// `decode`: the fake ssh only records its argv, TERM and the remote words instead of running them.
        init(decode: Bool = false) throws {
            root = "/tmp/hl-" + UUID().uuidString.prefix(8)
            home = root + "/home"
            ssh = root + "/ssh"
            login = root + "/login-sh"
            let fm = FileManager.default
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: root + "/tmux", withIntermediateDirectories: true)
            try writeScript("#!/bin/sh\nwhile [ $# -gt 0 ] && [ \"$1\" != -c ]; do shift; done\n[ $# -gt 0 ] || exec /bin/sh\nexec /bin/sh -c \"$2\"\n", to: login)
            // `<root>` from `$0`: no per-test content (see `writeScript`).
            let tail = decode
                ? "eval \"set -- $1\"\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$R/remote\"\nexit 0\n"
                : "export HOME=\"$R/home\"\ncd \"$HOME\" || exit 255\nexec /bin/sh -c \"$1\"\n"
            let script = "#!/bin/sh\nR=${0%/*}\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$R/argv\"\nprintf '%s' \"$TERM\" > \"$R/term\"\n"
                + "while [ $# -gt 0 ] && [ \"$1\" != -- ]; do shift; done\nshift 2\n" + tail
            try writeScript(script, to: ssh)
            let tmuxDir = RemoteLaunchTests.tmuxPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/usr/bin"
            env = ["PATH": "\(tmuxDir):/usr/bin:/bin", "SHELL": login, "HOME": home, "TMUX_TMPDIR": root + "/tmux",
                   "TERM": "xterm-ghostty", "LANG": "en_US.UTF-8"]
        }

        func target(tmux: Bool) -> RemoteTarget {
            RemoteTarget(host: "dev", controlPath: root + "/cm", home: home, tmux: tmux, sshPath: ssh)
        }

        func read(_ name: String) -> String { (try? String(contentsOfFile: root + "/" + name, encoding: .utf8)) ?? "" }

        /// Hangar's own tmux server (`-L hangar`) on the isolated `TMUX_TMPDIR`.
        func tmux(_ args: [String]) async throws -> RunResult { try await argv(["tmux", "-L", "hangar"] + args) }

        /// A `tmux …` argv as the server would run it (e.g. `killSessionArgs`).
        func argv(_ argv: [String]) async throws -> RunResult {
            try await runProcess(RemoteLaunchTests.tmuxPath ?? "/usr/bin/tmux", Array(argv.dropFirst()), cwd: "/", env: env)
        }

        func clients() async -> [pid_t] {
            ((try? await tmux(["list-clients", "-F", "#{client_pid}"]).stdout) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        }

        /// The tab command in a pty (tmux needs a terminal), as Ghostty would run it; returns its exit code.
        func run(_ command: String) async throws -> Int32 {
            let code = root + "/code-" + UUID().uuidString
            var e = env
            e["HANGAR_T_CMD"] = command
            e["HANGAR_T_CODE"] = code
            // A deadline: a broken script must fail the test, not hang it (cancel kills `script`, its pty hangs up the rest).
            let run = Task { try await runProcess("/usr/bin/script", ["-q", "/dev/null", "/bin/sh", "-c", #"eval "$HANGAR_T_CMD"; echo $? > "$HANGAR_T_CODE""#],
                                                  cwd: "/", env: e) }
            let timer = Task { try await Task.sleep(nanoseconds: 60_000_000_000); run.cancel() }
            _ = try? await run.value
            timer.cancel()
            return Int32((try? String(contentsOfFile: code, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -999
        }

        /// Runs `body`, then always kills the isolated tmux server and removes the root.
        static func with(_ body: (Fixture) async throws -> Void) async throws {
            let f = try Fixture()
            // The first exec of a fresh script is slow on macOS (security scan), worse under load.
            _ = try? await runProcess(f.login, ["-c", "true"], cwd: "/", env: f.env)
            _ = try? await runProcess(f.ssh, ["--", "dev", "true"], cwd: "/", env: f.env)
            do { try await body(f) } catch { await f.cleanup(); throw error }
            await f.cleanup()
        }

        func cleanup() async {
            if RemoteLaunchTests.tmuxPath != nil {
                _ = try? await tmux(["kill-server"])
                _ = try? await argv(["tmux", "kill-server"])
            }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func command(_ f: Fixture, leaf: UUID, cwd: String? = nil, agent: String, tmux: Bool = true) -> String {
        remoteTabCommand(target: f.target(tmux: tmux), tabId: UUID(), leafId: leaf, cwd: cwd ?? f.home, agentCommand: agent)
    }

    @Test func commandShape() async throws {
        let f = try Fixture(decode: true)
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let tab = UUID()
        let leaf = Leaf(kind: .claude, cwd: "/srv/my app")
        let spec = remoteLaunchSpec(for: leaf, tabId: tab, target: f.target(tmux: true), restoring: false, initialPrompt: "fix it")
        #expect(spec.cwd == NSHomeDirectory() && spec.env.isEmpty)
        #expect(spec.command.contains("TERM=xterm-256color"))
        _ = try await runProcess("/bin/sh", ["-c", spec.command], cwd: "/", env: f.env)
        let argv = f.read("argv").split(separator: "\n").map(String.init)
        #expect(f.read("term") == "xterm-256color")
        #expect(argv.contains("-t"))
        #expect(argv.contains("ControlMaster=no"))
        let dash = try #require(argv.firstIndex(of: "--"))
        #expect(argv[dash + 1] == "dev")
        let words = f.read("remote").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let name = "hangar-" + leaf.id.uuidString.lowercased()
        #expect(remoteSessionName(leaf.id) == name)
        #expect(words.contains("/srv/my app"))
        #expect(words.contains(name))
        #expect(words.contains(f.home + "/.hangar/run/" + name + ".exit"))
        #expect(words.contains(tab.uuidString) && words.contains(leaf.id.uuidString))
        #expect(words.contains(f.home + "/.hangar/hangar.sock"))
        // The server's claude gets Hangar's own hooks through `hangar-remote` (#119), quoted as one argument.
        let settings = " --settings " + shellQuote(tabAgentSettings(hookCLI: remoteHookCLI))
        #expect(words.contains("claude\(settings) 'fix it'"))
        #expect(tabAgentSettings(hookCLI: remoteHookCLI).contains(#"h=\"$HOME/.hangar/bin/hangar-remote\"; [ -x \"$h\" ]"#))

        // Resume by id; the Mac's [agents] path never reaches the server.
        let resumed = Leaf(kind: .claude, cwd: "/srv", agentSessionId: "abc")
        #expect(agentCommand(for: resumed, agent: { $0.rawValue }, shell: "sh", restoring: true, initialPrompt: nil) == "claude --resume abc")
        var config = HangarConfig()
        config.agentCommands[.claude] = "/Users/me/bin/claude"
        let local = try launchSpec(for: Leaf(kind: .claude, cwd: NSTemporaryDirectory()), tabId: tab, config: config, socketPath: "/tmp/h.sock",
                                   userShell: "/bin/zsh", restoring: false, initialPrompt: nil)
        #expect(local.command.contains("/Users/me/bin/claude"))
        let remote = remoteLaunchSpec(for: resumed, tabId: tab, target: f.target(tmux: true), restoring: true, initialPrompt: nil)
        #expect(!remote.command.contains("/Users/me"))
        _ = try await runProcess("/bin/sh", ["-c", remote.command], cwd: "/", env: f.env)
        #expect(f.read("remote").contains("claude\(settings) --resume abc"))

        #expect(killSessionArgs(leaf.id) == ["tmux", "-L", "hangar", "kill-session", "-t", "=" + name])
    }

    /// The plain login of «<host> · терминал» (#64): no tmux, no server check, no BatchMode (a password or 2FA is
    /// typed in the tab); the login is the master of its leaf socket (#124) and its remote command only adds the folder
    /// hook before the login shell; ssh's own code comes back.
    @Test func plainSSHShell() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let spec = sshShellSpec(host: "my-box", sshPath: f.ssh, controlPath: f.root + "/hs-1")
        #expect(spec.cwd == NSHomeDirectory() && spec.env.isEmpty)
        let r = try await runProcess("/bin/sh", ["-c", spec.command], cwd: "/", env: f.env)
        #expect(r.status == 0)
        #expect(r.stdout.contains("\u{1b}]133;D;0"))
        let argv = f.read("argv").split(separator: "\n").map(String.init)
        #expect(f.read("term") == "xterm-256color")
        #expect(argv.contains("-t"))
        #expect(Array(argv.prefix(7)) == ["-t", "-S", f.root + "/hs-1", "-o", "ControlMaster=auto", "-o", "ControlPersist=no"])
        let dash = try #require(argv.firstIndex(of: "--"))
        // The remote command spans lines (the fake writes one argv word per line).
        #expect(argv[(dash + 1)...].joined(separator: "\n") == "my-box\n" + remoteShellArgs(script: hostShellLoginScript, []))
        #expect(!argv.contains { $0.hasPrefix("BatchMode") || $0.contains("tmux") || $0.hasPrefix("ProxyCommand") })

        // The connection drops: ssh's 255 is the tab's code (a local leaf: ↩ logs in again).
        let failing = f.root + "/ssh-255"
        try writeScript("#!/bin/sh\nexit 255\n", to: failing)
        let lost = try await runProcess("/bin/sh", ["-c", sshShellSpec(host: "my-box", sshPath: failing, controlPath: f.root + "/hs-1").command],
                                        cwd: "/", env: f.env)
        #expect(lost.status == 255)
        #expect(lost.stdout.contains("\u{1b}]133;D;255"))
    }

    @Test func reattachMode() {
        let previous = LaunchMode(restoring: false, initialPrompt: "hi")
        #expect(launchMode(for: Leaf(kind: .claude, cwd: "/a"), .reattach(previous: previous)) == LaunchMode(restoring: true, initialPrompt: nil))
        #expect(launchMode(for: Leaf(kind: .codex, cwd: "/a"), .reattach(previous: previous)) == LaunchMode(restoring: true, initialPrompt: nil))
        #expect(launchMode(for: Leaf(kind: .shell, cwd: "/a"), .reattach(previous: previous)) == LaunchMode(restoring: false, initialPrompt: nil))
        #expect(launchMode(for: Leaf(kind: .shell, cwd: "/a"), .reattach(previous: LaunchMode(restoring: true, initialPrompt: nil))).restoring)
    }

    @Test func missingFolder() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        for tmux in [true, false] {
            let cmd = command(f, leaf: UUID(), cwd: f.root + "/nope", agent: "true", tmux: tmux)
            let r = try await runProcess("/bin/sh", ["-c", cmd], cwd: "/", env: f.env)
            #expect(r.status == 254, "tmux \(tmux)")
            #expect(r.stderr.contains("hangar: no such folder"), "tmux \(tmux)")
        }
    }

    @Test func directExitCodes() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        for (agent, code) in [("exit 3", 3), ("exit 255", 254), ("printf '%s' \"$HANGAR_LEAF_ID\" > leaf", 0)] as [(String, Int32)] {
            let leaf = UUID()
            let r = try await runProcess("/bin/sh", ["-c", command(f, leaf: leaf, agent: agent, tmux: false)], cwd: "/", env: f.env)
            #expect(r.status == code, "\(agent)")
            if code == 0 { #expect((try? String(contentsOfFile: f.home + "/leaf", encoding: .utf8)) == leaf.uuidString) }
        }
    }

    /// The task's port reaches the remote tab's environment, with and without tmux (#60).
    @Test func portReachesRemoteTab() async throws { try await Fixture.with { f in
        for tmux in [false] + (RemoteLaunchTests.tmuxPath == nil ? [] : [true]) {
            let out = f.root + "/port-\(tmux)"
            let cmd = remoteTabCommand(target: f.target(tmux: tmux), tabId: UUID(), leafId: UUID(), cwd: f.home,
                                       agentCommand: "printf '%s' \"$HANGAR_PORT\" > \(shellQuote(out))", port: 41234)
            let code = tmux ? try await f.run(cmd) : try await runProcess("/bin/sh", ["-c", cmd], cwd: "/", env: f.env).status
            #expect(code == 0, "tmux \(tmux)")
            #expect(f.read("port-\(tmux)") == "41234", "tmux \(tmux)")
        }
    } }

    @Test(.enabled(if: tmuxPath != nil)) func tmuxSessionSurvivesClient() async throws { try await Fixture.with { f in
        let leaf = UUID(), name = remoteSessionName(leaf), marker = f.root + "/started"
        let cmd = command(f, leaf: leaf, agent: "echo started >> \(shellQuote(marker)); sleep 30")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { f.read("started") == "started\n" })
        let pane = try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout
        // The connection drops: the tmux client dies, the session stays.
        let clients = try await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout
        for pid in clients.split(separator: "\n").compactMap({ pid_t($0) }) { kill(pid, SIGHUP) }
        #expect(try await first.value == 255)
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status == 0)
        // The user's own default server is another server: its kill-server leaves the agent alone.
        _ = try await f.argv(["tmux", "new-session", "-d", "-s", "mine", "sleep 30"])
        _ = try await f.argv(["tmux", "kill-server"])
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status == 0)

        let second = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { (try? await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout.isEmpty) == false })
        #expect(try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout == pane)
        #expect(f.read("started") == "started\n")
        #expect(try await f.argv(killSessionArgs(leaf)).status == 0)
        _ = try await second.value
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status != 0)
    } }

    @Test(.enabled(if: tmuxPath != nil)) func exitCodesThroughTmux() async throws { try await Fixture.with { f in
        for (agent, code) in [("exit 3", 3), ("exit 0", 0), ("exit 255", 254)] as [(String, Int32)] {
            let got = try await f.run(command(f, leaf: UUID(), agent: agent))
            #expect(got == code, "\(agent): got \(got)")
        }

        // Detach: the session goes on, the tab says "not finished".
        let detached = UUID()
        let d = Task { try await f.run(command(f, leaf: detached, agent: "sleep 30")) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { (try? await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout.isEmpty) == false })
        _ = try await f.tmux(["detach-client", "-s", "=" + remoteSessionName(detached)])
        #expect(try await d.value == 255)
        _ = try await f.argv(killSessionArgs(detached))

        // The agent exits with 5 while no client is attached: the next launch reports 5 and starts nothing.
        let leaf = UUID(), name = remoteSessionName(leaf), go = f.root + "/go", marker = f.root + "/started5"
        let cmd = command(f, leaf: leaf, agent: "echo started >> \(shellQuote(marker)); while [ ! -f \(shellQuote(go)) ]; do sleep 0.05; done; exit 5")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { f.read("started5") == "started\n" })
        let clients = try await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout
        for pid in clients.split(separator: "\n").compactMap({ pid_t($0) }) { kill(pid, SIGHUP) }
        #expect(try await first.value == 255)
        try "".write(toFile: go, atomically: true, encoding: .utf8)
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { (try? await f.tmux(["has-session", "-t", "=" + name]).status) != 0 })
        #expect(try await f.run(cmd) == 5)
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status != 0)
        #expect(f.read("started5") == "started\n")
    } }

    /// tmux format-expands `-c`: the folder must reach the pane only through the script's own `cd`.
    @Test(.enabled(if: tmuxPath != nil)) func paneStartsInOddFolders() async throws { try await Fixture.with { f in
        for (i, name) in ["my#Dir", "#S", "x#{pane_id}", "a;"].enumerated() {
            let dir = f.home + "/" + name, out = f.root + "/pwd-\(i)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let code = try await f.run(command(f, leaf: UUID(), cwd: dir, agent: "pwd -P > \(shellQuote(out))"))
            #expect(code == 0, "\(name)")
            let expected = try await runProcess("/bin/sh", ["-c", "cd \"$1\" && pwd -P", "sh", dir], cwd: "/", env: f.env).stdout
            #expect(f.read("pwd-\(i)") == expected, "\(name)")
        }
    } }

    /// A stored code counts only when the session is gone; an unreadable one is "exit status lost" (254).
    @Test(.enabled(if: tmuxPath != nil)) func exitFileGuards() async throws { try await Fixture.with { f in
        for (text, code) in [("", 254), ("abc", 254), ("7", 7)] as [(String, Int32)] {
            let leaf = UUID()
            let file = f.home + "/.hangar/run/" + remoteSessionName(leaf) + ".exit"
            try FileManager.default.createDirectory(atPath: f.home + "/.hangar/run", withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            #expect(try await f.run(command(f, leaf: leaf, agent: "exit 9")) == code, "'\(text)'")
            #expect(!FileManager.default.fileExists(atPath: file))
        }

        // A live session wins over a file next to it: the launch attaches to the same pane and reports nothing early;
        // the file counts only once the session is gone (attach first, #47).
        let leaf = UUID(), name = remoteSessionName(leaf)
        let cmd = command(f, leaf: leaf, agent: "sleep 30")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await !f.clients().isEmpty })
        let pane = try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout
        for pid in await f.clients() { kill(pid, SIGHUP) }
        #expect(try await first.value == 255)
        try "7".write(toFile: f.home + "/.hangar/run/" + name + ".exit", atomically: true, encoding: .utf8)
        let second = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await !f.clients().isEmpty })
        #expect(try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout == pane)
        _ = try await f.argv(killSessionArgs(leaf))
        #expect(try await second.value == 7)
    } }

    /// Attach first, so a live session is never replaced: `attach -d` to a live session; only when that fails
    /// (the session is gone, any exit file is final) the file, then `new-session`. The status line is off.
    @Test(.enabled(if: tmuxPath != nil)) func attachComesFirst() async throws { try await Fixture.with { f in
        // A tmux on PATH that logs each subcommand (`tmux -L hangar <cmd> …`) and runs the real one.
        let wrap = f.root + "/wrap"
        try FileManager.default.createDirectory(atPath: wrap, withIntermediateDirectories: true)
        try writeScript("#!/bin/sh\nb=${0%/*}\necho \"$3\" >> \"${b%/*}/tmux.log\"\nexec \(shellQuote(RemoteLaunchTests.tmuxPath!)) \"$@\"\n",
                        to: wrap + "/tmux")
        f.env["PATH"] = wrap + ":" + (f.env["PATH"] ?? "")
        _ = try? await runProcess(wrap + "/tmux", ["-V"], cwd: "/", env: f.env)  // first exec of a fresh script is slow
        let launches = { f.read("tmux.log").split(separator: "\n").map(String.init).filter { ["attach", "new-session", "has-session"].contains($0) } }

        let leaf = UUID(), name = remoteSessionName(leaf), go = f.root + "/go"
        let cmd = command(f, leaf: leaf, agent: "while [ ! -f \(shellQuote(go)) ]; do sleep 0.05; done; exit 4")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await f.clients().count == 1 })
        #expect(launches() == ["attach", "new-session"])
        #expect(try await f.tmux(["show-options", "-t", "=" + name + ":", "status"]).stdout == "status off\n")

        // A live session: the next client only attaches (the old one is detached).
        let second = Task { try await f.run(cmd) }
        #expect(try await first.value == 255)
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await f.clients().count == 1 })
        #expect(launches() == ["attach", "new-session", "attach"])
        try "".write(toFile: go, atomically: true, encoding: .utf8)
        #expect(try await second.value == 4)
    } }

    /// A second client of the same leaf (a reconnect while the old connection lingers) takes over: the old one
    /// is detached at once, so only the live client reads the agent's code.
    @Test(.enabled(if: tmuxPath != nil)) func newClientTakesOver() async throws { try await Fixture.with { f in
        let leaf = UUID(), go = f.root + "/go"
        let cmd = command(f, leaf: leaf, agent: "while [ ! -f \(shellQuote(go)) ]; do sleep 0.05; done; exit 6")
        let old = Task { try await f.run(cmd) }
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await f.clients().count == 1 })
        let new = Task { try await f.run(cmd) }
        #expect(try await old.value == 255)
        #expect(await waitUntil(polls: 1200, every: .milliseconds(50)) { await f.clients().count == 1 })
        try "".write(toFile: go, atomically: true, encoding: .utf8)
        #expect(try await new.value == 6)
    } }
}
