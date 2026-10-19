import Foundation
import Exec

public struct Branch: Equatable, Sendable {
    /// "origin/main" for remote branches, "main" for local ones.
    public var name: String
    public var isRemote: Bool
    public var lastCommit: Date

    public init(name: String, isRemote: Bool, lastCommit: Date) {
        self.name = name
        self.isRemote = isRemote
        self.lastCommit = lastCommit
    }
}

public struct GitError: Error, LocalizedError, Equatable, Sendable {
    public var args: [String]
    public var status: Int32
    /// Trimmed stderr of git.
    public var stderr: String

    /// git's own message; falls back to the command line when stderr is empty.
    public var errorDescription: String? {
        stderr.isEmpty ? "git \(args.joined(separator: " ")) exited \(status)" : stderr
    }
}

/// Thin wrapper over the `git` CLI. Every command is an argv array run through `Runner` with cwd = `repo`;
/// output is parsed from machine-readable formats only.
public struct Git: Sendable {
    private let repo: String
    private let runner: Runner

    public init(repo: String, runner: Runner = .local) {
        self.repo = repo
        self.runner = runner
    }

    // MARK: Probes (non-zero exit is an answer, not an error)

    public func isRepository() async -> Bool {
        guard let r = try? await runner.run(["git", "rev-parse", "--is-inside-work-tree"], repo) else { return false }
        return r.status == 0 && r.stdout.trimmed == "true"
    }

    public func hasCommits() async -> Bool {
        let r = try? await runner.run(["git", "rev-parse", "--verify", "--quiet", "HEAD"], repo)
        return r?.status == 0
    }

    public func isValidBranchName(_ name: String) async -> Bool {
        let r = try? await runner.run(["git", "check-ref-format", "--branch", name], repo)
        return r?.status == 0
    }

    // MARK: Branches

    /// nil = detached HEAD.
    public func currentBranch() async throws -> String? {
        try await probe(["symbolic-ref", "--quiet", "--short", "HEAD"])
    }

    /// origin/HEAD, else the first existing of origin/main, origin/master, main, master, else the current branch.
    /// nil when there are no commits.
    public func defaultBranch() async throws -> String? {
        guard await hasCommits() else { return nil }
        if let head = try await probe(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]),
           await refExists("refs/remotes/" + head) {
            return head
        }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            let ref = (candidate.hasPrefix("origin/") ? "refs/remotes/" : "refs/heads/") + candidate
            if await refExists(ref) { return candidate }
        }
        return try await currentBranch()
    }

    /// Remote branches first, then local; newest commit first within each group. Symbolic refs (origin/HEAD) are skipped.
    public func listBranches() async throws -> [Branch] {
        let out = try await exec([
            "for-each-ref", "--format=%(refname)%00%(symref)%00%(committerdate:unix)", "refs/remotes", "refs/heads",
        ])
        var branches: [Branch] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1].isEmpty, let ts = TimeInterval(parts[2]) else { continue }
            let ref = String(parts[0])
            let date = Date(timeIntervalSince1970: ts)
            if ref.hasPrefix("refs/remotes/") {
                branches.append(Branch(name: String(ref.dropFirst("refs/remotes/".count)), isRemote: true, lastCommit: date))
            } else if ref.hasPrefix("refs/heads/") {
                branches.append(Branch(name: String(ref.dropFirst("refs/heads/".count)), isRemote: false, lastCommit: date))
            }
        }
        return branches.sorted {
            if $0.isRemote != $1.isRemote { return $0.isRemote }
            return $0.lastCommit > $1.lastCommit
        }
    }

    public func deleteBranch(_ name: String) async throws {
        try await exec(["branch", "-d", "--", name])
    }

    // MARK: Remotes

    public func remotes() async throws -> [String] {
        try await exec(["remote"]).split(separator: "\n").map(String.init)
    }

    public func fetch(remote: String) async throws {
        try await exec(["fetch", "--quiet", "--", remote])
    }

    /// mtime of FETCH_HEAD in the common git dir (shared by worktrees); nil if never fetched.
    public func lastFetch() async -> Date? {
        guard let dir = try? await exec(["rev-parse", "--git-common-dir"]).trimmed, !dir.isEmpty else { return nil }
        let base = dir.hasPrefix("/") ? dir : repo + "/" + dir
        let attrs = try? FileManager.default.attributesOfItem(atPath: base + "/FETCH_HEAD")
        return attrs?[.modificationDate] as? Date
    }

    // MARK: Worktrees

    public func addWorktree(path: String, newBranch: String, base: String) async throws {
        try await exec(["worktree", "add", "--no-track", "-b", newBranch, "--", path, base])
    }

    public func removeWorktree(path: String, force: Bool) async throws {
        try await exec(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path])
    }

    public func pruneWorktrees() async throws {
        try await exec(["worktree", "prune"])
    }

    /// Any `status --porcelain` output, untracked files included (`worktree remove` refuses those too).
    public func isDirty(path: String) async throws -> Bool {
        let r = try await runner.run(["git", "status", "--porcelain"], path)
        guard r.status == 0 else { throw GitError(args: ["status", "--porcelain"], status: r.status, stderr: r.stderr.trimmed) }
        return !r.stdout.trimmed.isEmpty
    }

    // MARK: Helpers

    @discardableResult
    private func exec(_ args: [String]) async throws -> String {
        let r = try await runner.run(["git"] + args, repo)
        guard r.status == 0 else { throw GitError(args: args, status: r.status, stderr: r.stderr.trimmed) }
        return r.stdout
    }

    /// Runs a "checking" command: exit 0 -> trimmed stdout, non-zero -> nil.
    private func probe(_ args: [String]) async throws -> String? {
        let r = try await runner.run(["git"] + args, repo)
        guard r.status == 0 else { return nil }
        let s = r.stdout.trimmed
        return s.isEmpty ? nil : s
    }

    private func refExists(_ ref: String) async -> Bool {
        let r = try? await runner.run(["git", "rev-parse", "--verify", "--quiet", ref], repo)
        return r?.status == 0
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
