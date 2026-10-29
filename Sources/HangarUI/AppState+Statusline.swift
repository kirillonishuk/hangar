import Exec
import Foundation
import Integration
import Workspace

/// A project folder (or a session's worktree) whose own status line Hangar overrides, or failed to (#105).
struct StatuslineNote: Equatable, Identifiable {
    enum Problem: Equatable {
        /// `.claude/settings.local.json` is not ignored by git: the override could be committed.
        case notIgnored
        case failed(String)
    }
    var host: String?
    var path: String
    var name: String
    var problem: Problem?
    var id: String { (host.map { $0 + ":" } ?? "") + path }
}

/// The folders of one machine Claude can start in: projects and their sessions' worktrees.
struct StatuslineDir: Equatable { var path: String; var name: String }

/// Hangar's line for `hangar-remote statusline` (#105): rendered on the Mac from the same config file as the CLI reads,
/// so a change in Settings reaches the next refresh on every host. nil = the user's own line («Ваша»).
func statuslineRenderer(configURL: URL) -> @Sendable (Data) -> String? {
    { payload in
        let config = HangarConfig.load(from: configURL).config
        guard config.statusline == .hangar else { return nil }
        return renderStatusline(StatuslineInput(json: payload), segments: config.statuslineSegments, now: Date())
    }
}

/// One folder: Hangar's line in (`hangar()` true and a CLI known) or taken back out of its `.claude/settings.local.json`.
/// `read` gives nil for a missing file; `change` writes or removes the local file (path, original, change); `ignored` says
/// whether git ignores the local file (nil: not a repo). `hangar` is asked after the reads, so a choice changed meanwhile
/// wins. Returns the note when the folder carries Hangar's line afterwards or something failed.
@MainActor func syncStatuslineDir(_ dir: StatuslineDir, host: String?, cli: String?, hangar: () -> Bool,
                                  read: (String) async throws -> String?,
                                  change: (String, String?, ProjectFileChange) async throws -> Void,
                                  ignored: (String) async -> Bool?) async -> StatuslineNote? {
    let base = dir.path.hasSuffix("/") ? String(dir.path.dropLast()) : dir.path
    let sharedPath = base + "/.claude/settings.json", localPath = base + "/.claude/settings.local.json"
    var note = StatuslineNote(host: host, path: dir.path, name: dir.name)
    do {
        let local = try await read(localPath)
        let shared = cli == nil ? nil : try await read(sharedPath)
        let next: ProjectFileChange?
        if hangar(), let cli { next = try projectStatuslineApply(shared: shared, local: local, cli: cli) }
        else { next = try projectStatuslineRevert(local: local) }
        var result = local
        if let next {
            try await change(localPath, local, next)
            if case .write(let text) = next { result = text } else { result = nil }
        }
        guard projectHasHangarStatusline(result) else { return nil }
        if await ignored(base) == false { note.problem = .notIgnored }
        return note
    } catch {
        note.problem = .failed(IntegrationModel.describe(error))
        return note
    }
}

extension AppState {
    /// Folders of `host`'s projects (nil = this Mac) and of their live sessions' worktrees.
    func statuslineDirs(host: String?) -> [StatuslineDir] {
        var dirs: [StatuslineDir] = []
        for p in state.projects where p.host == host { dirs += statuslineDirs(project: p) }
        return dirs
    }

    private func statuslineDirs(project p: Project) -> [StatuslineDir] {
        var dirs = [StatuslineDir(path: p.path, name: p.name)]
        for t in state.tasks where t.projectId == p.id && !t.archived {
            if case .worktree(let path, _, _) = t.mode { dirs.append(StatuslineDir(path: path, name: p.name + " › " + t.name)) }
        }
        return dirs
    }

    /// Settings → «Строка состояния Claude»: saved, then every reachable project follows (overrides added or removed).
    func setStatuslineMode(_ mode: StatuslineMode) throws {
        try setConfig("statusline", mode.rawValue) { $0.statusline = mode }
        syncAllStatuslines()
    }

    /// This Mac and every connected host with projects, in the queue's order.
    @discardableResult func syncAllStatuslines() -> Task<Void, Never> {
        enqueueStatusline { [weak self] in
            guard let self else { return }
            await self.runStatuslineSync(host: nil, only: nil, revert: false)
            for host in Set(self.state.projects.compactMap(\.host)).sorted() where self.remote.hosts[host]?.state == .connected {
                await self.runStatuslineSync(host: host, only: nil, revert: false)
            }
        }
    }

    func setStatuslineSegment(_ segment: StatuslineSegment, on: Bool) throws {
        var set = Set(config.statuslineSegments)
        if on { set.insert(segment) } else { set.remove(segment) }
        try setStatuslineChips(config.statuslineChips, on: set)
    }

    /// A chip moved (drag or «Left»/«Right», #110): before the chip at `index` of the current row.
    func moveStatuslineSegment(_ segment: StatuslineSegment, to index: Int) throws {
        let chips = statuslineMove(config.statuslineChips, segment, to: index)
        guard chips != config.statuslineChips else { return }
        try setStatuslineChips(chips, on: Set(config.statuslineSegments))
    }

    /// Both keys in one write: the on segments in the chips' order for the renderer, the whole row for Settings.
    private func setStatuslineChips(_ chips: [StatuslineSegment], on: Set<StatuslineSegment>) throws {
        try editConfig({ HangarConfig.settingStatusline($0, chips: chips, on: on) }) {
            $0.statuslineSegments = chips.filter(on.contains)
            $0.statuslineOrder = chips
        }
        uiLog.info("config statusline_segments = \(chips.filter(on.contains).map(\.rawValue), privacy: .public)")
    }

    /// Projects of `host` (nil = this Mac) get Hangar's line in their local settings when «Hangar» is chosen and the
    /// agent's own settings use Hangar's status line (its CLI is taken from there); otherwise Hangar's overrides go.
    /// On launch, a host's connect, a project or worktree added or restored, and a change in Settings.
    func syncProjectStatuslines(host: String?) async {
        await enqueueStatusline { [weak self] in await self?.runStatuslineSync(host: host, only: nil, revert: false) }.value
    }

    /// Hangar's overrides out of these folders (all of `host`'s when nil): before a project is removed, a worktree is
    /// archived or deleted, or the Claude integration is uninstalled (#105).
    func revertProjectStatuslines(host: String?, dirs: [StatuslineDir]? = nil) async {
        await enqueueStatusline { [weak self] in await self?.runStatuslineSync(host: host, only: dirs, revert: true) }.value
    }

    /// A session's host follows again (its worktree is back, or it stayed after all).
    func syncStatuslines(task id: UUID) {
        let host = state.tasks.first { $0.id == id }.flatMap { project($0.projectId) }?.host
        Task { await syncProjectStatuslines(host: host) }
    }

    /// A project leaves Hangar: its folder and its sessions' worktrees lose Hangar's override first.
    func revertProjectStatuslines(projectId: UUID) {
        guard let p = project(projectId) else { return }
        let dirs = statuslineDirs(project: p)
        enqueueStatusline { [weak self] in await self?.runStatuslineSync(host: p.host, only: dirs, revert: true) }
    }

    /// One sync at a time, in call order: interleaved reads and writes could leave an override after «Ваша».
    @discardableResult private func enqueueStatusline(_ job: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = statuslineQueue
        let task = Task { @MainActor in
            await previous?.value
            await job()
        }
        statuslineQueue = task
        return task
    }

    private func runStatuslineSync(host: String?, only: [StatuslineDir]?, revert: Bool) async {
        guard statuslineSync else { return }
        let dirs = only ?? statuslineDirs(host: host)
        let hangar: () -> Bool = { [weak self] in !revert && self?.config.statusline == .hangar }
        var notes: [StatuslineNote] = []
        if let host {
            // A DEBUG run without a fake ssh never writes on a server (as `upgradeRemote`).
            guard autoUpgradeRemote, remote.hosts[host]?.state == .connected else { return }
            let m = ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
            notes = await m.syncProjectStatuslines(dirs, hangar: hangar)
        } else {
            let cli = (try? readUserFile(await doctorAgentPaths().claude)).flatMap(hangarStatuslineCLI)
            let backups = URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent).appendingPathComponent("backups")
            for dir in dirs {
                let note = await syncStatuslineDir(
                    dir, host: nil, cli: cli, hangar: hangar,
                    read: { try readUserFile(URL(fileURLWithPath: $0)) },
                    change: { path, original, change in
                        let url = URL(fileURLWithPath: path)
                        let backup: URL? = switch change {
                        case .write(let text): try writeUserFile(url, text: text, expected: original, now: Date(), backupDir: backups)
                        case .remove: try removeUserFile(url, expected: original ?? "", now: Date(), backupDir: backups)
                        }
                        uiLog.info("statusline override \(path, privacy: .public), backup \(backup?.path ?? "-", privacy: .public)")
                    },
                    ignored: { dir in
                        guard let r = try? await Runner.local.run(["git", "-C", dir, "check-ignore", "-q", ".claude/settings.local.json"], dir),
                              r.status == 0 || r.status == 1 else { return nil }
                        return r.status == 0
                    })
                if let note { notes.append(note) }
            }
        }
        let paths = only.map { Set($0.map(\.path)) }
        statuslineNotes = statuslineNotes.filter { note in note.host != host || (paths.map { !$0.contains(note.path) } ?? false) } + notes
    }
}
