import Foundation

/// What HEAD points at: a branch (also an unborn one) or a commit (detached, short hash).
public enum Head: Equatable, Sendable {
    case branch(String)
    case detached(String)

    /// The branch name or the short hash, as shown on the branch button.
    public var title: String {
        switch self {
        case .branch(let name), .detached(let name): name
        }
    }
}

/// Why a switch or a new branch was refused before git ran (decision #114). git's own failures stay `GitError`.
public enum BranchSwitchError: Error, Equatable, Sendable {
    /// `status --porcelain` is not empty: `files` entries (untracked included).
    case dirty(files: Int)
    /// The branch is checked out in another worktree at `path`.
    case checkedOutElsewhere(branch: String, path: String)
    /// The target tracks these paths, now ignored files on disk: git would overwrite them without asking.
    case wouldOverwriteIgnored([String])
    /// A merge, rebase, am, cherry-pick, revert or bisect is not finished (git's own word for it).
    case operationInProgress(String)
    case invalidName
    case alreadyExists(String)
}

/// Switching and creating branches (decision #114): only `git switch` / `git switch -c`, never with uncommitted
/// changes (except a new branch at HEAD, which leaves the working tree as it is), never over ignored files the target
/// tracks, never during an unfinished merge / rebase / am / cherry-pick / revert / bisect.
extension Git {
    /// nil outside a repository or in a repository without HEAD.
    public func head() async throws -> Head? {
        if let name = try await currentBranch() { return .branch(name) }
        return try await probe(["rev-parse", "--short", "HEAD"]).map(Head.detached)
    }

    /// Entries of `status --porcelain`, every untracked file and dirty submodule included whatever the repository's
    /// config hides (`status.showUntrackedFiles`, `submodule.*.ignore`); non-`-z` lines: a newline in a path is quoted.
    public func uncommittedCount() async throws -> Int {
        try await exec(["--no-optional-locks", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"])
            .split(separator: "\n").count
    }

    /// The unfinished operation (`merge`, `rebase`, `am`, `cherry-pick`, `revert`, `bisect`), nil when there is none.
    /// One shell call: the remote case costs one round trip; `rebase-apply/applying` before `rebase-apply` tells am apart.
    public func operationInProgress() async throws -> String? {
        let script = #"""
        for n in MERGE_HEAD rebase-merge rebase-apply/applying rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
          p=$(git rev-parse --git-path "$n") && [ -e "$p" ] && { echo "$n"; exit 0; }
        done
        exit 0
        """#
        let r = try await runner.run(["sh", "-c", script], repo)
        guard r.status == 0 else { throw GitError(args: ["rev-parse", "--git-path"], status: r.status, stderr: r.stderr.trimmed) }
        let names = ["MERGE_HEAD": "merge", "rebase-merge": "rebase", "rebase-apply/applying": "am", "rebase-apply": "rebase",
                     "CHERRY_PICK_HEAD": "cherry-pick", "REVERT_HEAD": "revert", "BISECT_LOG": "bisect"]
        return names[r.stdout.trimmed]
    }

    /// Ignored files on disk that `target` tracks: `switch` replaces them silently (git treats ignored as expendable).
    /// `target` is a full ref or a commit; at most `limit` paths.
    func ignoredOverwritten(by target: String, limit: Int = 20) async throws -> [String] {
        // The whole repository, top-relative: a project in a subfolder still loses a root `.env`.
        let ignored = try await exec(["--no-optional-locks", "ls-files", "-z", "--full-name", "-o", "-i", "--exclude-standard", "--directory", "--", ":(top)"])
            .split(separator: "\0").map(String.init)
        guard !ignored.isEmpty else { return [] }
        let set = Set(ignored)
        var hit: [String] = [], underDir: [String] = []
        for t in try await exec(["ls-tree", "-r", "-z", "--full-tree", "--name-only", target]).split(separator: "\0").map(String.init) {
            if set.contains(t) { hit.append(t); continue }
            var prefix = Substring(t)
            while let slash = prefix.lastIndex(of: "/") {
                prefix = prefix[..<slash]
                if set.contains(String(prefix)) { hit.append(t); break }  // an ignored file where the target has a folder
                if set.contains(String(prefix) + "/") { underDir.append(t); break }  // inside an ignored folder: only if it exists
            }
        }
        if !underDir.isEmpty {
            // shortcut: past 500 paths the check is skipped as a conflict, not run with a huge argv; change if it bites.
            if underDir.count > 500 { return Array((hit + underDir).prefix(limit)) }
            let present = try await exec(["--no-optional-locks", "ls-files", "-z", "--full-name", "-o", "-i", "--exclude-standard", "--"]
                                         + underDir.map { ":(top,literal)" + $0 })
            hit += present.split(separator: "\0").map(String.init)
        }
        return Array(hit.sorted().prefix(limit))
    }

    /// Branch → path of every worktree that has a branch checked out (this one too).
    public func checkedOutBranches() async throws -> [String: String] {
        var result: [String: String] = [:]
        var path: String?
        for line in try await exec(["worktree", "list", "--porcelain"]).split(separator: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line.hasPrefix("branch refs/heads/"), let path { result[String(line.dropFirst("branch refs/heads/".count))] = path }
        }
        return result
    }

    /// `git switch` to a local branch, or to a remote-tracking one (`origin/x`): its local branch when one exists,
    /// else a new local tracking branch (`git switch --track`). Refuses with changes or when the branch is checked
    /// out in another worktree. The current branch is a no-op.
    public func switchBranch(to name: String, isRemote: Bool) async throws {
        let local = isRemote ? try await localName(ofRemote: name) : name
        let current = try await currentBranch()
        if current == local { return }
        if let op = try await operationInProgress() { throw BranchSwitchError.operationInProgress(op) }
        let count = try await uncommittedCount()
        guard count == 0 else { throw BranchSwitchError.dirty(files: count) }
        if let path = try await checkedOutBranches()[local] { throw BranchSwitchError.checkedOutElsewhere(branch: local, path: path) }
        let hasLocal = try await hasBranch(local)
        let track = isRemote && !hasLocal
        let lost = try await ignoredOverwritten(by: track ? "refs/remotes/" + name : "refs/heads/" + local)
        guard lost.isEmpty else { throw BranchSwitchError.wouldOverwriteIgnored(lost) }
        try await exec(track ? ["switch", "--track", "--", name] : ["switch", "--", local])
    }

    /// `git switch -c <name> [<start>]`, without upstream (as worktree branches). At HEAD (`start` nil) uncommitted
    /// changes stay and go along; from another start point they refuse, as a switch does.
    public func createBranch(_ name: String, from start: String? = nil) async throws {
        guard await isValidBranchName(name) else { throw BranchSwitchError.invalidName }
        guard !(try await hasBranch(name)) else { throw BranchSwitchError.alreadyExists(name) }
        if let op = try await operationInProgress() { throw BranchSwitchError.operationInProgress(op) }
        if let start {
            let count = try await uncommittedCount()
            guard count == 0 else { throw BranchSwitchError.dirty(files: count) }
            // A dash-leading start is a branch name, not an option of ls-tree.
            let lost = try await ignoredOverwritten(by: start.hasPrefix("-") ? "refs/heads/" + start : start)
            guard lost.isEmpty else { throw BranchSwitchError.wouldOverwriteIgnored(lost) }
        }
        // `-c` takes the next argument as the name: a validated name never starts with "-", the start goes after `--`.
        try await exec(["switch", "--no-track", "-c", name] + (start.map { ["--", $0] } ?? []))
    }

    /// `origin/feat/x` → `feat/x`: the longest remote name that prefixes it (remote names may contain "/").
    private func localName(ofRemote name: String) async throws -> String {
        let remote = try await remotes().filter { name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return remote.map { String(name.dropFirst($0.count + 1)) } ?? name
    }
}
