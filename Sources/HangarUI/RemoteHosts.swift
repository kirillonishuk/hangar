import ControlServer
import Exec
import Foundation
import Observation
import Power

public enum HostState: Equatable, Sendable {
    case disconnected, connecting, connected
    case reconnecting(attempt: Int)
    case unreachable(String)
}

public struct HostInfo: Equatable {
    public var state: HostState = .disconnected
    public var home: String?
    public var report: ServerReport?
    /// The host socket is forwarded to the server: agent statuses and limits arrive.
    public var forwarding = false
    public var authFailed = false

    /// Something on the server is missing or stale (sidebar warning, #47).
    public var needsAttention: Bool {
        guard state == .connected, let r = report else { return false }
        return !r.missingRequired.isEmpty || r.remoteOutdated(current: hangarRemoteVersion) || r.socketClient == nil || !forwarding
    }
}

public enum RemoteHostError: Error, Equatable, CustomStringConvertible {
    case notConnected(String)
    public var description: String {
        switch self { case let .notConnected(h): "host \(h) is not connected" }
    }
}

/// Every ssh host: its master, the events-only host socket and bounded reconnect (#47). No timers while idle:
/// a retry is scheduled only while the app is active or the host had working agents.
@MainActor @Observable public final class RemoteHosts {
    public private(set) var hosts: [String: HostInfo] = [:]
    @ObservationIgnored public var onConnected: ((String) -> Void)?
    /// The master dropped; statuses are kept (the caller decides nothing else yet).
    @ObservationIgnored public var onLost: ((String) -> Void)?
    /// Reconnect gave up or was refused (auth, unsupported shell): the host's leaves are no longer running anything we see.
    @ObservationIgnored public var onUnreachable: ((String) -> Void)?

    /// Test seams.
    @ObservationIgnored var checkTimeout: Double = 30
    @ObservationIgnored var probeTimeout: Double = 10
    static let maxAttempts = 10
    /// The check prints ~1 KB; a flood from the server is cut here.
    static let maxCheckOutput = 262_144

    @ObservationIgnored private let paths: SSHPaths
    @ObservationIgnored private let sshPath: String
    @ObservationIgnored private let schedule: (Duration, @escaping @MainActor () -> Void) -> (() -> Void)
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private let hasWorking: (String) -> Bool
    @ObservationIgnored private let onMessage: (String, ControlMessage) -> Void
    @ObservationIgnored private var links: [String: Link] = [:]

    private final class Link {
        let master: SSHMaster
        var server: ControlServer?
        var inFlight: Task<Void, Never>?
        var cancelTimer: (() -> Void)?
        /// Attempts made since the loss; > 0 (or `waiting`) means failures go on with the backoff.
        var attempts = 0
        var reconnecting = false
        /// Lost while inactive and idle: the next attempt waits for `appBecameActive`.
        var waiting = false
        /// The master exited while an attempt was still running.
        var died = false
        /// Bumped by disconnect / stopAll: a running attempt must not resurrect the host.
        var generation = 0
        init(master: SSHMaster) { self.master = master }
    }

    public init(paths: SSHPaths, sshPath: String,
                schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = KeepAwake.taskSchedule,
                isActive: @escaping () -> Bool, hasWorking: @escaping (String) -> Bool,
                onMessage: @escaping (String, ControlMessage) -> Void) {
        self.paths = paths; self.sshPath = sshPath; self.schedule = schedule
        self.isActive = isActive; self.hasWorking = hasWorking; self.onMessage = onMessage
    }

    /// User or launch: a fresh attempt (pending backoff dropped). A call during an attempt waits for that attempt.
    @discardableResult public func connect(_ host: String) async -> HostState {
        let link = self.link(host)
        if let t = link.inFlight { await t.value; return state(host) }
        if state(host) == .connected { return .connected }
        link.cancelTimer?(); link.cancelTimer = nil
        link.attempts = 0; link.reconnecting = false; link.waiting = false
        set(host) { $0.state = .connecting; $0.authFailed = false }
        await attempt(host)
        return state(host)
    }

    /// «Проверить сервер»: the check again over the live master.
    public func recheck(_ host: String) async {
        guard state(host) == .connected, let link = links[host] else { return }
        if case let .success(r) = await check(host, link.master) { set(host) { $0.report = r } }
    }

    /// Commands on the host; while it is not connected they fail at once instead of dialing ssh directly.
    public func runner(_ host: String) -> Runner {
        let ssh = Runner.ssh(host: host, controlPath: paths.controlPath(host), sshPath: sshPath)
        return Runner { [weak self] args, cwd in
            guard await self?.state(host) == .connected else { throw RemoteHostError.notConnected(host) }
            return try await ssh.run(args, cwd)
        }
    }

    public func target(_ host: String) -> RemoteTarget? {
        guard let info = hosts[host], info.state == .connected, let home = info.home else { return nil }
        return RemoteTarget(host: host, controlPath: paths.controlPath(host), home: home, tmux: info.report?.tmux ?? false, sshPath: sshPath)
    }

    /// User action: `-O exit`, no reconnect.
    public func disconnect(_ host: String) {
        guard let link = links[host] else { return }
        close(link, host)
        set(host) { $0.state = .disconnected }
    }

    /// A host paused for activation gets its next attempt now.
    public func appBecameActive() {
        for (host, link) in links where link.waiting && link.inFlight == nil {
            link.waiting = false
            link.attempts += 1
            set(host) { $0.state = .reconnecting(attempt: link.attempts) }
            Task { await attempt(host) }
        }
    }

    /// After sleep a master may look alive but be dead: one probe per connected host.
    public func didWake() {
        for (host, link) in links where state(host) == .connected {
            let gen = link.generation, master = link.master, timeout = probeTimeout
            Task {
                guard await !master.probe(timeout: timeout), link.generation == gen, state(host) == .connected else { return }
                master.exit()
                lost(host, .unreachable("no response after wake"))
            }
        }
    }

    /// App quit: every master gets `-O exit`, host sockets go, timers are cancelled; no `onLost`.
    public func stopAll() {
        for (host, link) in links {
            close(link, host)
            set(host) { $0.state = .disconnected }
        }
    }

    // MARK: Private

    private func state(_ host: String) -> HostState { hosts[host]?.state ?? .disconnected }

    private func set(_ host: String, _ change: (inout HostInfo) -> Void) {
        var info = hosts[host] ?? HostInfo()
        change(&info)
        if hosts[host] != info { hosts[host] = info }
    }

    private func link(_ host: String) -> Link {
        if let l = links[host] { return l }
        let l = Link(master: SSHMaster(host: host, controlPath: paths.controlPath(host), sshPath: sshPath))
        links[host] = l
        return l
    }

    private func close(_ link: Link, _ host: String) {
        link.generation += 1
        link.cancelTimer?(); link.cancelTimer = nil
        link.attempts = 0; link.reconnecting = false; link.waiting = false
        link.master.exit()
        link.server?.stop()  // unlinks the host socket
        link.server = nil
        set(host) { $0.forwarding = false }
    }

    /// One attempt; every caller of `connect` during it awaits the same task.
    private func attempt(_ host: String) async {
        let link = self.link(host)
        let t = Task { await establish(host, link) }
        link.inFlight = t
        await t.value
        link.inFlight = nil
    }

    /// master → check → host socket → forward → connected.
    private func establish(_ host: String, _ link: Link) async {
        let gen = link.generation
        link.died = false
        guard validSSHHost(host) != nil else { return failed(host, link, .exited(255, "invalid host")) }
        do { try paths.prepare() } catch { return failed(host, link, .exited(-1, "\(error)")) }
        link.master.onExit = { [weak self] f in Task { @MainActor in self?.lost(host, f) } }
        let home: String
        switch await link.master.connect() {
        case let .success(h): home = h
        case let .failure(f):
            if gen == link.generation { failed(host, link, f) }
            return
        }
        let report: ServerReport
        switch await check(host, link.master) {
        case let .success(r): report = r
        case let .failure(f):
            link.master.exit()
            if gen == link.generation { failed(host, link, f) }
            return
        }
        guard gen == link.generation else { link.master.exit(); return }
        var forwarding = false
        if link.server == nil {
            let server = ControlServer(path: paths.hostSocket(host), remote: true, handler: { [weak self] m in self?.onMessage(host, m) })
            do { try server.start(); link.server = server } catch { uiLog.error("host socket \(host, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
        if link.server != nil {
            forwarding = await link.master.forward(remote: home + "/.hangar/hangar.sock", local: paths.hostSocket(host))
        }
        guard gen == link.generation else { link.master.exit(); return }
        if link.died { link.master.exit(); return failed(host, link, .unreachable("connection lost")) }
        link.attempts = 0; link.reconnecting = false
        set(host) { $0 = HostInfo(state: .connected, home: home, report: report, forwarding: forwarding, authFailed: false) }
        onConnected?(host)
    }

    /// The server check with a deadline (a hanging `--version`) and an output cap.
    private func check(_ host: String, _ master: SSHMaster) async -> Result<ServerReport, SSHFailure> {
        let runner = Runner.ssh(host: host, controlPath: master.controlPath, sshPath: sshPath, maxOutput: Self.maxCheckOutput)
        let run = Task { await checkServer(runner) }
        let seconds = checkTimeout
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            run.cancel()
        }
        let r = await run.value
        timer.cancel()
        // Only the timer cancels `run`.
        return run.isCancelled ? .failure(.unreachable("server check timed out")) : r
    }

    private func failed(_ host: String, _ link: Link, _ f: SSHFailure) {
        switch f {
        case let .auth(m):
            giveUp(host, link, m.isEmpty ? "authentication failed" : m, auth: true)
        case let .unsupportedShell(shell):
            giveUp(host, link, "unsupported login shell: \(shell)", auth: false)
        case let .unreachable(m), let .exited(_, m):
            if link.reconnecting { scheduleRetry(host, link, lastError: m) } else { giveUp(host, link, m, auth: false) }
        }
    }

    private func giveUp(_ host: String, _ link: Link, _ message: String, auth: Bool) {
        link.attempts = 0; link.reconnecting = false; link.waiting = false
        link.server?.stop()
        link.server = nil
        set(host) { $0.state = .unreachable(message); $0.forwarding = false; if auth { $0.authFailed = true } }
        onUnreachable?(host)
    }

    private func lost(_ host: String, _ f: SSHFailure) {
        guard let link = links[host] else { return }
        if link.inFlight != nil { link.died = true; return }
        guard state(host) == .connected else { return }
        set(host) { $0.forwarding = false }
        onLost?(host)
        link.reconnecting = true
        link.attempts = 0
        switch f {
        case .auth, .unsupportedShell: failed(host, link, f)
        case let .unreachable(m), let .exited(_, m): scheduleRetry(host, link, lastError: m)
        }
    }

    /// Backoff 2, 4, 8, 16, 32, 60… s, at most `maxAttempts`; paused while the app is inactive and the host idle.
    private func scheduleRetry(_ host: String, _ link: Link, lastError: String) {
        let n = link.attempts + 1
        guard n <= Self.maxAttempts else { return giveUp(host, link, lastError, auth: false) }
        set(host) { $0.state = .reconnecting(attempt: n) }
        guard isActive() || hasWorking(host) else { link.waiting = true; return }
        let gen = link.generation
        link.cancelTimer = schedule(.seconds(min(60, 1 << n))) { [weak self] in
            guard let self, link.generation == gen else { return }
            link.cancelTimer = nil
            link.attempts = n
            Task { await self.attempt(host) }
        }
    }
}
