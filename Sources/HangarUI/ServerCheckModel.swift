import ControlServer
import Exec
import Foundation
import Integration
import Observation

/// Follows `$f`'s symlinks (at most 32), as the write does: the backup goes next to the real file.
let remoteResolveLinks = #"""
i=0
while [ -L "$f" ] && [ $i -lt 32 ]; do
  l=$(readlink "$f")
  case $l in /*) f=$l ;; *) f=${f%/*}/$l ;; esac
  i=$((i + 1))
done
"""#

/// Writes an integration file on the server from stdin = `<expected bytes><new bytes>`: `$1` path, `$2` length of the
/// expected bytes (`-` = the file must not exist), `$3` timestamp. Symlinks are followed (the link stays a link).
/// Exit 3 = the file is not what the plan was made from. The old file is copied (`cp -p`) next to it before anything
/// is replaced; the new one goes to a temp file with the old mode and is renamed over it. Prints the backup path.
/// `dd bs=1`: `head -c` may read past its count from a pipe, eating the new bytes.
let remoteFileWriteScript = "set -e\nf=$1; n=$2; ts=$3\n" + remoteResolveLinks + "\n" + #"""
d=${f%/*}
mkdir -p "$d"
tmp=$(mktemp "$d/.hangar-XXXXXX")
trap 'rm -f "$tmp" "$tmp.old"' EXIT
if [ "$n" = - ]; then
  [ ! -e "$f" ] || exit 3
  cat > "$tmp"
  [ ! -e "$f" ] || exit 3
else
  dd bs=1 count="$n" of="$tmp.old" 2>/dev/null
  [ -f "$f" ] && cmp -s "$tmp.old" "$f" || exit 3
  b="$f.hangar-backup-$ts"; k=2
  while [ -e "$b" ]; do b="$f.hangar-backup-$ts-$k"; k=$((k + 1)); done
  cp -p "$f" "$b"
  cp -p "$f" "$tmp"
  cat > "$tmp"
  cmp -s "$tmp.old" "$f" || exit 3
  printf '%s\n' "$b"
fi
mv -f "$tmp" "$f"
"""#

/// «Сервер <host>»: the report of the last check, the install plan (run only after «Установить») and the agents'
/// integrations on the server. Nothing is written to the server except by `installFinished` of a confirmed install
/// or `applyIntegration` of a plan the user confirmed in the diff sheet; local ~/.claude / ~/.codex are never touched.
@MainActor @Observable final class ServerCheckModel {
    enum Phase: Equatable { case checking, ready, installing, failed(String) }

    let host: String
    private(set) var report: ServerReport?
    private(set) var plan: (steps: [InstallStep], manual: [RemoteTool]) = ([], [])
    /// Ticked optional tools (codex): only they join the plan; the shown plan is what «Установить» runs.
    var optional: Set<RemoteTool> = [] {
        didSet { if let report, phase != .installing { plan = installPlan(report, remoteVersion: hangarRemoteVersion, optional: optional) } }
    }
    /// The optional tools the server lacks: the sheet's unticked checkboxes.
    var missingOptional: [RemoteTool] { RemoteTool.optionalInstalls.filter { report?.tools[$0] == nil && report != nil } }
    private(set) var phase: Phase = .checking
    /// The steps the user confirmed with «Установить»; the terminal runs exactly these.
    private(set) var confirmedSteps: [InstallStep] = []
    /// Bumped per install: the sheet makes a fresh terminal for each run.
    private(set) var installRun = 0
    /// The terminal of the last confirmed install (kept after it exits, so its output stays readable).
    private(set) var installSpec: LaunchSpec?
    /// Integration states on the server; nil while not read (or the agent is not there).
    private(set) var claude: IntegrationState?
    private(set) var codex: IntegrationState?
    var integrationError: String?
    /// After a write: where the backup went.
    var message: String?
    /// Shown in the consent sheet; nothing is written until it is confirmed.
    var pendingPlan: IntegrationPlan?

    @ObservationIgnored private let remote: RemoteHosts
    @ObservationIgnored private let run: (InstallStep, Data?) async -> RunResult
    @ObservationIgnored var now: () -> Date = Date.init

    init(host: String, remote: RemoteHosts, run: @escaping (InstallStep, Data?) async -> RunResult) {
        self.host = host
        self.remote = remote
        self.run = run
    }

    /// Non-terminal steps and file writes: `sshWrite` over the host's master, `data` on stdin.
    static func sshRun(remote: RemoteHosts, host: String) -> (InstallStep, Data?) async -> RunResult {
        { [weak remote] step, data in
            await remote?.write(host, script: step.command, args: [], input: data ?? Data())
                ?? RunResult(status: -1, stdout: "", stderr: RemoteHostError.notConnected(host).description)
        }
    }

    /// `~/.hangar/bin/hangar-remote` on the server: what its hooks call.
    var cli: String? { report.map { $0.home + "/.hangar/bin/hangar-remote" } }

    /// «Проверить сервер»: the check again over the live master, then the integration files.
    func refresh() async {
        phase = .checking
        // Not connected (e.g. no tab of this host shown yet): connecting runs the check itself.
        if remote.hosts[host]?.state == .connected { await remote.recheck(host) } else { await remote.connect(host) }
        await show()
    }

    /// The report of the last check (right after connecting there is no need to check again).
    func show() async {
        guard let info = remote.hosts[host], info.state == .connected, let r = info.report else {
            phase = .failed(hostFailure(host, remote.hosts[host]).text)
            return
        }
        report = r
        plan = installPlan(r, remoteVersion: hangarRemoteVersion, optional: optional)
        phase = .ready
        await readIntegrations()
    }

    /// The install terminal's command: `terminalScript(confirmed or current steps)` through `ssh -t`.
    func terminalSpec() -> LaunchSpec? {
        guard let target = remote.target(host) else { return nil }
        let steps = phase == .installing ? confirmedSteps : plan.steps
        return installTerminalSpec(target: target, steps: steps)
    }

    /// The host socket reaches the server (agent statuses arrive).
    var forwarding: Bool { remote.hosts[host]?.forwarding == true }

    /// «Установить»: the shown steps are confirmed. With nothing for a terminal the writes run at once.
    func startInstall() {
        guard phase == .ready, !plan.steps.isEmpty else { return }
        confirmedSteps = plan.steps
        installRun += 1
        phase = .installing
        guard confirmedSteps.contains(where: \.inTerminal) else {
            installSpec = nil
            Task { await installFinished(code: 0) }
            return
        }
        installSpec = terminalSpec()
    }

    /// The terminal exited: on success the confirmed `hangar-remote` goes over stdin; then the check again.
    func installFinished(code: Int32) async {
        guard phase == .installing else { return }
        guard code == 0 else {
            phase = .failed(L10n.installFailed(code))
            return
        }
        for step in confirmedSteps where !step.inTerminal {
            let r = await run(step, Data(hangarRemoteScript.utf8))
            guard r.status == 0 else {
                phase = .failed(lastLine(r.stderr) ?? L10n.exitStatus(r.status))
                return
            }
        }
        await refresh()
    }

    // MARK: Integrations

    private func integrationPath(_ t: IntegrationTarget) -> String? {
        report.map { t == .claude ? $0.claudeDir + "/settings.json" : $0.codexHome + "/config.toml" }
    }

    private func readIntegrations() async {
        guard let cli else { return }
        for t in [IntegrationTarget.claude, .codex] {
            var state: IntegrationState?
            if t == .claude || report?.tools[.codex] != nil, let path = integrationPath(t) {
                // No file yet (nil) is «not installed»; an unreadable one stays unknown.
                if let text = try? await read(path) as String?? { state = t == .claude ? claudeState(text, cli: cli) : codexState(text, cli: cli) }
            }
            if t == .claude { claude = state } else { codex = state }
        }
    }

    /// `cat` on the server; a missing file is nil (not an error).
    private func read(_ path: String) async throws -> String? {
        let r = try await remote.runner(host).run(["cat", path], "")
        if r.status == 0 { return r.stdout }
        if r.status == 1, r.stderr.contains("No such file") { return nil }
        throw RemoteFileError(message: lastLine(r.stderr) ?? L10n.exitStatus(r.status))
    }

    /// The file the write will replace (its symlinks followed on the server), for the sheet's backup line.
    private func resolve(_ path: String) async throws -> String {
        let r = try await remote.runner(host).run(["/bin/sh", "-c", "f=$1\n" + remoteResolveLinks + "\nprintf '%s\\n' \"$f\"", "sh", path], "")
        guard r.status == 0, let real = lastLine(r.stdout) else { throw RemoteFileError(message: lastLine(r.stderr) ?? L10n.exitStatus(r.status)) }
        return real
    }

    private struct RemoteFileError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The diff the consent sheet shows: the same install/uninstall as on this Mac, for the server's file.
    func integrationPlan(_ t: IntegrationTarget, install: Bool) async -> IntegrationPlan? {
        guard let cli, let path = integrationPath(t) else { return nil }
        message = nil
        do {
            let original = try await read(path)
            let updated: String
            switch (t, install) {
            case (.claude, true): updated = try claudeInstall(original, cli: cli)
            case (.codex, true): updated = try codexInstall(original, cli: cli)
            case (_, false):
                guard let original else { return nil }
                updated = t == .claude ? try claudeUninstall(original) : try codexUninstall(original)
            }
            integrationError = nil
            let real = try await resolve(path)
            return IntegrationPlan(target: t, install: install, url: URL(fileURLWithPath: path), resolved: URL(fileURLWithPath: real),
                                   original: original, updated: updated, diff: collapsed(lineDiff(original ?? "", updated)),
                                   displayPath: host + ":" + path, backupDisplayPath: host + ":" + real)
        } catch {
            integrationError = (error as? RemoteFileError)?.message ?? IntegrationModel.describe(error)
            return nil
        }
    }

    func review(_ t: IntegrationTarget, install: Bool) async {
        integrationError = nil
        pendingPlan = await integrationPlan(t, install: install)
    }

    func cancelPlan() {
        pendingPlan = nil
        integrationError = nil
    }

    /// «Применить»: written → the sheet closes; the file changed meanwhile → a fresh diff with the error; else the same plan.
    func confirmPlan() async {
        guard let plan = pendingPlan else { return }
        if await applyIntegration(plan) { pendingPlan = nil; return }
        guard integrationError == L10n.fileChanged else { return }
        pendingPlan = await integrationPlan(plan.target, install: plan.install)
        integrationError = L10n.fileChanged
    }

    /// Writes the confirmed plan on the server; refuses (`fileChanged`) if the file is not what the plan was made from.
    func applyIntegration(_ p: IntegrationPlan) async -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let old = p.original.map { Data($0.utf8) }
        // The path exactly as read (`URL.path` would normalize it).
        let path = p.displayPath.map { String($0.dropFirst(host.count + 1)) } ?? p.url.path
        let args = [path, old.map { String($0.count) } ?? "-", f.string(from: now())]
        let r = await remote.write(host, script: remoteFileWriteScript, args: args, input: (old ?? Data()) + Data(p.updated.utf8))
        guard r.status == 0 else {
            integrationError = r.status == 3 ? L10n.fileChanged : L10n.integrationWriteFailed(lastLine(r.stderr) ?? L10n.exitStatus(r.status))
            return false
        }
        integrationError = nil
        message = lastLine(r.stdout).map { L10n.backupCreated(host + ":" + $0) }
        await readIntegrations()
        return true
    }
}

/// Last non-empty line (server output can carry rc-file noise before the real message).
func lastLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }.map { String($0.prefix(300)) }
}

/// Why a host is not connected, for a sheet or a tooltip; `mono`: ssh's own text.
@MainActor func hostFailure(_ host: String, _ info: HostInfo?) -> (text: String, mono: Bool) {
    guard let info else { return (L10n.hostDisconnected, false) }
    if info.authFailed { return (L10n.sshAuthFailed(host), false) }
    if let shell = info.unsupportedShell { return (L10n.unsupportedShell(shell), false) }
    if case let .unreachable(message) = info.state { return (message, true) }
    return (hostStatusLabel(info), false)
}

/// The host row's state in the sidebar. A paused retry (no timer) reads as plain «offline», not as work going on.
@MainActor func hostStatusLabel(_ info: HostInfo?) -> String {
    switch info?.state ?? .disconnected {
    case .connected: L10n.hostConnected
    case .connecting: L10n.hostConnecting
    case .reconnecting: info?.retryPaused == true ? L10n.hostPaused : L10n.hostReconnecting
    case .unreachable: L10n.hostUnreachable
    case .disconnected: L10n.hostDisconnected
    }
}
