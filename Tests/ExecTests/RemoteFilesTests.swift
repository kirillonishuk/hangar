import Foundation
import Testing
@testable import Exec
import TestSupport

/// Files of «<host> · терминал» (#124): the folder hook, the per-leaf master, listing and upload scripts — run against
/// this Mac's /bin/sh through a fake ssh (never a real host).
@Suite struct RemoteFilesTests {
    /// A temp root (space and Cyrillic in the path), a fake ssh that runs the remote command locally, a fake socket.
    final class Fixture: @unchecked Sendable {
        let root: String, ssh: String, socket: String
        init() throws {
            root = "/tmp/hg rf-" + UUID().uuidString.prefix(8) + "-файлы"
            ssh = root + "/ssh"
            socket = root + "/hs-sock"
            try FileManager.default.createDirectory(atPath: root + "/srv", withIntermediateDirectories: true)
            // argv to `<root>/argv`, then the remote command word (after `--` and the host) runs in `<root>/srv`.
            try writeScript("#!/bin/sh\nR=${0%/*}\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$R/argv\"\n"
                            + "while [ $# -gt 0 ] && [ \"$1\" != -- ]; do shift; done\nshift 2\ncd \"$R/srv\" || exit 255\nexec /bin/sh -c \"$1\"\n", to: ssh)
            FileManager.default.createFile(atPath: socket, contents: nil)
        }
        var link: RemoteShellLink { RemoteShellLink(host: "box", controlPath: socket, sshPath: ssh) }
        var srv: String { root + "/srv" }
        func argv() -> [String] { ((try? String(contentsOfFile: root + "/argv", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func write(_ rel: String, _ text: String) throws {
            let url = URL(fileURLWithPath: srv + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: Spec and master

    @Test func tabIsItsOwnMasterAndBackgroundCallsNeverLogIn() throws {
        let spec = sshShellSpec(host: "box", sshPath: "/usr/bin/ssh", plan: HostShellPlan(hook: true, controlPath: "/s/hs-1", ownMaster: true))
        #expect(spec.command.contains("ControlMaster=auto") && spec.command.contains("ControlPersist=no"))
        #expect(spec.command.contains("-S /s/hs-1") && !spec.command.contains("BatchMode"))
        let link = RemoteShellLink(host: "box", controlPath: "/s/hs-1", sshPath: "/usr/bin/ssh")
        let argv = try #require(link.argv(script: "true", args: []))
        #expect(argv.starts(with: ["-S", "/s/hs-1", "-o", "ControlMaster=no", "-o", "BatchMode=yes"]))
        // Without a live master ssh must not dial the host: the fallback connection runs `false` and fails.
        #expect(argv.contains("ProxyCommand=/usr/bin/false"))
        #expect(link.exitArgv == ["-S", "/s/hs-1", "-O", "exit", "--", "box"])
        #expect(RemoteShellLink(host: "-oProxyCommand=x", controlPath: "/s", sshPath: "/usr/bin/ssh").argv(script: "true", args: []) == nil)
    }

    @Test func planFollowsTheUsersConfig() {
        let own = "/s/hs-1"
        #expect(hostShellPlan(resolved: [:], ownControlPath: own, noHook: false) == HostShellPlan(hook: true, controlPath: own, ownMaster: true))
        #expect(hostShellPlan(resolved: ["controlmaster": "false", "controlpath": "none"], ownControlPath: own, noHook: false).ownMaster)
        // ssh refuses a command line next to the config's RemoteCommand.
        #expect(hostShellPlan(resolved: ["remotecommand": "tmux a"], ownControlPath: own, noHook: false) == HostShellPlan(hook: false, controlPath: own, ownMaster: true))
        // The user's own master (2FA once per host) stays theirs; the panel uses its socket and never ends it.
        #expect(hostShellPlan(resolved: ["controlmaster": "auto", "controlpath": "/u/cm"], ownControlPath: own, noHook: false)
                == HostShellPlan(hook: true, controlPath: "/u/cm", ownMaster: false))
        #expect(hostShellPlan(resolved: ["controlmaster": "false", "controlpath": "/u/cm"], ownControlPath: own, noHook: false).controlPath == "/u/cm")
        #expect(hostShellPlan(resolved: ["controlmaster": "ask"], ownControlPath: own, noHook: false) == .plain)
        #expect(hostShellPlan(resolved: nil, ownControlPath: own, noHook: false) == .plain)
        #expect(hostShellPlan(resolved: [:], ownControlPath: nil, noHook: false) == .plain)
        #expect(hostShellPlan(resolved: [:], ownControlPath: own, noHook: true) == HostShellPlan(hook: false, controlPath: own, ownMaster: true))
        #expect(parseSSHOptions("user root\nControlPath /a b/c\nidentityfile x\nidentityfile y\n") == ["user": "root", "controlpath": "/a b/c", "identityfile": "x"])
    }

    @Test func resolvesTheConfigWithABound() throws {
        let f = try Fixture()
        try writeScript("#!/bin/sh\n[ \"$1\" = -G ] || exit 9\nprintf 'remotecommand echo hi\\ncontrolmaster false\\n'\n", to: f.root + "/ssh-g")
        #expect(sshResolvedOptions(host: "box", sshPath: f.root + "/ssh-g") == ["remotecommand": "echo hi", "controlmaster": "false"])
        try writeScript("#!/bin/sh\nexec sleep 30\n", to: f.root + "/ssh-slow")
        let start = Date()
        #expect(sshResolvedOptions(host: "box", sshPath: f.root + "/ssh-slow", timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(sshResolvedOptions(host: "-oProxyCommand=x", sshPath: f.root + "/ssh-g") == nil)
    }

    /// The login's remote command goes through the server's login shell: one line, no `!` (tcsh/csh), and a shell
    /// that can't run it (rbash) fails with its own code — not 255 — so the app falls back to a plain login.
    @Test func loginSurvivesOddLoginShells() async throws {
        #expect(!hostShellLoginScript.contains("\n") && !hostShellLoginScript.contains("!"))
        for script in [remoteListScript, remoteFileUploadScript, remoteFolderUploadScript, removeLeftoverScript] {
            #expect(!script.contains("\n") && !script.contains("!"))
        }
        let f = try Fixture()
        // The server: ssh runs the remote command with the account's login shell, `$LOGIN -c <command>`.
        try writeScript("#!/bin/sh\nwhile [ $# -gt 0 ] && [ \"$1\" != -- ]; do shift; done\nshift 2\nexec \"$LOGIN\" -c \"$1\"\n", to: f.root + "/ssh-login")
        try writeScript("#!/bin/sh\nexec /bin/bash -r \"$@\"\n", to: f.root + "/rbash")
        let spec = sshShellSpec(host: "box", sshPath: f.root + "/ssh-login", plan: HostShellPlan(hook: true, controlPath: f.socket, ownMaster: true))
        func login(_ shell: String) async throws -> RunResult {
            try await runProcess("/bin/sh", ["-c", spec.command], cwd: "/",
                                 env: ["LOGIN": shell, "SHELL": shell, "PATH": "/usr/bin:/bin", "HOME": f.srv, "TMPDIR": f.srv])
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/tcsh") {
            let tcsh = try await login("/bin/tcsh")
            #expect(tcsh.status == 0, "\(tcsh.stderr)")
        }
        let rbash = try await login(f.root + "/rbash")
        #expect(rbash.status != 0 && rbash.status != 255)
    }

    @Test func socketPerLeafFitsSunPath() {
        let a = UUID(), b = UUID()
        let short = SSHPaths(stateDir: "/tmp/st")
        #expect(short.shellControlPath(a) != short.shellControlPath(b))
        #expect(short.shellControlPath(a).hasPrefix("/tmp/st/ssh/hs-"))
        let long = SSHPaths(stateDir: "/tmp/" + String(repeating: "x", count: 90))
        #expect(long.shellControlPath(a).hasPrefix("/tmp/hangar-\(getuid())/hs-"))
        #expect(long.shellControlPath(a).utf8.count + 17 < 104)
    }

    @Test func offlineWithoutMasterRunsNothing() async throws {
        let f = try Fixture()
        var link = f.link
        link.controlPath = f.root + "/no-socket"
        await #expect(throws: RemoteFileError.offline) { try await listRemoteFolder(link, path: "/") }
        #expect(f.argv().isEmpty)
        // ssh's own 255 (the master went away meanwhile) is offline too.
        try writeScript("#!/bin/sh\nexit 255\n", to: f.root + "/ssh255")
        let dead = RemoteShellLink(host: "box", controlPath: f.socket, sshPath: f.root + "/ssh255")
        await #expect(throws: RemoteFileError.offline) { try await listRemoteFolder(dead, path: "/") }
    }

    // MARK: Folder hook

    @Test func cwdValidation() {
        #expect(validRemoteCwd("/tmp/a b/Привет") == "/tmp/a b/Привет")
        #expect(validRemoteCwd("/") == "/")
        for bad in ["", "tmp", "~/x", "/a\u{7}b", "/a\u{1b}]7;x", "/a\nb", "/a\u{85}b", "/" + String(repeating: "a", count: 4096)] {
            #expect(validRemoteCwd(bad) == nil)
        }
    }

    /// A fake login shell records how the hook script started it.
    private func started(shell name: String) async throws -> (argv: [String], env: String, files: [String: String]) {
        let f = try Fixture()
        let bin = f.root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: f.root + "/tmp", withIntermediateDirectories: true)
        try writeScript("#!/bin/sh\nR=${0%/*}/..\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$R/shell-argv\"\n"
                        + "env | grep -E '^(ZDOTDIR|HANGAR_|PROMPT_COMMAND)' | sort > \"$R/shell-env\"\n"
                        + "for x in \"$ZDOTDIR/.zshenv\" \"$2\"; do [ -f \"$x\" ] && cp \"$x\" \"$R/hook-file\"; done\nexit 0\n", to: bin + "/" + name)
        let r = try await runProcess("/bin/sh", ["-c", hostShellLoginScript], cwd: "/",
                                     env: ["SHELL": bin + "/" + name, "PATH": "/usr/bin:/bin", "TMPDIR": f.root + "/tmp", "HOME": f.srv])
        #expect(r.status == 0)
        return (f.argv(f.root + "/shell-argv"), f.read(f.root + "/shell-env") ?? "", ["hook": f.read(f.root + "/hook-file") ?? ""])
    }

    @Test func hookScriptPerShell() async throws {
        let zsh = try await started(shell: "zsh")
        #expect(zsh.argv == ["-l"])
        #expect(zsh.env.contains("ZDOTDIR=") && zsh.env.contains("HANGAR_HOOK_DIR="))
        #expect(zsh.files["hook"]?.contains("kitty-shell-cwd://localhost") == true)
        #expect(zsh.files["hook"]?.contains("add-zsh-hook precmd __hangar_cwd") == true)
        let bash = try await started(shell: "bash")
        #expect(bash.argv == ["-l"])  // a real login shell; the hook rides in PROMPT_COMMAND
        #expect(bash.env.contains("PROMPT_COMMAND=__hangar_s=$?;") && bash.env.contains("kitty-shell-cwd://localhost"))
        let fish = try await started(shell: "fish")
        #expect(fish.argv.first == "-l" && fish.argv.dropFirst().first == "-C")
        #expect(fish.argv.last?.contains("--on-event fish_prompt") == true)
        let dash = try await started(shell: "dash")
        #expect(dash.argv == ["-l"] && dash.env.isEmpty)
    }

    /// The real zsh and bash of this Mac in a pty: the prompt hook reports a folder with a space and Cyrillic, the
    /// user's own prompt command still runs, and the temporary rc is gone.
    @Test(arguments: ["/bin/zsh", "/bin/bash"]) func hookReportsTheFolder(shell: String) async throws {
        let f = try Fixture()
        let home = f.srv, tmp = f.root + "/tmp", dir = f.root + "/a b/Привет"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try f.write(".zshrc", "precmd() { printf USERHOOK; }\n")
        try f.write(".zshenv", "")
        // bash: a real login shell (logout works, .bash_logout runs); the user's rc appends to PROMPT_COMMAND.
        try f.write(".bash_profile", "PROMPT_COMMAND=\"$PROMPT_COMMAND; printf USERHOOK\"; shopt -q login_shell && printf LOGINSHELL\n")
        // Typed slowly, as a person would: input that arrives with EOF before the shell's first prompt is dropped by zsh.
        let env = ["SHELL": shell, "PATH": "/usr/bin:/bin", "TMPDIR": tmp, "HOME": home, "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                   "HANGAR_T_LOGIN": hostShellLoginScript, "HANGAR_T_DIR": dir]
        let typing = #"(sleep 1; printf "cd '%s'\nfalse\n" "$HANGAR_T_DIR"; sleep 1; printf 'exit\n'; sleep 1) | /usr/bin/script -q /dev/null /bin/sh -c "$HANGAR_T_LOGIN""#
        let run = Task { try await runProcess("/bin/sh", ["-c", typing], cwd: home, env: env) }
        let timer = Task { try await Task.sleep(nanoseconds: 60_000_000_000); run.cancel() }
        let r = try await run.value
        timer.cancel()
        #expect(r.stdout.contains("\u{1b}]7;kitty-shell-cwd://localhost\(dir)\u{7}"))
        #expect(r.stdout.contains("USERHOOK"))
        if shell.hasSuffix("bash") { #expect(r.stdout.contains("LOGINSHELL")) }
        #expect((try FileManager.default.contentsOfDirectory(atPath: tmp)).isEmpty)
    }

    // MARK: Listing

    @Test func listingParserIsStrictAndCapped() {
        func rec(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        let data = rec("fb.txt") + rec("dz") + rec("Da-link") + rec("lbroken") + rec("x?") + rec("f../x") + rec("f.") + rec("f") + rec("f.env")
        let l = parseRemoteListing(data)
        #expect(l.entries.map(\.name) == ["a-link", "z", ".env", "b.txt", "broken"])
        #expect(l.entries.map(\.kind) == [.dirLink, .dir, .file, .file, .link])
        #expect(!l.truncated)
        let capped = parseRemoteListing(rec("fa") + rec("fb") + rec("fc"), limit: 2)
        #expect(capped.entries.count == 2 && capped.truncated)
        #expect(parseRemoteListing(rec("fa") + rec("T")).truncated)
    }

    @Test func listsAFolderThroughTheMaster() async throws {
        let f = try Fixture()
        try f.write("app/config/x", "1")
        try f.write("app/.env", "S=1")
        try f.write("app/имя с пробелом.txt", "")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/app/link", withDestinationPath: f.srv + "/app/config")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/app/dead", withDestinationPath: f.srv + "/nope")
        let l = try await listRemoteFolder(f.link, path: f.srv + "/app")
        #expect(Array(l.entries.prefix(2)) == [RemoteEntry(name: "config", kind: .dir), RemoteEntry(name: "link", kind: .dirLink)])
        #expect(Set(l.entries.dropFirst(2)) == [RemoteEntry(name: ".env", kind: .file), RemoteEntry(name: "dead", kind: .link),
                                                RemoteEntry(name: "имя с пробелом.txt", kind: .file)])
        #expect(f.argv().contains("ProxyCommand=/usr/bin/false"))
        // The home (no folder reported): commands start there.
        #expect(try await listRemoteFolder(f.link, path: ".").entries.map(\.name).contains("app"))
        #expect(try await listRemoteFolder(f.link, path: f.srv + "/app", limit: 2).truncated)
        await #expect(throws: RemoteFileError.missing(f.srv + "/gone")) { try await listRemoteFolder(f.link, path: f.srv + "/gone") }
        try FileManager.default.createDirectory(atPath: f.srv + "/locked", withIntermediateDirectories: true)
        chmod(f.srv + "/locked", 0)
        defer { chmod(f.srv + "/locked", 0o755) }
        await #expect(throws: RemoteFileError.noAccess(f.srv + "/locked")) { try await listRemoteFolder(f.link, path: f.srv + "/locked") }
    }

    // MARK: Upload

    private func source(_ path: String) throws -> UploadSource { try #require(UploadSource(URL(fileURLWithPath: path))) }

    @Test func uploadsAFileWhole() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(atPath: f.root + "/mac", withIntermediateDirectories: true)
        let local = f.root + "/mac/deploy.sh"
        try Data(String(repeating: "echo hi\n", count: 100_000).utf8).write(to: URL(fileURLWithPath: local))
        chmod(local, 0o755)
        let src = try source(local)
        let sent = Counter()
        try await uploadToRemote(f.link, source: src, dir: f.srv, replace: false) { sent.set($0) }
        #expect(f.read(f.srv + "/deploy.sh") == f.read(local))
        #expect(sent.value == src.bytes)
        let mode = (try FileManager.default.attributesOfItem(atPath: f.srv + "/deploy.sh")[.posixPermissions] as? Int) ?? 0
        #expect(mode & 0o777 == 0o755)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: f.srv)).contains { $0.hasSuffix(".hangar-part") })

        // Taken: refused without «replace» (the file stays), replaced with it.
        try Data("new".utf8).write(to: URL(fileURLWithPath: local))
        await #expect(throws: RemoteFileError.exists("deploy.sh")) {
            try await uploadToRemote(f.link, source: try source(local), dir: f.srv, replace: false) { _ in }
        }
        #expect(f.read(f.srv + "/deploy.sh")?.hasPrefix("echo hi") == true)
        try await uploadToRemote(f.link, source: try source(local), dir: f.srv, replace: true) { _ in }
        #expect(f.read(f.srv + "/deploy.sh") == "new")

        // A folder of that name is never replaced by a file.
        try FileManager.default.createDirectory(atPath: f.srv + "/data", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: f.root + "/mac/data"))
        await #expect(throws: RemoteFileError.kindClash("data")) {
            try await uploadToRemote(f.link, source: try source(f.root + "/mac/data"), dir: f.srv, replace: true) { _ in }
        }
    }

    /// A stream shorter than announced (cancel, lost connection): nothing under the real name, no temp left.
    @Test func cutStreamLeavesNothing() async throws {
        let f = try Fixture()
        let r = try await runProcess("/bin/sh", ["-c", remoteFileUploadScript, "sh", f.srv, "big.bin", "644", "0", "1000"], cwd: "/",
                                     env: ["PATH": "/usr/bin:/bin"], input: Data(repeating: 7, count: 10))
        #expect(r.status == 14)
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.srv)).isEmpty)
        #expect(uploadError(status: 14, stderr: "", name: "big.bin", dir: f.srv) == .incomplete("big.bin"))
        #expect(uploadError(status: 13, stderr: "sh: .x.hangar-part: Permission denied", name: "x", dir: "/etc") == .noAccess("/etc"))
    }

    @Test func uploadsAFolderAndMerges() async throws {
        let f = try Fixture()
        let mac = f.root + "/mac/site"
        try FileManager.default.createDirectory(atPath: mac + "/css", withIntermediateDirectories: true)
        try Data("<h1>new</h1>".utf8).write(to: URL(fileURLWithPath: mac + "/index.html"))
        try Data("a{}".utf8).write(to: URL(fileURLWithPath: mac + "/css/a.css"))
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: false) { _ in }
        #expect(f.read(f.srv + "/site/css/a.css") == "a{}")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: f.srv + "/site")).contains("._index.html"))

        // Taken: refused without «merge»; merged with it — same names replaced, the server's own files kept.
        try f.write("site/index.html", "<h1>old</h1>")
        try f.write("site/keep.txt", "mine")
        await #expect(throws: RemoteFileError.exists("site")) {
            try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: false) { _ in }
        }
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: true) { _ in }
        #expect(f.read(f.srv + "/site/index.html") == "<h1>new</h1>")
        #expect(f.read(f.srv + "/site/keep.txt") == "mine")
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.srv)) == ["site"])
    }

    @Test func leftoverOfACancelledUploadGoes() async throws {
        let f = try Fixture()
        try f.write(".big.bin.hangar-part", "half")
        try f.write("big.bin", "the old one")
        await removeUploadLeftover(f.link, dir: f.srv, name: "big.bin")
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.srv)) == ["big.bin"])
    }

    /// Replace never goes through a link: a link to a folder is a clash (GNU mv would drop the file inside it), a link
    /// to a file is replaced itself — its target stays.
    @Test func replaceNeverFollowsALink() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(atPath: f.root + "/mac", withIntermediateDirectories: true)
        try f.write("real/keep.txt", "keep")
        try f.write("target.txt", "target")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/data", withDestinationPath: f.srv + "/real")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/note.txt", withDestinationPath: f.srv + "/target.txt")
        try Data("x".utf8).write(to: URL(fileURLWithPath: f.root + "/mac/data"))
        try Data("new".utf8).write(to: URL(fileURLWithPath: f.root + "/mac/note.txt"))
        await #expect(throws: RemoteFileError.kindClash("data")) {
            try await uploadToRemote(f.link, source: try source(f.root + "/mac/data"), dir: f.srv, replace: true) { _ in }
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.srv + "/real")) == ["keep.txt"])
        try await uploadToRemote(f.link, source: try source(f.root + "/mac/note.txt"), dir: f.srv, replace: true) { _ in }
        #expect(f.read(f.srv + "/target.txt") == "target" && f.read(f.srv + "/note.txt") == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.srv + "/note.txt")) == nil)
    }

    /// «Заменить» keeps the server file's mode (a 0600 .env stays 0600); a new file gets the local mode under the
    /// server's umask, never wider.
    @Test func replaceKeepsModeNewFileHonoursUmask() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(atPath: f.root + "/mac", withIntermediateDirectories: true)
        try f.write(".env", "S=1")
        chmod(f.srv + "/.env", 0o600)
        try Data("S=2".utf8).write(to: URL(fileURLWithPath: f.root + "/mac/.env"))
        chmod(f.root + "/mac/.env", 0o644)
        try await uploadToRemote(f.link, source: try source(f.root + "/mac/.env"), dir: f.srv, replace: true) { _ in }
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions]) as? Int ?? 0) & 0o777 }
        #expect(f.read(f.srv + "/.env") == "S=2" && mode(f.srv + "/.env") == 0o600)
        try Data("w".utf8).write(to: URL(fileURLWithPath: f.root + "/mac/open.txt"))
        chmod(f.root + "/mac/open.txt", 0o666)
        try await uploadToRemote(f.link, source: try source(f.root + "/mac/open.txt"), dir: f.srv, replace: false) { _ in }
        let mask = umask(0); umask(mask)
        #expect(mode(f.srv + "/open.txt") == 0o666 & ~Int(mask))
    }

    /// «Объединить» copies into the existing folder: its own mode stays, the server's files stay, same names are
    /// overwritten in place.
    @Test func mergeLeavesExistingFoldersAlone() async throws {
        let f = try Fixture()
        let mac = f.root + "/mac/site"
        try FileManager.default.createDirectory(atPath: mac + "/private", withIntermediateDirectories: true)
        try Data("new".utf8).write(to: URL(fileURLWithPath: mac + "/private/a.txt"))
        try f.write("site/private/a.txt", "old")
        try f.write("site/private/mine.txt", "mine")
        chmod(f.srv + "/site/private", 0o700)
        chmod(f.srv + "/site/private/a.txt", 0o600)
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: true) { _ in }
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions]) as? Int ?? 0) & 0o777 }
        #expect(mode(f.srv + "/site/private") == 0o700 && mode(f.srv + "/site/private/a.txt") == 0o600)
        #expect(f.read(f.srv + "/site/private/a.txt") == "new" && f.read(f.srv + "/site/private/mine.txt") == "mine")
    }

    /// «Объединить» never writes through a link inside the server's folder: a link where the upload has a file is
    /// replaced (its target stays), a link where it has a folder is a clash and nothing is copied.
    @Test func mergeNeverWritesThroughLinks() async throws {
        let f = try Fixture()
        let mac = f.root + "/mac/app"
        try FileManager.default.createDirectory(atPath: mac, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: URL(fileURLWithPath: mac + "/config.yml"))
        try f.write("app/keep.txt", "keep")
        try f.write("outside/config.yml", "shared")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/app/config.yml", withDestinationPath: f.srv + "/outside/config.yml")
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: true) { _ in }
        #expect(f.read(f.srv + "/outside/config.yml") == "shared" && f.read(f.srv + "/app/config.yml") == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.srv + "/app/config.yml")) == nil)

        try FileManager.default.createDirectory(atPath: mac + "/shared", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: mac + "/shared/x.txt"))
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/app/shared", withDestinationPath: f.srv + "/outside")
        await #expect(throws: RemoteFileError.kindClash("app")) {
            try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: true) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: f.srv + "/outside/x.txt"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.srv)).filter { $0.hasSuffix(".hangar-part") }.isEmpty)
    }

    /// A newline in a file name does not break the folder's file count.
    @Test func newlineInANameStillCounts() async throws {
        let f = try Fixture()
        let mac = f.root + "/mac/notes"
        try FileManager.default.createDirectory(atPath: mac, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: URL(fileURLWithPath: mac + "/two\nlines.txt"))
        try Data("2".utf8).write(to: URL(fileURLWithPath: mac + "/plain.txt"))
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: false) { _ in }
        #expect(f.read(f.srv + "/notes/two\nlines.txt") == "1" && f.read(f.srv + "/notes/plain.txt") == "2")
    }

    @Test func namesThatLookLikeOptions() async throws {
        let f = try Fixture()
        let mac = f.root + "/mac/-rf"
        try FileManager.default.createDirectory(atPath: mac, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: mac + "/-x.txt"))
        try await uploadToRemote(f.link, source: try source(mac), dir: f.srv, replace: false) { _ in }
        try await uploadToRemote(f.link, source: try source(mac + "/-x.txt"), dir: f.srv, replace: false) { _ in }
        #expect(f.read(f.srv + "/-rf/-x.txt") == "x" && f.read(f.srv + "/-x.txt") == "x")
    }

    /// A link planted under the temp name (a shared folder where it can't be removed) is never written through.
    @Test func plantedTempLinkIsNotFollowed() async throws {
        let f = try Fixture()
        let bin = f.root + "/norm"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try writeScript("#!/bin/sh\nexit 0\n", to: bin + "/rm")  // as in a sticky folder: the link stays
        try f.write("victim.txt", "safe")
        try FileManager.default.createSymbolicLink(atPath: f.srv + "/.a.txt.hangar-part", withDestinationPath: f.srv + "/victim.txt")
        let r = try await runProcess("/bin/sh", ["-c", remoteFileUploadScript, "sh", f.srv, "a.txt", "644", "0", "4"], cwd: "/",
                                     env: ["PATH": bin + ":/usr/bin:/bin"], input: Data("evil".utf8))
        #expect(r.status == 13)
        #expect(f.read(f.srv + "/victim.txt") == "safe")
    }

    @Test func longNamesAreRefused() throws {
        let f = try Fixture()
        let ok = f.root + "/" + String(repeating: "a", count: uploadNameLimit)
        let long = f.root + "/" + String(repeating: "a", count: uploadNameLimit + 1)
        for p in [ok, long] { FileManager.default.createFile(atPath: p, contents: Data("x".utf8)) }
        #expect(UploadSource(URL(fileURLWithPath: ok)) != nil)
        #expect(UploadSource(URL(fileURLWithPath: long)) == nil)
        #expect(uploadNameLimit == 242)
    }

    @Test func folderUploadNeedsTar() async throws {
        let f = try Fixture()
        let empty = f.root + "/empty-bin"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let r = try await runProcess("/bin/sh", ["-c", remoteFolderUploadScript, "sh", f.srv, "site", "0", "1"], cwd: "/", env: ["PATH": empty])
        #expect(r.status == 12)
        #expect(uploadError(status: 12, stderr: "", name: "site", dir: f.srv) == .noTar)
    }

    @Test func uploadNames() {
        #expect(validUploadName("отчёт 2026.pdf") != nil)
        for bad in ["", ".", "..", "a/b", "a\nb", String(repeating: "x", count: 256)] { #expect(validUploadName(bad) == nil) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64 = 0
    func set(_ n: Int64) { lock.lock(); v = n; lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
}

private extension RemoteFilesTests.Fixture {
    func argv(_ path: String) -> [String] { (read(path) ?? "").split(separator: "\n").map(String.init) }
}
