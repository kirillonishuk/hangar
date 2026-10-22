import Foundation
import Testing
import Exec
@testable import Git

@Suite struct GitTests {
    @Test func defaultBranchFromOriginHead() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        #expect(try await Git(repo: t.repo).defaultBranch() == "origin/main")
    }

    @Test func defaultBranchFallsBackWithoutOriginHead() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("remote", "set-head", "origin", "-d", in: t.repo)
        #expect(try await Git(repo: t.repo).defaultBranch() == "origin/main")

        let t2 = try TempRepo(emptyWithBranch: "master"); defer { t2.cleanup() }
        try t2.commit(file: "a.txt", on: "master")
        #expect(try await Git(repo: t2.repo).defaultBranch() == "master")
    }

    @Test func emptyRepoHasNoDefaultBranch() async throws {
        let t = try TempRepo(emptyWithBranch: "main"); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        #expect(try await g.defaultBranch() == nil)
        #expect(await g.hasCommits() == false)
        #expect(try await g.listBranches().isEmpty)
    }

    @Test func listBranchesRemoteFirstWithoutHead() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let now = Int(Date().timeIntervalSince1970)
        try t.git("checkout", "-q", "-b", "release/2.4", in: t.repo)
        try t.commit(file: "r.txt", on: "release/2.4", date: now - 1000)
        try t.pushBranch("release/2.4")
        try t.git("checkout", "-q", "-b", "refactor-db", "main", in: t.repo)
        try t.commit(file: "d.txt", on: "refactor-db", date: now + 60)
        let list = try await Git(repo: t.repo).listBranches()
        let names = list.map(\.name)
        #expect(names == ["origin/main", "origin/release/2.4", "refactor-db", "main", "release/2.4"])
        #expect(list.map { $0.isRemote } == [true, true, false, false, false])
        #expect(list.allSatisfy { $0.lastCommit.timeIntervalSince1970 > 0 })
    }

    @Test func fetchGetsNewRemoteBranch() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let second = t.base + "/second"
        try t.git("clone", "-q", t.origin, second, in: t.base)
        try t.git("checkout", "-q", "-b", "feat/x", in: second)
        try t.commit(file: "x.txt", on: "feat/x", in: second)
        try t.git("push", "-q", "origin", "feat/x", in: second)
        let g = Git(repo: t.repo)
        #expect(try await g.listBranches().map(\.name).contains("origin/feat/x") == false)
        let before = Date()
        try await g.fetch(remote: "origin")
        #expect(try await g.listBranches().map(\.name).contains("origin/feat/x"))
        let last = try #require(await g.lastFetch())
        #expect(last >= before.addingTimeInterval(-1))
    }

    @Test func failedFetchTruncatesFetchHeadAndLastFetchIsNil() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try await g.fetch(remote: "origin")
        #expect(await g.lastFetch() != nil)
        try t.git("remote", "set-url", "origin", "/nonexistent/x.git", in: t.repo)
        _ = try? await g.fetch(remote: "origin")
        let size = try FileManager.default.attributesOfItem(atPath: t.repo + "/.git/FETCH_HEAD")[.size] as? Int
        #expect(size == 0)
        #expect(await g.lastFetch() == nil)
    }

    @Test func fetchFailureCarriesStderr() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("remote", "set-url", "origin", "/nonexistent/x.git", in: t.repo)
        do {
            try await Git(repo: t.repo).fetch(remote: "origin")
            Issue.record("expected GitError")
        } catch let e as GitError {
            #expect(e.status != 0)
            #expect(!e.stderr.isEmpty)
            #expect(e.args.contains("fetch"))
        }
    }

    @Test func addWorktreeCreatesBranchWithoutUpstream() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let path = t.worktrees + "/fix-login"
        try await Git(repo: t.repo).addWorktree(path: path, newBranch: "fix-login", base: "origin/main")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await Git(repo: path).currentBranch() == "fix-login")
        let merge = (try? t.git("config", "--get", "branch.fix-login.merge", in: t.repo)) ?? ""
        #expect(merge.isEmpty)
    }

    @Test func addWorktreeExistingBranchFails() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try await g.addWorktree(path: t.worktrees + "/fix-login", newBranch: "fix-login", base: "origin/main")
        do {
            try await g.addWorktree(path: t.worktrees + "/fix-login-2", newBranch: "fix-login", base: "origin/main")
            Issue.record("expected GitError")
        } catch let e as GitError {
            #expect(e.stderr.contains("already exists"))
        }
        // The pre-existing branch is not cleaned up.
        #expect(try t.git("branch", "--list", "fix-login", in: t.repo).contains("fix-login"))
    }

    @Test func failedAddWorktreeRemovesNewBranch() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let path = t.worktrees + "/busy"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "x".write(toFile: path + "/keep.txt", atomically: true, encoding: .utf8)
        do {
            try await Git(repo: t.repo).addWorktree(path: path, newBranch: "busy", base: "origin/main")
            Issue.record("expected GitError")
        } catch let e as GitError {
            #expect(e.stderr.contains("already exists"))
        }
        #expect(try t.git("branch", "--list", "busy", in: t.repo).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path + "/keep.txt"))
    }

    @Test func branchNameValidation() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        #expect(await g.isValidBranchName("feat/ok"))
        for bad in ["bad..name", "with space", "end.", ""] {
            #expect(await g.isValidBranchName(bad) == false, "\(bad)")
        }
    }

    @Test func dirtyAndRemove() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let clean = t.worktrees + "/clean"
        try await g.addWorktree(path: clean, newBranch: "clean", base: "origin/main")
        #expect(try await g.isDirty(path: clean) == false)
        try await g.removeWorktree(path: clean, force: false)
        #expect(!FileManager.default.fileExists(atPath: clean))

        let dirty = t.worktrees + "/dirty"
        try await g.addWorktree(path: dirty, newBranch: "dirty", base: "origin/main")
        try "x".write(toFile: dirty + "/untracked.txt", atomically: true, encoding: .utf8)
        #expect(try await g.isDirty(path: dirty))
        await #expect(throws: GitError.self) { try await g.removeWorktree(path: dirty, force: false) }
        #expect(FileManager.default.fileExists(atPath: dirty))
        try await g.removeWorktree(path: dirty, force: true)
        #expect(!FileManager.default.fileExists(atPath: dirty))
    }

    @Test func deleteBranchRefusesUnmerged() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        try t.git("checkout", "-q", "-b", "unmerged", in: t.repo)
        try t.commit(file: "u.txt", on: "unmerged")
        try t.git("checkout", "-q", "main", in: t.repo)
        await #expect(throws: GitError.self) { try await g.deleteBranch("unmerged") }
        #expect(try await g.listBranches().map(\.name).contains("unmerged"))

        try t.git("branch", "merged", in: t.repo)
        try await g.deleteBranch("merged")
        #expect(try await g.listBranches().map(\.name).contains("merged") == false)
    }

    @Test func pruneForgetsDeletedFolder() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let path = t.worktrees + "/gone"
        try await g.addWorktree(path: path, newBranch: "gone", base: "origin/main")
        try FileManager.default.removeItem(atPath: path)
        try await g.pruneWorktrees()
        let list = try t.git("worktree", "list", "--porcelain", in: t.repo)
        #expect(!list.contains("gone"))
    }

    @Test func nonRepository() async throws {
        let dir = NSTemporaryDirectory() + "hangar-git-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(try await Git(repo: dir).isRepository() == false)
    }

    @Test func gitErrorDescriptionIsStderr() {
        let e = GitError(args: ["fetch", "origin"], status: 128, stderr: "fatal: boom")
        #expect(e.localizedDescription == "fatal: boom")
        let empty = GitError(args: ["fetch", "origin"], status: 1, stderr: "")
        #expect(empty.localizedDescription == "git fetch origin exited 1")
    }

    @Test func dashLeadingNamesAreNotParsedAsOptions() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        // Without `--` git reads these as options ("unknown switch"/"unknown option") instead of treating them as names.
        // Branch "-x" (only creatable via update-ref) is deleted.
        try t.git("update-ref", "refs/heads/-x", "HEAD", in: t.repo)
        try await g.deleteBranch("-x")
        #expect(try await g.listBranches().map(\.name).contains("-x") == false)
        do { try await g.deleteBranch("-nope"); Issue.record("expected GitError") }
        catch let e as GitError { #expect(e.stderr.contains("not found")) }
        // Remote "-r" (only creatable via config) is fetched.
        try t.git("config", "remote.-r.url", t.origin, in: t.repo)
        try t.git("config", "remote.-r.fetch", "+refs/heads/*:refs/remotes/-r/*", in: t.repo)
        try await g.fetch(remote: "-r")
        #expect(try await g.listBranches().map(\.name).contains("-r/main"))
        // Dash-leading relative worktree path is created and removed (cwd = repo).
        try await g.addWorktree(path: "-wt", newBranch: "dash-wt", base: "origin/main")
        #expect(FileManager.default.fileExists(atPath: t.repo + "/-wt"))
        try await g.removeWorktree(path: "-wt", force: false)
        #expect(!FileManager.default.fileExists(atPath: t.repo + "/-wt"))
        do { try await g.removeWorktree(path: "-nope", force: false); Issue.record("expected GitError") }
        catch let e as GitError { #expect(e.stderr.contains("is not a working tree")) }
    }
    @Test func gitOverSSH() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let remote = Git(repo: t.repo, runner: .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path))
        let local = Git(repo: t.repo)
        try "x".write(toFile: t.repo + "/new it's.txt", atomically: true, encoding: .utf8)
        #expect(try await remote.currentBranch() == "main")
        #expect(try await remote.currentBranch() == local.currentBranch())
        #expect(try await remote.status() == local.status())
        #expect(await remote.lastFetch() == nil)
        try await local.fetch(remote: "origin")
        try "x".write(toFile: t.repo + "/.git/FETCH_HEAD", atomically: true, encoding: .utf8)
        let mtime = try #require(FileManager.default.attributesOfItem(atPath: t.repo + "/.git/FETCH_HEAD")[.modificationDate] as? Date)
        let got = try #require(await remote.lastFetch())
        #expect(abs(got.timeIntervalSince(mtime)) <= 1)
        #expect(FakeSSH.calls(ssh.log).count >= 4)
    }

    @Test func lastFetchLocalUsesRunner() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        #expect(await g.lastFetch() == nil)
        try "".write(toFile: t.repo + "/.git/FETCH_HEAD", atomically: true, encoding: .utf8)
        #expect(await g.lastFetch() == nil)
    }
}
