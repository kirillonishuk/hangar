import Foundation
import Testing
import Workspace
@testable import Exec

/// Remote tabs (#47) against a fake ssh that runs the remote command locally; tmux is the real one on an isolated
/// `TMUX_TMPDIR` whose server is killed at the end. Never a real host.
@Suite struct RemoteLaunchTests {
    static let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// A short root (tmux socket path), a fake login shell (skips /etc/profile) and a fake ssh.
    final class Fixture: @unchecked Sendable {
        let root: String, home: String, ssh: String, login: String
        let env: [String: String]

        /// `decode`: the fake ssh only records its argv, TERM and the remote words instead of running them.
        init(decode: Bool = false) throws {
            root = "/tmp/hl-" + UUID().uuidString.prefix(8)
            home = root + "/home"
            ssh = root + "/ssh"
            login = root + "/login-sh"
            let fm = FileManager.default
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: root + "/tmux", withIntermediateDirectories: true)
            let r = shellQuote(root)
            try "#!/bin/sh\nwhile [ $# -gt 0 ] && [ \"$1\" != -c ]; do shift; done\n[ $# -gt 0 ] || exec /bin/sh\nexec /bin/sh -c \"$2\"\n"
                .write(toFile: login, atomically: true, encoding: .utf8)
            let tail = decode
                ? "eval \"set -- $1\"\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \(r)/remote\nexit 0\n"
                : "export HOME=\(shellQuote(home))\ncd \"$HOME\" || exit 255\nexec /bin/sh -c \"$1\"\n"
            let script = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \(r)/argv\nprintf '%s' \"$TERM\" > \(r)/term\n"
                + "while [ $# -gt 0 ] && [ \"$1\" != -- ]; do shift; done\nshift 2\n" + tail
            try script.write(toFile: ssh, atomically: true, encoding: .utf8)
            for x in [login, ssh] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: x) }
            let tmuxDir = RemoteLaunchTests.tmuxPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/usr/bin"
            env = ["PATH": "\(tmuxDir):/usr/bin:/bin", "SHELL": login, "HOME": home, "TMUX_TMPDIR": root + "/tmux",
                   "TERM": "xterm-ghostty", "LANG": "en_US.UTF-8"]
        }

        func target(tmux: Bool) -> RemoteTarget {
            RemoteTarget(host: "dev", controlPath: root + "/cm", home: home, tmux: tmux, sshPath: ssh)
        }

        func read(_ name: String) -> String { (try? String(contentsOfFile: root + "/" + name, encoding: .utf8)) ?? "" }

        func tmux(_ args: [String]) async throws -> RunResult {
            try await runProcess(RemoteLaunchTests.tmuxPath ?? "/usr/bin/tmux", args, cwd: "/", env: env)
        }

        /// The tab command in a pty (tmux needs a terminal), as Ghostty would run it; returns its exit code.
        func run(_ command: String) async throws -> Int32 {
            let code = root + "/code-" + UUID().uuidString
            var e = env
            e["HANGAR_T_CMD"] = command
            e["HANGAR_T_CODE"] = code
            _ = try await runProcess("/usr/bin/script", ["-q", "/dev/null", "/bin/sh", "-c", #"eval "$HANGAR_T_CMD"; echo $? > "$HANGAR_T_CODE""#],
                                     cwd: "/", env: e)
            return Int32((try? String(contentsOfFile: code, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -999
        }

        /// Runs `body`, then always kills the isolated tmux server and removes the root.
        static func with(_ body: (Fixture) async throws -> Void) async throws {
            let f = try Fixture()
            do { try await body(f) } catch { await f.cleanup(); throw error }
            await f.cleanup()
        }

        func cleanup() async {
            if RemoteLaunchTests.tmuxPath != nil { _ = try? await tmux(["kill-server"]) }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// Test-only wait for an async side effect; SuspendingClock survives Mac sleep.
    private func waitUntil(_ seconds: Double = 20, _ cond: () async -> Bool) async -> Bool {
        let clock = SuspendingClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await cond()
    }

    private func command(_ f: Fixture, leaf: UUID, cwd: String? = nil, agent: String, tmux: Bool = true) -> String {
        remoteTabCommand(target: f.target(tmux: tmux), tabId: UUID(), leafId: leaf, cwd: cwd ?? f.home, agentCommand: agent)
    }

    @Test func commandShape() async throws {
        let f = try Fixture(decode: true)
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let tab = UUID()
        let leaf = Leaf(kind: .claude, cwd: "/srv/my app")
        let spec = remoteLaunchSpec(for: leaf, tabId: tab, target: f.target(tmux: true), editor: "hx", restoring: false, initialPrompt: "fix it")
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
        #expect(words.contains("claude 'fix it'"))

        // Resume by id; the Mac's [agents] path never reaches the server.
        let resumed = Leaf(kind: .claude, cwd: "/srv", agentSessionId: "abc")
        #expect(agentCommand(for: resumed, agent: { $0.rawValue }, editor: "hx", shell: "sh", restoring: true, initialPrompt: nil) == "claude --resume abc")
        var config = HangarConfig()
        config.agentCommands[.claude] = "/Users/me/bin/claude"
        let local = try launchSpec(for: Leaf(kind: .claude, cwd: NSTemporaryDirectory()), tabId: tab, config: config, socketPath: "/tmp/h.sock",
                                   userShell: "/bin/zsh", restoring: false, initialPrompt: nil)
        #expect(local.command.contains("/Users/me/bin/claude"))
        let remote = remoteLaunchSpec(for: resumed, tabId: tab, target: f.target(tmux: true), editor: "hx", restoring: true, initialPrompt: nil)
        #expect(!remote.command.contains("/Users/me"))
        _ = try await runProcess("/bin/sh", ["-c", remote.command], cwd: "/", env: f.env)
        #expect(f.read("remote").contains("claude --resume abc"))

        let editor = Leaf(kind: .editor, cwd: "/srv", openFile: "/srv/a b.txt", openLine: 3)
        #expect(agentCommand(for: editor, agent: { $0.rawValue }, editor: "hx", shell: "sh", restoring: false, initialPrompt: nil) == "hx '/srv/a b.txt:3'")
        #expect(killSessionArgs(leaf.id) == ["tmux", "kill-session", "-t", "=" + name])
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

    @Test(.enabled(if: tmuxPath != nil)) func tmuxSessionSurvivesClient() async throws { try await Fixture.with { f in
        let leaf = UUID(), name = remoteSessionName(leaf), marker = f.root + "/started"
        let cmd = command(f, leaf: leaf, agent: "echo started >> \(shellQuote(marker)); sleep 30")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil { f.read("started") == "started\n" })
        let pane = try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout
        // The connection drops: the tmux client dies, the session stays.
        let clients = try await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout
        for pid in clients.split(separator: "\n").compactMap({ pid_t($0) }) { kill(pid, SIGHUP) }
        #expect(try await first.value == 255)
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status == 0)

        let second = Task { try await f.run(cmd) }
        #expect(await waitUntil { (try? await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout.isEmpty) == false })
        #expect(try await f.tmux(["list-panes", "-t", "=" + name, "-F", "#{pane_pid}"]).stdout == pane)
        #expect(f.read("started") == "started\n")
        let args = killSessionArgs(leaf)
        #expect(try await f.tmux(Array(args.dropFirst())).status == 0)
        _ = try await second.value
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status != 0)
    } }

    @Test(.enabled(if: tmuxPath != nil)) func exitCodesThroughTmux() async throws { try await Fixture.with { f in
        for (agent, code) in [("exit 3", 3), ("exit 0", 0), ("exit 255", 254)] as [(String, Int32)] {
            #expect(try await f.run(command(f, leaf: UUID(), agent: agent)) == code, "\(agent)")
        }

        // Detach: the session goes on, the tab says "not finished".
        let detached = UUID()
        let d = Task { try await f.run(command(f, leaf: detached, agent: "sleep 30")) }
        #expect(await waitUntil { (try? await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout.isEmpty) == false })
        _ = try await f.tmux(["detach-client", "-s", "=" + remoteSessionName(detached)])
        #expect(try await d.value == 255)
        _ = try await f.tmux(Array(killSessionArgs(detached).dropFirst()))

        // The agent exits with 5 while no client is attached: the next launch reports 5 and starts nothing.
        let leaf = UUID(), name = remoteSessionName(leaf), go = f.root + "/go", marker = f.root + "/started5"
        let cmd = command(f, leaf: leaf, agent: "echo started >> \(shellQuote(marker)); while [ ! -f \(shellQuote(go)) ]; do sleep 0.05; done; exit 5")
        let first = Task { try await f.run(cmd) }
        #expect(await waitUntil { f.read("started5") == "started\n" })
        let clients = try await f.tmux(["list-clients", "-F", "#{client_pid}"]).stdout
        for pid in clients.split(separator: "\n").compactMap({ pid_t($0) }) { kill(pid, SIGHUP) }
        #expect(try await first.value == 255)
        try "".write(toFile: go, atomically: true, encoding: .utf8)
        #expect(await waitUntil { (try? await f.tmux(["has-session", "-t", "=" + name]).status) != 0 })
        #expect(try await f.run(cmd) == 5)
        #expect(try await f.tmux(["has-session", "-t", "=" + name]).status != 0)
        #expect(f.read("started5") == "started\n")
    } }
}
