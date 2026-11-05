import Exec
import Foundation
import Git
import Workspace

/// Crash-safe worktree removal (decision HD-059): a quit mid-way leaves only `<path>.hangar-removing`.
let tombstoneSuffix = ".hangar-removing"

/// One atomic rename to a sibling tombstone, then `worktree prune` (its lock lifted first). Returns the tombstone; deleting
/// it is `deleteTombstone`'s (in the background, `AppState.removeWorktree`). Refused unless `path` resolves (`pwd -P`, so
/// a symlink acts on the real folder) to the top folder of a linked worktree of `git`'s repo other than its main folder:
/// a wrong task path never moves the main checkout, a subfolder or another repo. `runner`: the project's machine (argv,
/// quoted per word over ssh).
func moveWorktreeAside(_ path: String, git: Git, runner: Runner) async throws -> String {
    guard let real = try await linkedWorktree(path, mainFolder: git.repo, runner: runner) else {
        throw TombstoneError(message: "\(path) is not a linked worktree of this project, left in place")
    }
    let tomb = real + tombstoneSuffix
    // A stale tombstone would make `mv` move the folder into it; one that can't be cleared stops here.
    try await deleteTombstone(tomb, runner: runner)
    // While the path is still there: a locked worktree's registration would survive prune.
    await git.unlockWorktree(path: real)
    // shortcut: a worktree that is itself a mount point makes `mv` copy (slow, not atomic); handle when one shows up.
    let script = #"[ -e "$2" ] && { echo "$2 is in the way" >&2; exit 1; }; mv -- "$1" "$2""#
    let mv = try await runner.run(["sh", "-c", script, "sh", real, tomb], "/")
    guard mv.status == 0 else { throw TombstoneError(message: mv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    // The folder is gone already; a failed prune is redone by the next restore or `worktree add`.
    _ = try? await git.pruneWorktrees()
    return tomb
}

/// `rm -rf` of a tombstone (nothing but `*.hangar-removing`); read-only folders (Go's module cache) and locked files
/// (`uchg`) are made writable and it tries once more. A missing one is done. Throws with what is left in the way.
func deleteTombstone(_ tomb: String, runner: Runner) async throws {
    guard tomb.hasSuffix(tombstoneSuffix) else { throw TombstoneError(message: "\(tomb) is not a tombstone") }
    let script = #"""
    [ -e "$1" ] || [ -L "$1" ] || exit 0
    rm -rf -- "$1" 2>/dev/null && exit 0
    chmod -R u+w -- "$1" 2>/dev/null; chflags -R nouchg -- "$1" 2>/dev/null
    rm -rf -- "$1" 2>&1 | head -3 >&2
    [ ! -e "$1" ]
    """#
    let r = try await runner.run(["sh", "-c", script, "sh", tomb], "/")
    guard r.status != 0 else { return }
    let why = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    throw TombstoneError(message: why.isEmpty ? "\(tomb) could not be deleted" : why)
}

/// Local processes (not Hangar) whose working folder is `path` or inside it, by `lsof`; empty when it can't tell.
func processesWorking(in path: String) async -> [Int32] {
    guard let resolved = realpath(path, nil) else { return [] }
    let real = String(cString: resolved)
    free(resolved)
    guard let r = try? await Runner.local.run(["/usr/sbin/lsof", "-w", "-a", "-d", "cwd", "-F", "pn"], "/") else { return [] }
    var pids: [Int32] = [], pid: Int32?
    for line in r.stdout.split(separator: "\n") {
        if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
        if line.hasPrefix("n"), let p = pid, p != getpid() {
            let dir = String(line.dropFirst())
            if dir == real || dir.hasPrefix(real + "/") { pids.append(p) }
        }
    }
    return pids
}

/// After a chat's tabs stop: their shells and agents get up to `timeout` to leave the folder before it is checked, so
/// nothing is written after the check. Someone else's process there (an editor, a shell) is only waited for, never killed.
func waitForProcessesToLeave(_ path: String, timeout: Duration = .seconds(3)) async {
    let clock = ContinuousClock(), deadline = clock.now + timeout
    while await !processesWorking(in: path).isEmpty, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(200))
    }
}

/// A usable worktree: its `.git` is there (a half-deleted folder inside another repo still answers rev-parse) and git agrees.
/// 255 means ssh itself failed.
func isWorktree(_ path: String, runner: Runner) async throws -> Bool {
    let script = #"test -e "$1/.git" && git -C "$1" rev-parse --is-inside-work-tree"#
    let r = try await runner.run(["sh", "-c", script, "sh", path], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
}

/// The real path (`pwd -P`) of `path` if it is the top folder (`--show-toplevel`) of a linked worktree (`--git-dir` ≠
/// `--git-common-dir`) sharing `mainFolder`'s `--git-common-dir`, and not `mainFolder` itself; all resolved. A main
/// folder that doesn't resolve (missing, `~`, no access) refuses. 255 means ssh itself failed.
func linkedWorktree(_ path: String, mainFolder: String, runner: Runner) async throws -> String? {
    let script = #"""
    at() { d=$(git rev-parse "$1" 2>/dev/null) && [ -n "$d" ] && cd "$d" && pwd -P; }
    main=$(cd "$2" 2>/dev/null && pwd -P) && [ -n "$main" ] || exit 1
    repo=$(cd "$main" && at --git-common-dir) || exit 1
    real=$(cd "$1" 2>/dev/null && pwd -P) && [ -n "$real" ] && cd "$real" || exit 1
    top=$(at --show-toplevel) && [ "$top" = "$real" ] || exit 1
    dir=$(at --git-dir) && common=$(at --git-common-dir) || exit 1
    [ "$dir" != "$common" ] && [ "$common" = "$repo" ] && [ "$real" != "$main" ] || exit 1
    printf '%s' "$real"
    """#
    let r = try await runner.run(["sh", "-c", script, "sh", path, mainFolder], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0 && r.stdout.hasPrefix("/") ? r.stdout : nil
}

/// Restore's folder step (decision HD-057): a valid worktree stays; one with `.git` (even a dangling link) gets
/// `git worktree repair` and is otherwise left untouched (`.failed`). A folder without `.git` is touched only when its
/// name is the branch's worktree name: empty, it goes; with files, it is renamed to `<path>.hangar-orphan-<time>`
/// (`.restoredKeeping`). Never deletes user files.
func reviveWorktree(_ path: String, branch: String, git: Git, runner: Runner) async throws -> RestoreOutcome {
    if try await isWorktree(path, runner: runner) { return .restored }
    guard try await git.hasBranch(branch) else { return .branchMissing(branch) }
    var orphan: String?
    if try await isDirectory(path, runner: runner) {
        if try await hasGitEntry(path, runner: runner) {
            _ = try? await git.repairWorktree(path: path)
            return try await isWorktree(path, runner: runner) ? .restored : .failed("\(path) is not a valid worktree, left in place")
        }
        guard (path as NSString).lastPathComponent == branchSlug(branch) else {
            return .failed("\(path) has no .git and is not the worktree folder of \(branch), left in place")
        }
        // Half-removed by a quit mid `worktree remove` (an older build), or someone's files: an empty folder goes, a full one is kept aside.
        let kept = path + ".hangar-orphan-\(Int(Date().timeIntervalSince1970))"
        let script = #"rmdir -- "$1" 2>/dev/null && exit 0; [ ! -e "$2" ] && mv -- "$1" "$2" && exit 2; exit 1"#
        let r = try await runner.run(["sh", "-c", script, "sh", path, kept], "/")
        switch r.status {
        case 0: break
        case 2: orphan = kept
        default: return .failed("\(path) has no .git and could not be moved aside, left in place")
        }
    }
    // A folder deleted by hand leaves a registration that blocks `worktree add`.
    try await git.pruneWorktrees()
    try await git.addWorktree(path: path, existingBranch: branch)
    return orphan.map { .restoredKeeping($0) } ?? .restored
}

/// `.git` as a file, folder or (even dangling) symlink; 255 means ssh itself failed.
private func hasGitEntry(_ path: String, runner: Runner) async throws -> Bool {
    let r = try await runner.run(["sh", "-c", #"test -e "$1/.git" || test -L "$1/.git""#, "sh", path], "/")
    guard r.status != 255 else { throw TombstoneError(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return r.status == 0
}

private struct TombstoneError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppState {
    /// Startup (local, `host` nil) and host connect: tombstones a quit left behind are deleted again, shown like any
    /// removal; only in the worktree roots of known projects (the configured root and the folders of their worktree tasks).
    public func sweepTombstones(host: String?) async {
        for project in state.projects where project.host == host {
            let worktrees = state.tasks.compactMap { task -> String? in
                guard task.projectId == project.id, case .worktree(let path, _, _) = task.mode else { return nil }
                return path
            }
            // shortcut: a project with no worktree task left is skipped (no ssh call on every connect); a tombstone of
            // a deleted task waits for the next worktree task there.
            guard !worktrees.isEmpty else { continue }
            let dirs = Set(worktrees.map(parent) + [parent(worktreePath(projectPath: project.path, root: project.worktreeRoot, branch: "x"))])
            let script = #"for d; do for t in "$d"/*.hangar-removing; do [ -d "$t" ] && printf '%s\n' "$t"; done; done; exit 0"#
            let runner = runner(for: project)
            guard let found = try? await runner.run(["sh", "-c", script, "sh"] + dirs.sorted(), "/") else { continue }
            // One being deleted already (a reconnect mid-removal) is left to that delete.
            for tomb in found.stdout.split(separator: "\n").map(String.init)
            where tomb.hasSuffix(tombstoneSuffix) && !worktreeRemovals.items.contains(where: { $0.path == tomb }) {
                let name = String((tomb as NSString).lastPathComponent.dropLast(tombstoneSuffix.count))
                let item = worktreeRemovals.begin(name: name, path: tomb, local: runner.isLocal)
                worktreeRemovals.moved(item, to: tomb)
                Task { await deleteTombstoneTracked(tomb, item: item, runner: runner) }
            }
        }
    }

    private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
}
