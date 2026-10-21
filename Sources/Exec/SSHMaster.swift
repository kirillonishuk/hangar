import Foundation

public enum SSHFailure: Error, Equatable, Sendable {
    case auth(String), unreachable(String), exited(Int32, String)
}

/// Classifies a failed ssh by its stderr; the message is the last non-empty stderr line, at most 300 characters.
func sshFailure(status: Int32, stderr: String) -> SSHFailure {
    let last = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    let line = String(last.prefix(300))
    let has = { (s: String) in stderr.contains(s) }
    if has("Permission denied") || has("Host key verification failed") || has("passphrase") { return .auth(line) }
    if has("Could not resolve") || has("Connection refused") || has("timed out") || has("No route") { return .unreachable(line) }
    return .exited(status, line)
}

/// `<home>` of a `HANGAR-READY <home>` line, only if it is an absolute path without control characters, ≤ 1024 bytes:
/// it comes from the server and later goes into ssh arguments and the session environment.
func readyHome(_ line: Substring) -> String? {
    let prefix = "HANGAR-READY "
    guard line.hasPrefix(prefix) else { return nil }
    let home = String(line.dropFirst(prefix.count))
    guard home.hasPrefix("/"), home.utf8.count <= 1024,
          !home.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0.properties.generalCategory == .control })
    else { return nil }
    return home
}

/// The control master of one host: a child process of the app (#47). Ready = the marker on stdout, lost = the process
/// exited; no polling. shortcut: a `connect`/`exit` racing a dying master on the same control path is not serialized
/// (the new master needs a network round trip before it binds); serialize if reconnects ever become instant.
public final class SSHMaster: @unchecked Sendable {
    public let host: String, controlPath: String, sshPath: String
    private let lock = NSLock()
    private var exitHandler: (@Sendable (SSHFailure) -> Void)?
    private var current: MasterProcess?

    public init(host: String, controlPath: String, sshPath: String = "/usr/bin/ssh") {
        self.host = host; self.controlPath = controlPath; self.sshPath = sshPath
    }

    /// Called once when an established master exits on its own (not after `exit()`).
    public var onExit: (@Sendable (SSHFailure) -> Void)? {
        get { lock.withLock { exitHandler } }
        set { lock.withLock { exitHandler = newValue } }
    }

    /// Starts the master; success is the server's `$HOME`. Timeout kills it and reports `.unreachable("timed out")`.
    public func connect(timeout: Double = 30) async -> Result<String, SSHFailure> {
        guard let host = validSSHHost(host) else { return .failure(.exited(255, "invalid host")) }
        lock.withLock { current }?.stop(sendExit: false)
        unlink(controlPath)  // ssh -M with an existing socket silently runs without a master
        let script = #"printf 'HANGAR-READY %s\n' "$HOME"; exec cat >/dev/null"#
        let args = ["-M", "-T", "-S", controlPath, "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                    "--", host, remoteShellArgs(script: script, [])]
        let p = MasterProcess(sshPath: sshPath, args: args, host: host, controlPath: controlPath)
        lock.withLock { current = p }
        return await p.start(timeout: timeout) { [weak self] failure in self?.onExit?(failure) }
    }

    /// Links `remote` (a socket path on the server) to the local socket through the master; true = forwarded.
    public func forward(remote: String, local: String) async -> Bool {
        guard let host = validSSHHost(host), !remote.contains(":"), !local.contains(":") else { return false }
        let runner = Runner.ssh(host: host, controlPath: controlPath, sshPath: sshPath)
        // sshd's StreamLocalBindUnlink defaults to no: a stale socket file would make -R fail.
        let prep = try? await runner.run(["sh", "-c", #"mkdir -p -m 700 "$HOME/.hangar/run" && rm -f "$1""#, "sh", remote], "")
        guard prep?.status == 0 else { return false }
        let argv = ["-S", controlPath, "-O", "forward", "-R", remote + ":" + local, "--", host]
        return (try? await runProcess(sshPath, argv, cwd: "/", env: ProcessInfo.processInfo.environment))?.status == 0
    }

    /// One `true` through the master (after wake); false on a non-zero exit or after `timeout` (the ssh is killed).
    public func probe(timeout: Double) async -> Bool {
        let runner = Runner.ssh(host: host, controlPath: controlPath, sshPath: sshPath)
        let run = Task { (try? await runner.run(["true"], ""))?.status == 0 }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            run.cancel()
        }
        let ok = await run.value
        timer.cancel()
        return ok
    }

    /// App quit or host removed: `-O exit` (fire-and-forget), close the master's stdin, terminate it; no `onExit`.
    public func exit() {
        lock.withLock { current }?.stop(sendExit: true)
    }
}

/// One master process. Resolves `start` exactly once; reports a loss only after it was ready and not stopped.
private final class MasterProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let host: String, controlPath: String, sshPath: String
    private let lock = NSLock()
    private var cont: CheckedContinuation<Result<String, SSHFailure>, Never>?
    private var onLost: (@Sendable (SSHFailure) -> Void)?
    private var out = Data(), err = Data()
    private var ready = false, stopped = false, stdinClosed = false
    private var pid: pid_t = 0, ownGroup = false
    private let outEOF = DispatchSemaphore(value: 0), errEOF = DispatchSemaphore(value: 0)

    init(sshPath: String, args: [String], host: String, controlPath: String) {
        self.host = host; self.controlPath = controlPath; self.sshPath = sshPath
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Children spawned meanwhile elsewhere in the app must not inherit these ends: a stray copy of a write end
        // would hold EOF (and the remote `cat`) open for as long as that child lives.
        for p in [stdin, stdout, stderr] {
            for h in [p.fileHandleForReading, p.fileHandleForWriting] { _ = fcntl(h.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        }
    }

    func start(timeout: Double, onLost: @escaping @Sendable (SSHFailure) -> Void) async -> Result<String, SSHFailure> {
        await withCheckedContinuation { c in
            lock.withLock { cont = c; self.onLost = onLost }
            process.terminationHandler = { [self] p in exited(p.terminationStatus) }
            do {
                try process.run()
            } catch {
                close()
                resolve(.failure(.exited(-1, error.localizedDescription)))
                return
            }
            // `exit()` may have run before the pid was known.
            let (stoppedEarly, group) = lock.withLock { () -> (Bool, Bool) in
                pid = process.processIdentifier; ownGroup = getpgid(pid) == pid
                return (stopped, ownGroup)
            }
            if stoppedEarly { terminateProcess(process.processIdentifier, group: group) }
            stdout.fileHandleForReading.readabilityHandler = { [self] h in readOut(h.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { [self] h in readErr(h.availableData) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                if resolve(.failure(.unreachable("timed out"))) { stop(sendExit: false) }
            }
        }
    }

    func stop(sendExit: Bool) {
        let (target, group, already) = lock.withLock { () -> (pid_t, Bool, Bool) in
            defer { stopped = true }
            return (self.pid, ownGroup, stopped)
        }
        guard !already else { return }
        if sendExit {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sshPath)
            p.arguments = ["-S", controlPath, "-O", "exit", "--", host]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        closeStdin()
        if target > 0 && process.isRunning { terminateProcess(target, group: group) }
    }

    /// Lines before the marker (rc-file noise) are skipped; an over-long unterminated line is dropped.
    private func readOut(_ data: Data) {
        if data.isEmpty {
            endOfFile(stdout.fileHandleForReading)
            outEOF.signal()
            return
        }
        var result: Result<String, SSHFailure>?
        lock.withLock {
            guard !ready, cont != nil else { return }
            out.append(data)
            while result == nil, let nl = out.firstIndex(of: 10) {
                let line = String(decoding: out[out.startIndex..<nl], as: UTF8.self)
                out.removeSubrange(out.startIndex...nl)
                guard line.hasPrefix("HANGAR-READY ") else { continue }
                if let home = readyHome(Substring(line)) { ready = true; result = .success(home) }
                else { result = .failure(.exited(-1, "invalid HANGAR-READY line")) }
            }
            if out.count > 4096 { out.removeAll() }
        }
        guard let result else { return }
        resolve(result)
        if case .failure = result { stop(sendExit: false) }
    }

    private func readErr(_ data: Data) {
        if data.isEmpty {
            endOfFile(stderr.fileHandleForReading)
            errEOF.signal()
            return
        }
        lock.withLock {
            err.append(data)
            if err.count > 8192 { err.removeSubrange(err.startIndex..<(err.endIndex - 4096)) }
        }
    }

    private func exited(_ status: Int32) {
        // The last stderr/stdout bytes may still be in flight; a helper holding the pipes open must not block us.
        let deadline = DispatchTime.now() + 1
        _ = errEOF.wait(timeout: deadline)
        _ = outEOF.wait(timeout: deadline)
        close()
        let (failure, lost) = lock.withLock { () -> (SSHFailure, (@Sendable (SSHFailure) -> Void)?) in
            let f = sshFailure(status: status, stderr: String(decoding: err, as: UTF8.self))
            let l = ready && !stopped ? onLost : nil
            onLost = nil
            return (f, l)
        }
        resolve(.failure(failure))
        lost?(failure)
    }

    /// Runs inside the handle's own readability handler, so nothing else reads it while it closes.
    private func endOfFile(_ h: FileHandle) {
        h.readabilityHandler = nil
        try? h.close()
    }

    /// Stops reading and closes stdin. A read end without EOF (a helper still holds the pipe) is not closed here:
    /// closing under a running handler would raise; Pipe closes it on dealloc.
    private func close() {
        process.terminationHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        closeStdin()
    }

    private func closeStdin() {
        guard lock.withLock({ defer { stdinClosed = true }; return !stdinClosed }) else { return }
        try? stdin.fileHandleForWriting.close()
    }

    @discardableResult
    private func resolve(_ r: Result<String, SSHFailure>) -> Bool {
        guard let c = lock.withLock({ defer { cont = nil }; return cont }) else { return false }
        c.resume(returning: r)
        return true
    }
}
