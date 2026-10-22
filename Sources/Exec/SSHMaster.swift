import Foundation

public enum SSHFailure: Error, Equatable, Sendable {
    case auth(String), unreachable(String), exited(Int32, String)
    /// The login shell (path) is csh/tcsh: not supported in stage 6 (#47).
    case unsupportedShell(String)
}

/// Classifies a failed ssh by ssh's own diagnostic lines (whole lines, not substrings: a banner or rc file may say
/// "Permission denied"); the message is the last non-empty stderr line, at most 300 characters.
func sshFailure(status: Int32, stderr: String) -> SSHFailure {
    let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let line = String((lines.last ?? "").prefix(300))
    let auth = lines.contains { l in
        l.hasPrefix("Permission denied (") || l.contains(": Permission denied (") || l.hasPrefix("Host key verification failed")
            || ((l.hasPrefix("Load key") || l.hasPrefix("Enter passphrase")) && l.contains("passphrase"))
    }
    if auth { return .auth(line) }
    let network = lines.contains { l in
        (l.hasPrefix("ssh:") && ["Could not resolve", "Connection refused", "timed out", "No route"].contains { l.contains($0) })
            || l.hasPrefix("client_loop:") || l.hasPrefix("Timeout, server") || l.hasPrefix("Connection timed out")
    }
    return network ? .unreachable(line) : .exited(status, line)
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
/// exited; no polling. `connect()` right after `exit()` first waits for that `-O exit` (≤ 3 s): run later, it would
/// stop the new master on the same socket.
public final class SSHMaster: @unchecked Sendable {
    public let host: String, controlPath: String, sshPath: String
    private let lock = NSLock()
    private var exitHandler: (@Sendable (SSHFailure) -> Void)?
    private var current: MasterProcess?
    /// Bumped by `exit()`: a `connect` that started earlier must not start its child.
    private var exits = 0

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
        let (epoch, old) = lock.withLock { (exits, current) }
        // The old master unlinks its socket when it dies; it must not take the new one with it.
        await old?.stopAndWait(seconds: 3)
        unlink(controlPath)  // ssh -M with an existing socket silently runs without a master
        let script = #"printf 'HANGAR-READY %s\n' "$HOME"; exec cat >/dev/null"#
        let args = ["-M", "-T", "-S", controlPath, "-o", "ControlPersist=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                    "--", host, remoteShellArgs(script: script, [])]
        let p = MasterProcess(sshPath: sshPath, args: args, host: host, controlPath: controlPath)
        let stopped = lock.withLock { () -> Bool in
            guard exits == epoch else { return true }
            current = p
            return false
        }
        if stopped { return .failure(.exited(-1, "stopped")) }
        return await p.start(timeout: timeout) { [weak self] failure in self?.onExit?(failure) }
    }

    /// Links `remote` (a socket path on the server) to the local socket through the master; true = forwarded.
    public func forward(remote: String, local: String) async -> Bool {
        guard let host = validSSHHost(host), !remote.contains(":"), !local.contains(":") else { return false }
        let runner = Runner.ssh(host: host, controlPath: controlPath, sshPath: sshPath)
        let (cp, ssh) = (controlPath, sshPath)
        return await withTimeout(10) {
            // sshd's StreamLocalBindUnlink defaults to no: a stale socket file would make -R fail.
            let prep = try? await runner.run(["sh", "-c", #"mkdir -p -m 700 "$HOME/.hangar/run" && rm -f "$1""#, "sh", remote], "")
            guard prep?.status == 0 else { return false }
            let argv = ["-S", cp, "-O", "forward", "-R", remote + ":" + local, "--", host]
            return (try? await runProcess(ssh, argv, cwd: "/", env: ProcessInfo.processInfo.environment))?.status == 0
        }
    }

    /// One `true` through the master (after wake); false on a non-zero exit or after `timeout` (the ssh is killed).
    public func probe(timeout: Double) async -> Bool {
        let runner = Runner.ssh(host: host, controlPath: controlPath, sshPath: sshPath)
        return await withTimeout(timeout) { (try? await runner.run(["true"], ""))?.status == 0 }
    }

    /// App quit or host removed: `-O exit` (fire-and-forget), close the master's stdin, terminate it; no `onExit`.
    public func exit() {
        lock.withLock { () -> MasterProcess? in exits += 1; return current }?.stop(sendExit: true)
    }
}

/// Runs `op`, cancelling it after `seconds` (cancel kills its ssh); a cancelled `op` is expected to return false.
private func withTimeout(_ seconds: Double, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
    let run = Task { await op() }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        run.cancel()
    }
    let ok = await run.value
    timer.cancel()
    return ok
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
    private var ready = false, stopped = false, stdinClosed = false, gone = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var pid: pid_t = 0, ownGroup = false
    /// The `-O exit` helper, if one was started.
    private let exitHelper = DispatchGroup()
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
                finishWaiters()
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
            exitHelper.enter()
            p.terminationHandler = { [exitHelper] _ in exitHelper.leave() }
            do { try p.run() } catch { exitHelper.leave() }
        }
        closeStdin()
        if target > 0 && process.isRunning { terminateProcess(target, group: group) }
    }

    /// Stops without `-O exit` and returns once the process (and an earlier `-O exit` helper) is gone; after `seconds`
    /// it is SIGKILLed and not waited for.
    func stopAndWait(seconds: Double) async {
        stop(sendExit: false)
        let helper = exitHelper
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { _ = helper.wait(timeout: .now() + seconds); c.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if gone || pid == 0 { return true }
                exitWaiters.append(c)
                return false
            }
            if done { c.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                let (target, group) = lock.withLock { (pid, ownGroup) }
                if process.isRunning { kill(group ? -target : target, SIGKILL) }
                finishWaiters()
            }
        }
    }

    private func finishWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { gone = true; exitWaiters = [] }
            return exitWaiters
        }
        waiters.forEach { $0.resume() }
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
                // Pre-ready stderr (banner, rc noise) must not classify a later drop.
                if let home = readyHome(Substring(line)) { ready = true; err.removeAll(); result = .success(home) }
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
        finishWaiters()
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
