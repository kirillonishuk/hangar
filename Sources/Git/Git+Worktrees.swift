import Foundation

/// One entry of `git worktree list --porcelain`; the first one is the main checkout.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    /// nil when detached or bare.
    public var branch: String?
    /// Registered, but its folder is gone (`prunable`): not a place to work in.
    public var prunable: Bool

    public init(path: String, branch: String?, prunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.prunable = prunable
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

func parseWorktreeList(_ out: String) -> [WorktreeEntry] {
    var result: [WorktreeEntry] = []
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("worktree ") {
            result.append(WorktreeEntry(path: String(line.dropFirst("worktree ".count)), branch: nil))
        } else if line.hasPrefix("branch refs/heads/"), !result.isEmpty {
            result[result.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
        } else if line == "prunable" || line.hasPrefix("prunable "), !result.isEmpty {
            result[result.count - 1].prunable = true
        }
    }
    return result
}

extension Git {
    /// Every worktree of the repository, the main checkout first (`git worktree list --porcelain`).
    public func worktrees() async throws -> [WorktreeEntry] {
        parseWorktreeList(try await exec(["--no-optional-locks", "worktree", "list", "--porcelain"]))
    }
}
