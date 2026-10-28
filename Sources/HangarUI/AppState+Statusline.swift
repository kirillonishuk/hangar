import Exec
import Foundation
import Integration
import Workspace

/// A project folder (or a session's worktree) whose own status line Hangar overrides, or failed to (#103).
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

/// Hangar's line for `hangar-remote statusline` (#103): rendered on the Mac from the same config file as the CLI reads,
/// so a change in Settings reaches the next refresh on every host. nil = the user's own line («Ваша»).
func statuslineRenderer(configURL: URL) -> @Sendable (Data) -> String? {
    { payload in
        let config = HangarConfig.load(from: configURL).config
        guard config.statusline == .hangar else { return nil }
        return renderStatusline(StatuslineInput(json: payload), segments: config.statuslineSegments,
                                ru: config.language.resolved() == .ru, now: Date())
    }
}

/// One folder: Hangar's line in (`hangar`) or taken back out of its `.claude/settings.local.json`. `read` gives nil for
/// a missing file, `write` gets (path, original, updated), `ignored` says whether git ignores the local file
/// (nil: not a repo). Returns the note when the folder carries Hangar's line afterwards or something failed.
@MainActor func syncStatuslineDir(_ dir: StatuslineDir, host: String?, cli: String?, hangar: Bool,
                       read: (String) async throws -> String?, write: (String, String?, String) async throws -> Void,
                       ignored: (String) async -> Bool?) async -> StatuslineNote? {
    let base = dir.path.hasSuffix("/") ? String(dir.path.dropLast()) : dir.path
    let sharedPath = base + "/.claude/settings.json", localPath = base + "/.claude/settings.local.json"
    var note = StatuslineNote(host: host, path: dir.path, name: dir.name)
    do {
        let local = try await read(localPath)
        var result = local
        if hangar, let cli {
            if let updated = try projectStatuslineApply(shared: try await read(sharedPath), local: local, cli: cli) {
                try await write(localPath, local, updated)
                result = updated
            }
        } else if let updated = try projectStatuslineRevert(local: local) {
            try await write(localPath, local, updated)
            result = updated
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
        for p in state.projects where p.host == host {
            dirs.append(StatuslineDir(path: p.path, name: p.name))
            for t in state.tasks where t.projectId == p.id && !t.archived {
                if case .worktree(let path, _, _) = t.mode { dirs.append(StatuslineDir(path: path, name: p.name + " › " + t.name)) }
            }
        }
        return dirs
    }

    /// Settings → «Строка состояния Claude»: saved, then every reachable project follows (overrides added or removed).
    func setStatuslineMode(_ mode: StatuslineMode) throws {
        try setConfig("statusline", mode.rawValue) { $0.statusline = mode }
        Task {
            await syncProjectStatuslines(host: nil)
            for host in Set(state.projects.compactMap(\.host)) where remote.hosts[host]?.state == .connected {
                await syncProjectStatuslines(host: host)
            }
        }
    }

    func setStatuslineSegment(_ segment: StatuslineSegment, on: Bool) throws {
        var set = Set(config.statuslineSegments)
        if on { set.insert(segment) } else { set.remove(segment) }
        let segments = StatuslineSegment.allCases.filter(set.contains)
        let literal = "[" + segments.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "]"
        try setConfig("statusline_segments", literal: literal) { $0.statuslineSegments = segments }
    }

    /// Projects of `host` (nil = this Mac) get Hangar's line in their local settings when «Hangar» is chosen and the
    /// agent's own settings use Hangar's status line (its CLI is taken from there); otherwise Hangar's overrides go.
    /// On launch, a host's connect, a project or worktree added, and a change in Settings.
    func syncProjectStatuslines(host: String?) async {
        guard statuslineSync else { return }
        let hangar = config.statusline == .hangar
        let dirs = statuslineDirs(host: host)
        var notes: [StatuslineNote] = []
        if let host {
            // A DEBUG run without a fake ssh never writes on a server (as `upgradeRemote`).
            guard autoUpgradeRemote, remote.hosts[host]?.state == .connected else { return }
            let m = ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
            notes = await m.syncProjectStatuslines(dirs, hangar: hangar)
        } else {
            let cli = (try? readUserFile(await doctorAgentPaths().claude)).flatMap(hangarStatuslineCLI)
            let now = Date()
            for dir in dirs {
                let note = await syncStatuslineDir(
                    dir, host: nil, cli: cli, hangar: hangar,
                    read: { try readUserFile(URL(fileURLWithPath: $0)) },
                    write: { path, original, updated in
                        let backup = try writeUserFile(URL(fileURLWithPath: path), text: updated, expected: original, now: now)
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
        statuslineNotes = statuslineNotes.filter { $0.host != host } + notes
    }
}
