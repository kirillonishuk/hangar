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
    case invalidName
    case alreadyExists(String)
}

/// Switching and creating branches (decision #114): only `git switch` / `git switch -c`, never with uncommitted
/// changes (except a new branch at HEAD, which leaves the working tree as it is).
extension Git {
    /// nil outside a repository or in a repository without HEAD.
    public func head() async throws -> Head? {
        if let name = try await currentBranch() { return .branch(name) }
        return try await probe(["rev-parse", "--short", "HEAD"]).map(Head.detached)
    }

    /// Entries of `status --porcelain`, untracked included (non-`-z` lines: a newline in a path is quoted).
    public func uncommittedCount() async throws -> Int {
        try await exec(["--no-optional-locks", "status", "--porcelain"]).split(separator: "\n").count
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
        let count = try await uncommittedCount()
        guard count == 0 else { throw BranchSwitchError.dirty(files: count) }
        if let path = try await checkedOutBranches()[local] { throw BranchSwitchError.checkedOutElsewhere(branch: local, path: path) }
        if isRemote, !(try await hasBranch(local)) {
            try await exec(["switch", "--track", "--", name])
        } else {
            try await exec(["switch", "--", local])
        }
    }

    /// `git switch -c <name> [<start>]`, without upstream (as worktree branches). At HEAD (`start` nil) uncommitted
    /// changes stay and go along; from another start point they refuse, as a switch does.
    public func createBranch(_ name: String, from start: String? = nil) async throws {
        guard await isValidBranchName(name) else { throw BranchSwitchError.invalidName }
        guard !(try await hasBranch(name)) else { throw BranchSwitchError.alreadyExists(name) }
        if start != nil {
            let count = try await uncommittedCount()
            guard count == 0 else { throw BranchSwitchError.dirty(files: count) }
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
