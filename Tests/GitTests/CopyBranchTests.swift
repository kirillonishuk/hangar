import Foundation
import Testing
@testable import Git

/// «Ветка копии»: a new branch, or an existing local / remote-only one checked out as itself (decision HD-169).
@Suite struct CopyBranchTests {
    private let branches = [
        Branch(name: "origin/main", isRemote: true, lastCommit: .distantPast),
        Branch(name: "origin/JS-1 dubai", isRemote: true, lastCommit: .distantPast),
        Branch(name: "origin/fix", isRemote: true, lastCommit: .distantPast),
        Branch(name: "upstream/only-up", isRemote: true, lastCommit: .distantPast),
        Branch(name: "main", isRemote: false, lastCommit: .distantPast),
        Branch(name: "fix", isRemote: false, lastCommit: .distantPast),
    ]
    private let remotes = ["origin", "upstream"]

    private func classify(_ typed: String, checkedOut: [String: String] = ["main": "/p"]) -> CopyBranch {
        classifyCopyBranch(typed, branches: branches, remotes: remotes, checkedOut: checkedOut)
    }

    @Test func classifies() {
        #expect(classify("") == .new(""))
        #expect(classify("feat/x") == .new("feat/x"))
        #expect(classify("fix") == .local("fix"))
        // A remote one with a local branch of its name is that local branch.
        #expect(classify("origin/fix") == .local("fix"))
        #expect(classify("origin/JS-1 dubai") == .remote(local: "JS-1 dubai", upstream: "origin/JS-1 dubai"))
        #expect(classify("JS-1 dubai") == .remote(local: "JS-1 dubai", upstream: "origin/JS-1 dubai"))
        #expect(classify("only-up") == .remote(local: "only-up", upstream: "upstream/only-up"))
        #expect(classify("main") == .checkedOut("main", path: "/p"))
        #expect(classify("origin/main") == .checkedOut("main", path: "/p"))
        #expect(classify("fix", checkedOut: ["fix": "/p.worktrees/fix"]) == .checkedOut("fix", path: "/p.worktrees/fix"))
        #expect(classify("origin/JS-1 dubai").name == "JS-1 dubai")
    }

    /// `git worktree add --track -b x <path> origin/x`: `git push` / `git pull` of the copy go to `origin/x`.
    @Test func remoteOnlyBranchIsTracked() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "colleague", in: t.repo)
        try t.commit(file: "c.txt", on: "colleague")
        try t.git("push", "-q", "origin", "colleague", in: t.repo)
        try t.git("checkout", "-q", "main", in: t.repo)
        try t.git("branch", "-q", "-D", "colleague", in: t.repo)
        let path = t.worktrees + "/colleague"
        try await Git(repo: t.repo).addWorktree(path: path, newBranch: "colleague", base: "origin/colleague", track: true)
        #expect(try await Git(repo: path).currentBranch() == "colleague")
        #expect(FileManager.default.fileExists(atPath: path + "/c.txt"))
        #expect(try t.git("rev-parse", "--abbrev-ref", "colleague@{upstream}", in: t.repo).trimmingCharacters(in: .whitespacesAndNewlines)
                == "origin/colleague")
    }

    @Test func localBranchIsCheckedOutAsIs() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("branch", "fix", in: t.repo)
        let path = t.worktrees + "/fix"
        try await Git(repo: t.repo).addWorktree(path: path, existingBranch: "fix")
        #expect(try await Git(repo: path).currentBranch() == "fix")
        #expect(try await Git(repo: t.repo).checkedOutBranches()["fix"] != nil)
    }
}
