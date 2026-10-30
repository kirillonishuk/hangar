import Foundation
import Testing
import Exec
@testable import Git

@Suite struct BranchSwitchTests {
    @Test func headIsBranchUnbornOrShortHash() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        #expect(try await g.head() == .branch("main"))
        let short = try t.git("rev-parse", "--short", "HEAD", in: t.repo)
        try t.git("checkout", "-q", "--detach", in: t.repo)
        #expect(try await g.head() == .detached(short))
        #expect(try await g.head()?.title == short)

        let e = try TempRepo(emptyWithBranch: "trunk"); defer { e.cleanup() }
        #expect(try await Git(repo: e.repo).head() == .branch("trunk"))
        #expect(try await Git(repo: e.base).head() == nil)
    }

    @Test func switchesLocalBranchOnlyWhenClean() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try t.git("branch", "feat", in: t.repo)
        try "x".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: t.repo + "/new.txt", atomically: true, encoding: .utf8)
        await #expect(throws: BranchSwitchError.dirty(files: 2)) { try await g.switchBranch(to: "feat", isRemote: false) }
        #expect(try await g.currentBranch() == "main")
        // The current branch is a no-op, changes or not.
        try await g.switchBranch(to: "main", isRemote: false)

        try t.git("checkout", "-q", "--", "a.txt", in: t.repo)
        try FileManager.default.removeItem(atPath: t.repo + "/new.txt")
        try await g.switchBranch(to: "feat", isRemote: false)
        #expect(try await g.currentBranch() == "feat")
        // A dash-leading name is a branch, not an option.
        try t.git("update-ref", "refs/heads/-x", "HEAD", in: t.repo)  // git branch refuses it; another tool may not
        try await g.switchBranch(to: "-x", isRemote: false)
        #expect(try await g.currentBranch() == "-x")
    }

    @Test func remoteBranchTracksOrReusesLocal() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try t.git("branch", "feat/x", in: t.repo)
        try t.commit(file: "f.txt", on: "feat/x")
        try t.pushBranch("feat/x")
        try t.git("checkout", "-q", "main", in: t.repo)
        try t.git("branch", "-q", "-D", "feat/x", in: t.repo)

        try await g.switchBranch(to: "origin/feat/x", isRemote: true)
        #expect(try await g.currentBranch() == "feat/x")
        #expect(try t.git("rev-parse", "--abbrev-ref", "feat/x@{upstream}", in: t.repo) == "origin/feat/x")

        // The local branch exists: switch to it, nothing new.
        try t.git("checkout", "-q", "main", in: t.repo)
        try await g.switchBranch(to: "origin/feat/x", isRemote: true)
        #expect(try await g.currentBranch() == "feat/x")
    }

    @Test func refusesBranchOfAnotherWorktree() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let wt = t.worktrees + "/other"
        try t.git("worktree", "add", "-q", "-b", "other", wt, "main", in: t.repo)
        do {
            try await g.switchBranch(to: "other", isRemote: false)
            Issue.record("expected checkedOutElsewhere")
        } catch BranchSwitchError.checkedOutElsewhere(let branch, let path) {
            #expect(branch == "other")
            #expect(realPath(path) == realPath(wt))
        }
        #expect(try await g.currentBranch() == "main")
        // From the worktree, the main checkout's branch is taken too.
        await #expect(throws: BranchSwitchError.self) { try await Git(repo: wt).switchBranch(to: "main", isRemote: false) }
        #expect(try await g.checkedOutBranches().keys.sorted() == ["main", "other"])
    }

    @Test func createsBranchAtHeadCarryingChanges() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        for bad in ["a b", "-x", "@{-1}", "HEAD", "x..y", ""] {
            await #expect(throws: BranchSwitchError.invalidName, "\(bad)") { try await g.createBranch(bad) }
        }
        await #expect(throws: BranchSwitchError.alreadyExists("main")) { try await g.createBranch("main") }

        try "x".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        await #expect(throws: BranchSwitchError.dirty(files: 1)) { try await g.createBranch("other", from: "origin/main") }
        try await g.createBranch("feat/new")
        #expect(try await g.currentBranch() == "feat/new")
        #expect(try await g.uncommittedCount() == 1)
    }

    @Test func createsBranchFromStartWithoutUpstream() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let base = try t.git("rev-parse", "HEAD", in: t.repo)
        try t.commit(file: "b.txt", on: "main")
        try await g.createBranch("fix", from: "origin/main")
        #expect(try await g.currentBranch() == "fix")
        #expect(try t.git("rev-parse", "HEAD", in: t.repo) == base)
        #expect((try? t.git("rev-parse", "--abbrev-ref", "fix@{upstream}", in: t.repo)) == nil)
    }

    @Test func switchAndCreateOverSSH() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let g = Git(repo: t.repo, runner: .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path))
        try t.git("branch", "feat", in: t.repo)
        try await g.switchBranch(to: "feat", isRemote: false)
        #expect(try await g.head() == .branch("feat"))
        try await g.createBranch("ssh/new", from: "main")
        #expect(try await g.head() == .branch("ssh/new"))
        try "x".write(toFile: t.repo + "/it's.txt", atomically: true, encoding: .utf8)
        await #expect(throws: BranchSwitchError.dirty(files: 1)) { try await g.switchBranch(to: "main", isRemote: false) }
        #expect(FakeSSH.calls(ssh.log).count >= 6)
    }
}

@Suite struct BranchSwitchSafetyTests {
    /// main ignores `.env` and `build/`; `other` (also on origin) tracks `.env` and `build/keep.txt`.
    private func ignoredFixture() throws -> TempRepo {
        let t = try TempRepo()
        try t.git("branch", "other", in: t.repo)
        try t.commit(file: ".env", on: "other")
        try FileManager.default.createDirectory(atPath: t.repo + "/build", withIntermediateDirectories: true)
        try t.commit(file: "build/keep.txt", on: "other")
        try t.pushBranch("other")
        try t.git("checkout", "-q", "main", in: t.repo)
        try ".env\nbuild/\n".write(toFile: t.repo + "/.gitignore", atomically: true, encoding: .utf8)
        try t.git("add", ".gitignore", in: t.repo)
        try t.git("commit", "-q", "-m", "ignore", in: t.repo)
        return t
    }

    @Test func refusesToOverwriteIgnoredFile() async throws {
        let t = try ignoredFixture(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try "SECRET".write(toFile: t.repo + "/.env", atomically: true, encoding: .utf8)
        #expect(try await g.uncommittedCount() == 0)
        await #expect(throws: BranchSwitchError.wouldOverwriteIgnored([".env"])) { try await g.switchBranch(to: "other", isRemote: false) }
        try t.git("branch", "-q", "-D", "other", in: t.repo)
        await #expect(throws: BranchSwitchError.wouldOverwriteIgnored([".env"])) { try await g.switchBranch(to: "origin/other", isRemote: true) }
        await #expect(throws: BranchSwitchError.wouldOverwriteIgnored([".env"])) { try await g.createBranch("n", from: "origin/other") }
        #expect(try String(contentsOfFile: t.repo + "/.env", encoding: .utf8) == "SECRET")
        #expect(try await g.currentBranch() == "main")
    }

    @Test func ignoredFolderBlocksOnlyFilesThatExist() async throws {
        let t = try ignoredFixture(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try FileManager.default.createDirectory(atPath: t.repo + "/build", withIntermediateDirectories: true)
        try "local".write(toFile: t.repo + "/build/keep.txt", atomically: true, encoding: .utf8)
        try "obj".write(toFile: t.repo + "/build/out.o", atomically: true, encoding: .utf8)
        await #expect(throws: BranchSwitchError.wouldOverwriteIgnored(["build/keep.txt"])) { try await g.switchBranch(to: "other", isRemote: false) }
        try FileManager.default.removeItem(atPath: t.repo + "/build/keep.txt")
        try await g.switchBranch(to: "other", isRemote: false)
        #expect(try await g.currentBranch() == "other")
        #expect(FileManager.default.fileExists(atPath: t.repo + "/build/out.o"))
    }

    @Test func countIgnoresConfigThatHidesChanges() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try t.git("config", "status.showUntrackedFiles", "no", in: t.repo)
        try FileManager.default.createDirectory(atPath: t.repo + "/new", withIntermediateDirectories: true)
        try "x".write(toFile: t.repo + "/new/a.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: t.repo + "/new/b.txt", atomically: true, encoding: .utf8)
        #expect(try await g.uncommittedCount() == 2)
        try FileManager.default.removeItem(atPath: t.repo + "/new")

        try t.git("submodule", "-q", "add", t.origin, "sub", in: t.repo)
        try t.git("config", "-f", ".gitmodules", "submodule.sub.ignore", "dirty", in: t.repo)
        try t.git("add", ".gitmodules", in: t.repo)
        try t.git("commit", "-q", "-m", "sub", in: t.repo)
        #expect(try await g.uncommittedCount() == 0)
        try "changed".write(toFile: t.repo + "/sub/a.txt", atomically: true, encoding: .utf8)
        #expect(try t.git("status", "--porcelain", in: t.repo).isEmpty)
        #expect(try await g.uncommittedCount() == 1)
        try t.git("branch", "other", in: t.repo)
        await #expect(throws: BranchSwitchError.dirty(files: 1)) { try await g.switchBranch(to: "other", isRemote: false) }
    }

    @Test func refusesDuringUnfinishedOperations() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try t.git("branch", "other", in: t.repo)
        #expect(try await g.operationInProgress() == nil)

        try t.git("bisect", "start", in: t.repo)
        await #expect(throws: BranchSwitchError.operationInProgress("bisect")) { try await g.switchBranch(to: "other", isRemote: false) }
        await #expect(throws: BranchSwitchError.operationInProgress("bisect")) { try await g.createBranch("n") }
        try t.git("bisect", "reset", in: t.repo)

        // A rebase stopped on a clean tree: git itself would only print «cannot switch branch while rebasing».
        try t.commit(file: "b.txt", on: "main")
        _ = try? t.git("rebase", "-q", "--exec", "false", "HEAD~1", in: t.repo)
        #expect(try await g.uncommittedCount() == 0)
        await #expect(throws: BranchSwitchError.operationInProgress("rebase")) { try await g.switchBranch(to: "other", isRemote: false) }
        try t.git("rebase", "--abort", in: t.repo)

        // Conflicting merge and cherry-pick.
        try "main".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        try t.git("commit", "-q", "-am", "main a", in: t.repo)
        try t.git("checkout", "-q", "other", in: t.repo)
        try "other".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        try t.git("commit", "-q", "-am", "other a", in: t.repo)
        _ = try? t.git("merge", "-q", "main", in: t.repo)
        await #expect(throws: BranchSwitchError.operationInProgress("merge")) { try await g.switchBranch(to: "main", isRemote: false) }
        try t.git("merge", "--abort", in: t.repo)
        _ = try? t.git("cherry-pick", "main", in: t.repo)
        await #expect(throws: BranchSwitchError.operationInProgress("cherry-pick")) { try await g.switchBranch(to: "main", isRemote: false) }
        try t.git("cherry-pick", "--abort", in: t.repo)
        #expect(try await g.operationInProgress() == nil)
    }
}

private func realPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
