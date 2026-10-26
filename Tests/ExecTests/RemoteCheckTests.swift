import Foundation
import Testing
@testable import Exec

@Suite struct RemoteCheckTests {
    private static let ubuntu = """
    Welcome!
    HANGAR os Linux
    HANGAR distro ubuntu
    HANGAR pm apt-get
    HANGAR uid 1000
    HANGAR sudo yes
    HANGAR home /home/dev
    HANGAR shell /usr/bin/fish
    motd: system restart required
    HANGAR tool git /usr/bin/git git version 2.43.0
    HANGAR missing tmux
    HANGAR tool claude /home/dev/.local/bin/claude 2.0.1 (Claude Code)
    HANGAR missing codex
    HANGAR missing hx
    HANGAR tool curl /usr/bin/curl curl 8.5.0 (x86_64-pc-linux-gnu)
    HANGAR missing npm
    HANGAR client python3
    HANGAR remote none
    HANGAR claude_dir /home/dev/.claude
    HANGAR codex_home /home/dev/.codex
    HANGAR end

    """

    private static let claudeInstall = "t=$(mktemp)\ntrap 'rm -f \"$t\"' EXIT\ncurl -fsSL -o \"$t\" https://claude.ai/install.sh\nbash \"$t\""
    private static let remoteInstall = #"mkdir -p "$HOME/.hangar/bin" && cat > "$HOME/.hangar/bin/hangar-remote.tmp" && chmod 700 "$HOME/.hangar/bin/hangar-remote.tmp" && mv -f "$HOME/.hangar/bin/hangar-remote.tmp" "$HOME/.hangar/bin/hangar-remote""#

    private func report(pm: PackageManager? = .aptGet, distro: String? = nil, uid: Int = 1000, sudo: Bool = true,
                        have: [RemoteTool] = RemoteTool.allCases, client: String? = "python3", remote: Int? = 1) -> ServerReport {
        var tools: [RemoteTool: ToolInfo] = [:]
        for t in have { tools[t] = ToolInfo(path: "/usr/bin/" + t.rawValue, version: "1") }
        return ServerReport(os: "Linux", home: "/home/dev", shell: "/bin/bash", claudeDir: "/home/dev/.claude",
                            codexHome: "/home/dev/.codex", distro: distro, packageManager: pm, uid: uid, hasSudo: sudo,
                            tools: tools, socketClient: client, remoteVersion: remote)
    }

    private func without(_ missing: [RemoteTool]) -> [RemoteTool] { RemoteTool.allCases.filter { !missing.contains($0) } }

    @Test func parseFullReport() throws {
        let r = try #require(parseServerReport(Self.ubuntu))
        #expect(r.os == "Linux")
        #expect(r.distro == "ubuntu")
        #expect(r.packageManager == .aptGet)
        #expect(r.uid == 1000)
        #expect(r.hasSudo)
        #expect(r.home == "/home/dev")
        #expect(r.shell == "/usr/bin/fish")
        #expect(r.tools[.git] == ToolInfo(path: "/usr/bin/git", version: "git version 2.43.0"))
        #expect(r.tools[.claude] == ToolInfo(path: "/home/dev/.local/bin/claude", version: "2.0.1 (Claude Code)"))
        #expect(r.tools[.tmux] == nil)
        #expect(r.tools.count == 3)
        #expect(r.socketClient == "python3")
        #expect(r.remoteVersion == nil)
        #expect(r.claudeDir == "/home/dev/.claude")
        #expect(r.codexHome == "/home/dev/.codex")
        #expect(r.tmux == false)
        #expect(r.missingRequired == [.tmux])
        #expect(r.remoteOutdated(current: 1))
    }

    /// The login PATH reaches every later remote command: only absolute entries, bounded; else nil (sshd's PATH).
    @Test func parseLoginPath() throws {
        #expect(try #require(parseServerReport(Self.ubuntu)).path == nil)
        let good = "/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin"
        for (value, expected) in [(good, good), ("bin:/usr/bin", nil), ("/usr/bin::/bin", nil), ("/usr/bin:", nil), ("", nil),
                                  ("/" + String(repeating: "a", count: 4000), nil)] as [(String, String?)] {
            let text = Self.ubuntu.replacingOccurrences(of: "HANGAR end\n", with: "HANGAR path \(value)\nHANGAR end\n")
            #expect(try #require(parseServerReport(text)).path == expected, "\(value)")
        }
    }

    @Test func parseRejectsTruncated() {
        #expect(parseServerReport(Self.ubuntu.replacingOccurrences(of: "HANGAR end\n", with: "")) == nil)
        #expect(parseServerReport(Self.ubuntu.replacingOccurrences(of: "HANGAR home /home/dev\n", with: "")) == nil)
        #expect(parseServerReport("") == nil)
    }

    @Test func parseIsStrict() throws {
        let hostile = Self.ubuntu
            .replacingOccurrences(of: "HANGAR client python3", with: "HANGAR client sh -c id")
            .replacingOccurrences(of: "HANGAR remote none", with: "HANGAR remote 1; rm -rf /")
            .replacingOccurrences(of: "HANGAR pm apt-get", with: "HANGAR pm apt-get;id")
            .replacingOccurrences(of: "HANGAR distro ubuntu", with: "HANGAR distro ubu ntu")
            .replacingOccurrences(of: "HANGAR missing npm", with: "HANGAR tool npm relative/npm 10\nHANGAR tool vim /usr/bin/vim 9")
            .replacingOccurrences(of: "HANGAR uid 1000", with: "HANGAR uid -5")
        let r = try #require(parseServerReport(hostile))
        #expect(r.socketClient == nil)
        #expect(r.remoteVersion == nil)
        #expect(r.packageManager == nil)
        #expect(r.distro == nil)
        #expect(r.tools[.npm] == nil)
        #expect(r.uid == -1)
        // A version longer than 80 characters is cut; control characters never survive.
        let long = Self.ubuntu.replacingOccurrences(of: "git version 2.43.0", with: String(repeating: "v", count: 500) + "\u{1b}[2J")
        #expect(try #require(parseServerReport(long)).tools[.git]?.version.count == 80)
        // An oversized line is dropped, not parsed.
        let huge = Self.ubuntu.replacingOccurrences(of: "HANGAR home /home/dev", with: "HANGAR home /" + String(repeating: "a", count: 5000))
        #expect(parseServerReport(huge) == nil)
        // Lines after `end` are ignored.
        let after = Self.ubuntu + "HANGAR tool tmux /usr/bin/tmux tmux 3.4\n"
        #expect(try #require(parseServerReport(after)).tools[.tmux] == nil)
        // CRLF output parses the same.
        #expect(parseServerReport(Self.ubuntu.replacingOccurrences(of: "\n", with: "\r\n")) == parseServerReport(Self.ubuntu))
    }

    /// codex and hx are optional: left out (not even «install yourself») until the user ticks them.
    @Test func optionalToolsOnlyWhenChosen() {
        #expect(RemoteTool.optionalInstalls == [.codex, .hx])
        let r = report(pm: .brew, have: without([.tmux, .hx, .codex]))
        var p = installPlan(r, remoteVersion: 1, optional: [])
        #expect(p.steps.map(\.command) == ["brew install tmux"])
        #expect(p.manual.isEmpty)
        p = installPlan(r, remoteVersion: 1, optional: [.codex])
        #expect(p.steps.map(\.command) == ["brew install tmux", "brew install codex"])
        p = installPlan(r, remoteVersion: 1, optional: [.hx])
        #expect(p.steps.map(\.command) == ["brew install tmux helix"])
        // Chosen but not installable here → manual.
        p = installPlan(report(have: without([.hx])), remoteVersion: 1, optional: [.hx])
        #expect(p.steps.isEmpty && p.manual == [.hx])
    }

    @Test func planTable() {
        // apt + no git, tmux, hx → hx is manual (no helix package on most apt releases).
        var p = installPlan(report(have: without([.git, .tmux, .hx])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps == [InstallStep(title: "packages", command: "sudo apt-get update\nsudo apt-get install -y git tmux", inTerminal: true)])
        #expect(p.manual == [.hx])

        p = installPlan(report(pm: .pacman, uid: 0, sudo: false, have: without([.git, .tmux, .hx])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["pacman -S --needed --noconfirm git tmux helix"])
        #expect(p.manual.isEmpty)

        p = installPlan(report(pm: .brew, have: without([.tmux, .hx])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["brew install tmux helix"])

        p = installPlan(report(pm: .dnf, have: without([.tmux])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["sudo dnf install -y tmux"])
        // helix only where the distro's own repos have it: Fedora yes, RHEL/Rocky/Alma/Amazon no.
        p = installPlan(report(pm: .dnf, distro: "fedora", have: without([.hx])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["sudo dnf install -y helix"])
        #expect(p.manual.isEmpty)
        for distro in ["rocky", "rhel", "almalinux", "amzn", nil] as [String?] {
            p = installPlan(report(pm: .dnf, distro: distro, have: without([.hx])), remoteVersion: 1, optional: [.hx, .codex])
            #expect(p.steps.isEmpty, "\(String(describing: distro))")
            #expect(p.manual == [.hx])
        }
        p = installPlan(report(pm: .apk, uid: 0, have: without([.hx])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["apk add helix"])
        p = installPlan(report(pm: .yum, have: without([.tmux])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["sudo yum install -y tmux"])
        p = installPlan(report(pm: .apk, uid: 0, have: without([.git]), client: nil), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["apk add git socat"])

        // No sudo for a normal user, or no package manager → nothing to run, everything manual.
        for r in [report(sudo: false, have: without([.git, .tmux, .hx])), report(pm: nil, have: without([.git, .tmux, .hx]))] {
            p = installPlan(r, remoteVersion: 1, optional: [.hx, .codex])
            #expect(p.steps.isEmpty)
            #expect(p.manual == [.git, .tmux, .hx])
        }

        // No claude and no curl → curl in the packages, the installer after them.
        p = installPlan(report(have: without([.claude, .curl])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.command) == ["sudo apt-get update\nsudo apt-get install -y curl", Self.claudeInstall])
        // …and without a way to get curl, claude is manual too.
        p = installPlan(report(pm: nil, have: without([.claude, .curl])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.isEmpty)
        #expect(p.manual == [.curl, .claude])

        // codex: brew, else npm, else manual.
        #expect(installPlan(report(pm: .brew, have: without([.codex])), remoteVersion: 1, optional: [.hx, .codex]).steps.map(\.command) == ["brew install codex"])
        #expect(installPlan(report(have: without([.codex])), remoteVersion: 1, optional: [.hx, .codex]).steps.map(\.command) == ["npm install -g @openai/codex"])
        p = installPlan(report(have: without([.codex, .npm])), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.isEmpty)
        #expect(p.manual == [.codex])

        // Everything present and hangar-remote current → nothing.
        p = installPlan(report(), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.isEmpty && p.manual.isEmpty)

        // hangar-remote missing or older → written over ssh stdin, not in the terminal.
        for old in [nil, 1] as [Int?] {
            p = installPlan(report(remote: old), remoteVersion: 2, optional: [.hx, .codex])
            #expect(p.steps == [InstallStep(title: "hangar-remote", command: Self.remoteInstall, inTerminal: false)])
        }
    }

    @Test func planIsWhatRuns() {
        let p = installPlan(report(have: [.npm], client: nil, remote: nil), remoteVersion: 1, optional: [.hx, .codex])
        #expect(p.steps.map(\.title) == ["packages", "claude", "codex", "hangar-remote"])
        #expect(p.steps[0].command == "sudo apt-get update\nsudo apt-get install -y git tmux socat curl")
        #expect(p.steps[1].command == Self.claudeInstall)
        #expect(p.manual == [.hx])
        #expect(terminalScript(p.steps) == "set -e\n" + p.steps.filter(\.inTerminal).map(\.command).joined(separator: "\n"))
        #expect(!terminalScript(p.steps).contains("hangar-remote"))
    }

    // MARK: the script itself, on local /bin/sh and dash with a fixture PATH

    /// A bin dir with only the utilities the script needs plus fake tools that log their argv to `<root>/calls`.
    private func fixture() throws -> (root: String, bin: String, home: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "hangar-check-\(UUID().uuidString)"
        let bin = root + "/bin", home = root + "/home dir"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.hangar/bin", withIntermediateDirectories: true)
        for u in ["uname", "id", "sed", "tr", "cut", "head", "cat", "mktemp", "rm", "mkdir", "dirname"] {
            let path = ["/usr/bin/" + u, "/bin/" + u].first { fm.fileExists(atPath: $0) }!
            try fm.createSymbolicLink(atPath: bin + "/" + u, withDestinationPath: path)
        }
        func tool(_ name: String, _ body: String) throws {
            let p = bin + "/" + name
            try writeScript("#!/bin/sh\nb=${0%/*}\nprintf '%s %s\\n' \(name) \"$*\" >> \"${b%/*}/calls\"\n\(body)\n", to: p)
        }
        try tool("git", "echo 'git version 2.43.0'")
        try tool("tmux", #"[ "$1" = -V ] && echo 'tmux 3.4' || { echo usage >&2; exit 1; }"#)
        try tool("claude", "echo " + String(repeating: "x", count: 120) + "; echo second line")
        try tool("curl", "printf 'curl 8.5\\033[2J\\n'")
        // Like helix: writes a log under its cache dir on start.
        try tool("hx", #"c=${XDG_CACHE_HOME:-$HOME/.cache}; mkdir -p "$c/helix" && echo x > "$c/helix/log"; printf '%s\n' "$c" > "$(dirname "$0")/../hxcache"; echo 'helix 25.01'"#)
        try tool("apt-get", "exit 0")
        try tool("brew", "exit 0")
        try tool("sudo", "exit 0")
        try tool("python3", "exit 0")
        try "#!/bin/sh\n# hangar-remote 3\n".write(toFile: home + "/.hangar/bin/hangar-remote", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home + "/.hangar/bin/hangar-remote")
        return (root, bin, home, { try? fm.removeItem(atPath: root) })
    }

    @Test func scriptReadsFixtureServer() async throws {
        let f = try fixture(); defer { f.cleanup() }
        for sh in ["/bin/sh", "/bin/dash"] where FileManager.default.fileExists(atPath: sh) {
            try? FileManager.default.removeItem(atPath: f.root + "/calls")
            let before = try FileManager.default.subpathsOfDirectory(atPath: f.home).sorted()
            let r = try await Runner.local.run(["env", "-i", "PATH=" + f.bin, "HOME=" + f.home, "SHELL=/bin/zsh",
                                                "CLAUDE_CONFIG_DIR=/cfg/claude", sh, "-c", serverCheckScript], "/")
            #expect(r.status == 0, "\(sh) \(r.stderr)")
            let lines = r.stdout.split(separator: "\n").map(String.init)
            #expect(lines.allSatisfy { $0.hasPrefix("HANGAR ") }, "\(sh) \(lines)")
            #expect(lines.last == "HANGAR end")
            let rep = try #require(parseServerReport(r.stdout), "\(sh) \(r.stdout)")
            #expect(rep.os == (try await Runner.local.run(["uname", "-s"], "/")).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(rep.packageManager == .aptGet)
            #expect(rep.hasSudo)
            #expect(rep.uid == Int(getuid()))
            #expect(rep.home == f.home)
            #expect(rep.shell == "/bin/zsh")
            #expect(rep.tools[.git] == ToolInfo(path: f.bin + "/git", version: "git version 2.43.0"))
            #expect(rep.tools[.tmux]?.version == "tmux 3.4")
            #expect(rep.tools[.claude]?.version == String(repeating: "x", count: 80))
            #expect(rep.tools[.curl]?.version == "curl 8.5[2J")
            #expect(rep.tools[.hx]?.version == "helix 25.01")
            #expect(rep.tools[.codex] == nil && rep.tools[.npm] == nil)
            // hx gets a temp XDG dir outside HOME, removed afterwards.
            let hxCache = try String(contentsOfFile: f.root + "/hxcache", encoding: .utf8).trimmingCharacters(in: .newlines)
            #expect(!hxCache.isEmpty && !hxCache.hasPrefix(f.home), "\(hxCache)")
            #expect(!FileManager.default.fileExists(atPath: hxCache))
            #expect(rep.socketClient == "python3")
            #expect(rep.remoteVersion == 3)
            #expect(rep.claudeDir == "/cfg/claude")
            #expect(rep.codexHome == f.home + "/.codex")
            // Read-only: tools only asked for their version, nothing written under HOME, sudo / package managers never run.
            let calls = (try String(contentsOfFile: f.root + "/calls", encoding: .utf8)).split(separator: "\n").sorted()
            #expect(calls == ["claude --version", "curl --version", "git --version", "hx --version", "tmux -V"], "\(sh)")
            #expect(try FileManager.default.subpathsOfDirectory(atPath: f.home).sorted() == before)
        }
    }

    @Test func scriptIsPOSIX() async throws {
        for sh in ["/bin/sh", "/bin/dash"] where FileManager.default.fileExists(atPath: sh) {
            #expect(try await Runner.local.run([sh, "-n", "-c", serverCheckScript], "/").status == 0, "\(sh)")
        }
    }

    @Test func checkViaFakeSSH() async throws {
        let root = NSTemporaryDirectory() + "hangar-checkssh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = try FakeSSH.make(dir: root + "/fake")
        // The login shell is /bin/sh with a system PATH so no real agent binary of this Mac is ever started.
        let wrapper = root + "/ssh"
        try writeScript("#!/bin/sh\nexport SHELL=/bin/sh PATH=/usr/bin:/bin\nexec \"${0%/*}/fake/ssh\" \"$@\"\n", to: wrapper)
        let runner = Runner.ssh(host: "dev", controlPath: root + "/cm", sshPath: wrapper)

        let r = await checkServer(runner)
        guard case .success(let rep) = r else { Issue.record("\(r)"); return }
        #expect(URL(fileURLWithPath: rep.home).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: fake.home).resolvingSymlinksInPath().path)
        #expect(rep.os == "Darwin")
        #expect(rep.tools[.git] != nil)

        try "auth".write(toFile: root + "/fake/fail", atomically: true, encoding: .utf8)
        #expect(await checkServer(runner) == .failure(.auth("Permission denied (publickey).")))
    }

    /// Runs `terminalScript` locally under /bin/sh with fake sudo / apt-get / curl / bash on PATH.
    private func runInstall(_ script: String, failing: [String]) async throws -> (status: Int32, calls: [String]) {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "hangar-install-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        let bin = root + "/bin"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin + "/rm", withDestinationPath: "/bin/rm")
        // macOS mktemp ignores TMPDIR: a fake one creates its files in `<root>/tmp` so leftovers can be seen.
        let tmp = root + "/tmp"
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try writeScript("#!/bin/sh\nb=${0%/*}\nf=\"${b%/*}/tmp/t.$$\"\n: > \"$f\"\nprintf '%s\\n' \"$f\"\n", to: bin + "/mktemp")
        for name in ["sudo", "apt-get", "curl", "bash"] {
            let body = name == "sudo" ? #""$@""# : (failing.contains(name) ? "exit 7" : "exit 0")
            try writeScript("#!/bin/sh\nb=${0%/*}\nprintf '%s %s\\n' \(name) \"$*\" >> \"${b%/*}/calls\"\n\(body)\n", to: bin + "/" + name)
        }
        let r = try await Runner.local.run(["env", "-i", "PATH=" + bin, "/bin/sh", "-c", script], "/")
        let calls = ((try? String(contentsOfFile: root + "/calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(try fm.contentsOfDirectory(atPath: tmp).isEmpty, "temp file left, failing: \(failing)")
        return (r.status, calls)
    }

    @Test func terminalScriptStopsOnFailure() async throws {
        let script = terminalScript(installPlan(report(have: without([.git, .claude, .curl])), remoteVersion: 1, optional: [.hx, .codex]).steps)
        // apt-get update fails → install never runs.
        var r = try await runInstall(script, failing: ["apt-get"])
        #expect(r.status != 0)
        #expect(r.calls == ["sudo apt-get update", "apt-get update"])
        // The download fails → the installer never runs (no `curl | bash` masking it).
        r = try await runInstall(script, failing: ["curl"])
        #expect(r.status != 0)
        #expect(r.calls.contains { $0.hasPrefix("curl -fsSL -o ") })
        #expect(!r.calls.contains { $0.hasPrefix("bash") }, "\(r.calls)")
        // The installer fails → non-zero, its temp file still removed (checked in runInstall).
        r = try await runInstall(script, failing: ["bash"])
        #expect(r.status != 0)
        // All succeed → status 0, the installer runs on the downloaded file.
        r = try await runInstall(script, failing: [])
        #expect(r.status == 0)
        #expect(r.calls.contains { $0.hasPrefix("bash /") }, "\(r.calls)")
    }

    @Test func remoteInstallIsAtomic() throws {
        let home = NSTemporaryDirectory() + "hangar-rinst-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let step = try #require(installPlan(report(remote: nil), remoteVersion: 1, optional: [.hx, .codex]).steps.last)
        let text = "#!/bin/sh\n# hangar-remote 1\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["HOME=" + home, "/bin/sh", "-c", step.command]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let path = home + "/.hangar/bin/hangar-remote"
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))
    }

    @Test func cshLoginShellUnsupported() async {
        // A csh/tcsh login shell cannot run the check: no report, then a cheap probe of $SHELL names the reason.
        for shell in ["/bin/tcsh", "/usr/bin/csh"] {
            let runner = Runner { args, _ in
                args.contains(serverCheckScript)
                    ? RunResult(status: 1, stdout: "", stderr: "Unmatched quote.")
                    : RunResult(status: 0, stdout: shell, stderr: "")
            }
            #expect(await checkServer(runner) == .failure(.unsupportedShell(shell)))
        }
        let bash = Runner { args, _ in
            args.contains(serverCheckScript)
                ? RunResult(status: 1, stdout: "", stderr: "boom")
                : RunResult(status: 0, stdout: "/bin/bash", stderr: "")
        }
        #expect(await checkServer(bash) == .failure(.exited(1, "boom")))
    }
}
