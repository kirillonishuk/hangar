import Foundation

/// One entry of `git worktree list --porcelain`; the first one is the main checkout.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    /// nil when detached or bare.
    public var branch: String?
    /// Registered, but its folder is gone (`prunable`): not a place to work in.
    public var prunable: Bool
    /// `git worktree lock`: git refuses to remove or prune it, so Hangar doesn't offer to.
    public var locked: Bool
    /// Text after `locked` (Claude Code writes `claude agent agent-<hex> (pid ...)`); nil: none.
    public var lockReason: String?

    public init(path: String, branch: String?, prunable: Bool = false, locked: Bool = false, lockReason: String? = nil) {
        self.path = path
        self.branch = branch
        self.prunable = prunable
        self.locked = locked
        self.lockReason = lockReason
    }
}

/// Where a chat's copy (worktree) is now, by the repository's own list.
public enum WorktreePlace: Equatable, Sendable {
    /// The stored folder is a registered worktree root.
    case inPlace
    /// Not registered any more, but its branch is checked out in this other linked worktree (`git worktree move`).
    case moved(to: String)
    /// Neither: the folder is gone or no longer a worktree (deleted, pruned), and the branch is in no linked worktree.
    case missing
}

/// `path` (the stored worktree folder) against the repository's list. A folder that still exists inside the main
/// checkout answers git as the main checkout, so only the list decides. The main checkout is never a copy's new place.
/// `same` compares two paths (a local caller resolves symlinks: git prints real paths).
public func worktreePlace(path: String, branch: String, in list: [WorktreeEntry],
                          same: (String, String) -> Bool = { $0 == $1 }) -> WorktreePlace {
    let linked = list.dropFirst().filter { !$0.prunable }
    if linked.contains(where: { same($0.path, path) }) { return .inPlace }
    if let other = linked.first(where: { $0.branch == branch }) { return .moved(to: other.path) }
    return .missing
}

/// As `worktreePlace`, comparing paths as written, then — not in place — once more with `path` resolved on its machine
/// (`resolve`: symlinks, `/tmp` → `/private/tmp`; git lists real paths). One resolution only when needed.
public func worktreePlace(path: String, branch: String, in list: [WorktreeEntry],
                          resolve: @Sendable (String) async -> String?) async -> WorktreePlace {
    let place = worktreePlace(path: path, branch: branch, in: list)
    guard place != .inPlace, let real = await resolve(path), real != path else { return place }
    return worktreePlace(path: real, branch: branch, in: list)
}

func parseWorktreeList(_ out: String) -> [WorktreeEntry] {
    var result: [WorktreeEntry] = []
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("worktree ") {
            result.append(WorktreeEntry(path: String(line.dropFirst("worktree ".count)), branch: nil))
        } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
            result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
        } else if line == "prunable" || line.hasPrefix("prunable "), !result.isEmpty {
            result[result.count - 1].prunable = true
        } else if line == "locked" || line.hasPrefix("locked "), !result.isEmpty {
            result[result.count - 1].locked = true
            let reason = line.dropFirst("locked".count).trimmingCharacters(in: .whitespaces)
            result[result.count - 1].lockReason = reason.isEmpty ? nil : reason
        }
    }
    return result
}

extension Git {
    /// Every worktree of the repository, the main checkout first (`git worktree list --porcelain`).
    public func worktrees() async throws -> [WorktreeEntry] {
        parseWorktreeList(try await exec(["--no-optional-locks", "worktree", "list", "--porcelain"]))
    }

    /// `path` with symlinks resolved on the repository's machine (`pwd -P`); nil when it can't be entered.
    public func resolvedPath(_ path: String) async -> String? {
        guard let r = try? await runner.run(["sh", "-c", #"cd -- "$1" 2>/dev/null && pwd -P"#, "sh", path], "/"), r.status == 0 else { return nil }
        let out = r.stdout.trimmed
        return out.hasPrefix("/") ? out : nil
    }
}

/// What the «Ветка копии» field names (decision HD-169): a branch to create from the base, or an existing one to check out.
public enum CopyBranch: Equatable, Sendable {
    /// No such branch: created from the base without upstream (HD-042).
    case new(String)
    /// A local branch no worktree has: checked out as is.
    case local(String)
    /// Only on a remote: a local branch `local` tracking `upstream` (`origin/x`) is created, as `git switch --track` does.
    case remote(local: String, upstream: String)
    /// A local branch already checked out at `path` (the project folder or another copy): git refuses a second one.
    case checkedOut(String, path: String)

    /// The local branch the copy will be on.
    public var name: String {
        switch self {
        case .new(let n), .local(let n), .checkedOut(let n, _): n
        case .remote(let n, _): n
        }
    }
}

/// `typed` against the repository's branches: `origin/x` names the remote branch (its local `x` when there is one); a bare
/// `x` is the local branch, else the remote-only one (origin first); anything else is new. `checkedOut`: branch → worktree path.
public func classifyCopyBranch(_ typed: String, branches: [Branch], remotes: [String],
                               checkedOut: [String: String]) -> CopyBranch {
    let remoteNames = Set(branches.filter(\.isRemote).map(\.name))
    let localNames = Set(branches.filter { !$0.isRemote }.map(\.name))
    var local = typed
    var upstream: String?
    if remoteNames.contains(typed), let r = remotes.filter({ typed.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
        local = String(typed.dropFirst(r.count + 1))
        upstream = typed
    } else if !localNames.contains(typed), !typed.isEmpty {
        let ordered = remotes.filter { $0 == "origin" } + remotes.filter { $0 != "origin" }
        upstream = ordered.map { $0 + "/" + typed }.first(where: remoteNames.contains)
    }
    if localNames.contains(local) { return checkedOut[local].map { .checkedOut(local, path: $0) } ?? .local(local) }
    if let upstream { return .remote(local: local, upstream: upstream) }
    return .new(typed)
}
