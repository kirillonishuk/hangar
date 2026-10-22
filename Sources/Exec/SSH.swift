import Foundation

public enum SSHError: Error, Equatable, Sendable {
    case invalidHost(String)
    /// A socket directory that is not a private directory of this user (e.g. pre-created by someone else in /tmp).
    case unsafeDirectory(String)
}

/// The host if it is safe to put on an ssh command line, else nil: 1…255 bytes, no leading `-` or `@-` (an option),
/// no whitespace, control characters or shell metacharacters (ssh may hand it to a shell via ProxyCommand `%h`).
public func validSSHHost(_ s: String) -> String? {
    let banned = Set("'\"\\`$;&|<>()")
    guard (1...255).contains(s.utf8.count), !s.hasPrefix("-"), !s.contains("@-") else { return nil }
    for u in s.unicodeScalars {
        if u.properties.isWhitespace || u.value < 0x20 || u.value == 0x7f || u.properties.generalCategory == .control { return nil }
        if banned.contains(Character(u)) { return nil }
    }
    return s
}

/// Where master and host sockets live: `<stateDir>/ssh/`, or `/tmp/hangar-<uid>/` when that would not fit
/// the 104-byte `sun_path` (NUL included) together with the 17-byte suffix ssh appends while creating the master (#47).
public struct SSHPaths: Sendable, Equatable {
    public var stateDir: String

    public init(stateDir: String) { self.stateDir = stateDir }

    public var dir: String {
        let d = stateDir + "/ssh"
        return d.utf8.count + "/cm-".utf8.count + 16 + 17 < 104 ? d : "/tmp/hangar-\(getuid())"
    }

    public func controlPath(_ host: String) -> String { dir + "/cm-" + fnv1a64Hex(host) }
    public func hostSocket(_ host: String) -> String { dir + "/r-" + fnv1a64Hex(host) + ".sock" }

    /// Creates the directory 0700 and checks it is a real directory owned by this user.
    public func prepare() throws {
        let d = dir
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(d, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), chmod(d, 0o700) == 0 else {
            throw SSHError.unsafeDirectory(d)
        }
    }
}

/// FNV-1a 64 of the UTF-8 bytes, 16 lowercase hex digits: a short fixed-length socket name for any host.
func fnv1a64Hex(_ s: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    let hex = String(h, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}

/// Options of every non-terminal ssh call except the master itself; the caller appends `--` and the host.
/// ConnectTimeout: with the master down ssh connects directly, and a dead host must fail fast.
public func sshBaseArgs(controlPath: String) -> [String] {
    ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
}

/// The remote command line: the login shell (maybe fish) only parses quoted words; the script reads its arguments
/// as positional parameters, so nothing from `args` is ever spliced into code.
public func remoteShellArgs(script: String, _ args: [String]) -> String {
    (["/bin/sh", "-c", shellQuote(script), "sh"] + args.map(shellQuote)).joined(separator: " ")
}

/// `$1` = PATH (empty = sshd's own), `$2` = cwd (empty = remote $HOME), the rest = argv. No prompts: git must fail
/// rather than wait for a password.
let remoteRunScript = #"[ -z "$1" ] || { PATH=$1; export PATH; }; shift; cd "${1:-$HOME}" && shift && exec env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" "$@""#

extension Runner {
    /// Runs argv on `host` through the master at `controlPath`; a failed login is status 255 with ssh's stderr.
    /// Cancel kills the local ssh. shortcut: the remote command may outlive a cancel; ok for short git calls.
    /// `maxOutput`: past that many bytes on a stream the ssh is killed and the stream cut (untrusted server output).
    /// `path`: the login shell's PATH from the server check (#47); nil = the non-login PATH sshd gives.
    public static func ssh(host: String, controlPath: String, sshPath: String = "/usr/bin/ssh", maxOutput: Int = .max,
                           path: String? = nil) -> Runner {
        Runner { args, cwd in
            try await runSSH(host: host, controlPath: controlPath, sshPath: sshPath, script: remoteRunScript, args: [path ?? "", cwd] + args,
                             input: nil, maxOutput: maxOutput)
        }
    }
}

/// Runs `/bin/sh -c script sh args…` on `host` with `input` as stdin (writing `hangar-remote` and integration files).
public func sshWrite(host: String, controlPath: String, sshPath: String = "/usr/bin/ssh",
                     script: String, args: [String], input: Data) async throws -> RunResult {
    try await runSSH(host: host, controlPath: controlPath, sshPath: sshPath, script: script, args: args, input: input)
}

private func runSSH(host: String, controlPath: String, sshPath: String,
                    script: String, args: [String], input: Data?, maxOutput: Int = .max) async throws -> RunResult {
    guard let host = validSSHHost(host) else { throw SSHError.invalidHost(host) }
    let argv = sshBaseArgs(controlPath: controlPath) + ["-T", "--", host, remoteShellArgs(script: script, args)]
    return try await runProcess(sshPath, argv, cwd: "/", env: ProcessInfo.processInfo.environment, input: input, maxOutput: maxOutput)
}

/// A connected host, as terminal launches need it (built by RemoteHosts from the master and the server check).
public struct RemoteTarget: Equatable, Sendable {
    public var host: String, controlPath: String, home: String
    public var tmux: Bool
    public var sshPath: String

    public init(host: String, controlPath: String, home: String, tmux: Bool, sshPath: String) {
        self.host = host; self.controlPath = controlPath; self.home = home; self.tmux = tmux; self.sshPath = sshPath
    }
}

/// `test -d` through the runner (local or remote); a runner that can't run (host not connected) throws.
public func directoryExists(_ path: String, runner: Runner) async throws -> Bool {
    try await runner.run(["test", "-d", path], "/").status == 0
}
