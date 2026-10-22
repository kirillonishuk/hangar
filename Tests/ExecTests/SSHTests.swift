import Foundation
import Testing
@testable import Exec

@Suite struct SSHTests {
    /// Temp dir with a fake ssh; `dir` has a space and Cyrillic on purpose.
    private func fake() throws -> (dir: String, ssh: (path: String, log: String, home: String), cleanup: () -> Void) {
        let root = NSTemporaryDirectory() + "hangar-ssh-\(UUID().uuidString)"
        let dir = root + "/папка с пробелом"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ssh = try FakeSSH.make(dir: root + "/fake")
        return (dir, ssh, { try? FileManager.default.removeItem(atPath: root) })
    }

    @Test func hostValidated() {
        for ok in ["dev", "user@host.example", "[::1]", "h-1_2"] { #expect(validSSHHost(ok) == ok) }
        let long = String(repeating: "a", count: 256)
        for bad in ["-oProxyCommand=x", "-oProxyCommand=touch /tmp/x", "a b", "h;rm", "\"$(id)\"", "`id`", "a'b",
                    "a|b", "a&b", "u@-oProxyCommand=x", "@-x", "a<b", "a\\b", "", long, "a\nb", "a\tb", "a\u{7f}b"] {
            #expect(validSSHHost(bad) == nil, "\(bad)")
        }
        #expect(validSSHHost(String(repeating: "a", count: 255)) != nil)
    }

    @Test func shellQuoteSurvivesBackslashes() async throws {
        // A backslash stays outside single quotes: fish (a possible login shell) treats `\'` inside them as a quote.
        #expect(shellQuote(#"a\'b"#) == #"'a'\\''\''b'"#)
        // zsh expands a leading `=cmd` to the command's path.
        #expect(shellQuote("=ls") == "'=ls'")
        #expect(shellQuote("a=b") == "a=b")
        for sh in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            for v in ["=ls", #"a\'b"#, #"\\"#, #"x\"#, "it's", "$(id)"] {
                let r = try await Runner.local.run([sh, "-c", "printf %s " + shellQuote(v)], "/")
                #expect(r.stdout == v, "\(sh) \(v)")
            }
        }
    }

    @Test func remoteArgsArePositional() async throws {
        let f = try fake(); defer { f.cleanup() }
        let cp = f.dir + "/cm"
        let runner = Runner.ssh(host: "dev", controlPath: cp, sshPath: f.ssh.path)
        #expect(!runner.isLocal)
        let hostile = ["a b", "it's", "$(touch pwned)", "`touch pwned2`", "x;touch pwned3", "l1\nl2", "-n", #"b\'c"#, "привет"]
        let r = try await runner.run(["printf", "%s|"] + hostile, f.dir)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout == hostile.map { $0 + "|" }.joined())
        for name in ["pwned", "pwned2", "pwned3"] {
            #expect(!FileManager.default.fileExists(atPath: f.dir + "/" + name))
            #expect(!FileManager.default.fileExists(atPath: f.ssh.home + "/" + name))
        }
        let call = try #require(FakeSSH.calls(f.ssh.log).last)
        let dd = try #require(call.firstIndex(of: "--"))
        #expect(call[dd + 1] == "dev")
        let before = Array(call[..<dd])
        #expect(zip(before, before.dropFirst()).contains { $0 == ("-o", "BatchMode=yes") })
        #expect(zip(before, before.dropFirst()).contains { $0 == ("-o", "ControlMaster=no") })
        #expect(zip(before, before.dropFirst()).contains { $0 == ("-o", "ConnectTimeout=10") })
        #expect(zip(before, before.dropFirst()).contains { $0 == ("-S", cp) })
    }

    @Test func emptyCwdIsRemoteHome() async throws {
        let f = try fake(); defer { f.cleanup() }
        let r = try await Runner.ssh(host: "dev", controlPath: "/tmp/x", sshPath: f.ssh.path).run(["sh", "-c", "pwd; echo $GIT_TERMINAL_PROMPT"], "")
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(URL(fileURLWithPath: lines.first ?? "").resolvingSymlinksInPath().path
                == URL(fileURLWithPath: f.ssh.home).resolvingSymlinksInPath().path)
        #expect(lines.last == "0")
    }

    @Test func invalidHostNeverRunsSSH() async throws {
        let f = try fake(); defer { f.cleanup() }
        let runner = Runner.ssh(host: "-oProxyCommand=touch /tmp/x", controlPath: "/tmp/x", sshPath: f.ssh.path)
        await #expect(throws: SSHError.self) { try await runner.run(["true"], "") }
        await #expect(throws: SSHError.self) {
            try await sshWrite(host: "a b", controlPath: "/tmp/x", sshPath: f.ssh.path, script: "cat", args: [], input: Data())
        }
        #expect(FakeSSH.calls(f.ssh.log).isEmpty)
    }

    @Test func sshWritePassesStdin() async throws {
        let f = try fake(); defer { f.cleanup() }
        let target = f.dir + "/out it's"
        let data = Data("line1\nпривет $(id)\n".utf8)
        let r = try await sshWrite(host: "dev", controlPath: "/tmp/x", sshPath: f.ssh.path,
                                   script: "cat > \"$1\"", args: [target], input: data)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(FileManager.default.contents(atPath: target) == data)
    }

    @Test func sshAuthFailureIsStatus() async throws {
        let f = try fake(); defer { f.cleanup() }
        try "auth".write(toFile: (f.ssh.path as NSString).deletingLastPathComponent + "/fail", atomically: true, encoding: .utf8)
        let r = try await Runner.ssh(host: "dev", controlPath: "/tmp/x", sshPath: f.ssh.path).run(["true"], "")
        #expect(r.status == 255)
        #expect(r.stderr.contains("Permission denied"))
    }

    @Test func cancelKillsLocalSSH() async throws {
        let f = try fake(); defer { f.cleanup() }
        try "".write(toFile: (f.ssh.path as NSString).deletingLastPathComponent + "/hang", atomically: true, encoding: .utf8)
        let start = SuspendingClock.now
        let runner = Runner.ssh(host: "dev", controlPath: "/tmp/x", sshPath: f.ssh.path)
        let task = Task { try await runner.run(["true"], "") }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Long before the fake's 300 s hang; loose for a busy cooperative pool, blind to a system sleep.
        #expect(SuspendingClock.now - start < .seconds(20))
    }

    @Test func controlPathFitsSocketLimit() throws {
        let long = SSHPaths(stateDir: "/" + String(repeating: "s", count: 119))
        let cp = long.controlPath("dev")
        #expect(cp.hasPrefix("/tmp/hangar-\(getuid())/cm-"))
        #expect(cp.utf8.count + 17 < 104)
        #expect(long.hostSocket("dev").hasPrefix("/tmp/hangar-\(getuid())/r-"))

        // sun_path counts the NUL: cp + 17 == 104 no longer fits.
        let edge = SSHPaths(stateDir: "/" + String(repeating: "e", count: 62))
        #expect(edge.stateDir.utf8.count + "/ssh/cm-".utf8.count + 16 + 17 == 104)
        #expect(edge.controlPath("dev").hasPrefix("/tmp/hangar-\(getuid())/"))
        let fits = SSHPaths(stateDir: "/" + String(repeating: "e", count: 61))
        #expect(fits.controlPath("dev").hasPrefix(fits.stateDir + "/ssh/"))
        #expect(fits.controlPath("dev").utf8.count + 17 == 103)

        let short = SSHPaths(stateDir: "/tmp/st")
        #expect(short.controlPath("dev") == "/tmp/st/ssh/cm-" + fnv1a64Hex("dev"))
        #expect(short.hostSocket("dev") == "/tmp/st/ssh/r-" + fnv1a64Hex("dev") + ".sock")
        #expect(short.controlPath("dev") == short.controlPath("dev"))
        #expect(short.controlPath("dev") != short.controlPath("prod"))
        #expect(fnv1a64Hex("") == "cbf29ce484222325")
        #expect(fnv1a64Hex("a") == "af63dc4c8601ec8c")
    }

    @Test func prepareMakesPrivateDir() throws {
        let root = "/tmp/hg-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = SSHPaths(stateDir: root)
        #expect(paths.dir == root + "/ssh")
        try paths.prepare()
        let attrs = try FileManager.default.attributesOfItem(atPath: root + "/ssh")
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func sshConfigHostList() {
        let text = """
        # comment
        Host dev prod
          HostName 10.0.0.1
        host=box
        Host *
        Host !bad
        Match all
        HOST  dev   *.example  h?
        Host = spaced
        Host dev2 # my box
        """
        #expect(sshConfigHosts(text) == ["dev", "prod", "box", "spaced", "dev2"])
    }

    @Test func directoryExistsRemote() async throws {
        let f = try fake(); defer { f.cleanup() }
        let runner = Runner.ssh(host: "dev", controlPath: "/tmp/x", sshPath: f.ssh.path)
        try "x".write(toFile: f.dir + "/file", atomically: true, encoding: .utf8)
        #expect(await directoryExists(f.dir, runner: runner))
        #expect(await !directoryExists(f.dir + "/file", runner: runner))
        #expect(await !directoryExists(f.dir + "/nope", runner: runner))
        #expect(await directoryExists(f.dir, runner: .local))
    }

    @Test func runnerIsLocalFlag() {
        #expect(Runner.local.isLocal)
        #expect(!Runner { _, _ in RunResult(status: 0, stdout: "", stderr: "") }.isLocal)
    }
}
