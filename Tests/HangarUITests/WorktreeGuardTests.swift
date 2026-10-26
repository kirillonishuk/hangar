import Exec
import Foundation
import Git
import Testing
@testable import HangarUI

/// The guard in front of `mv` + `rm -rf` (#59): only a linked worktree's top folder of this very repo goes; restore
/// never deletes a folder that may hold the user's files.
@Suite struct WorktreeGuardTests {
    /// Repo with linked worktree `x` (branch x) at `<repo>.worktrees/x`, which has a `sub` folder.
    private func make() async throws -> (TempRepo, String) {
        let t = try await TempRepo.offMain {
            let t = try TempRepo()
            try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
            _ = try t.git("worktree", "add", "-q", "-b", "x", t.worktrees + "/x", "main", in: t.repo)
            try FileManager.default.createDirectory(atPath: t.worktrees + "/x/sub", withIntermediateDirectories: true)
            try "s".write(toFile: t.worktrees + "/x/sub/s.txt", atomically: true, encoding: .utf8)
            return t
        }
        return (t, t.worktrees + "/x")
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    private func runners(_ t: TempRepo) throws -> [Runner] {
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        return [.local, .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path)]
    }

    /// (a) A folder inside a linked worktree is not the worktree.
    @Test func refusesSubfolderOfWorktree() async throws {
        let (t, wt) = try await make()
        defer { t.cleanup() }
        for runner in try runners(t) {
            let git = Git(repo: t.repo, runner: runner)
            await #expect(throws: (any Error).self) { try await removeWorktreeFolder(wt + "/sub", git: git, runner: runner) }
            #expect(exists(wt + "/sub/s.txt") && !exists(wt + "/sub.hangar-removing"))
        }
    }

    /// (b) A linked worktree of another repo is not this project's.
    @Test func refusesWorktreeOfAnotherRepo() async throws {
        let (t, _) = try await make()
        defer { t.cleanup() }
        let other = t.root + "/other", otherWt = t.root + "/other-wt"
        _ = try await t.git("init", "-q", "-b", "main", other, in: t.root)
        try await t.commit(file: "o.txt", on: "main", in: other)
        _ = try await t.git("worktree", "add", "-q", "-b", "y", otherWt, "main", in: other)
        for runner in try runners(t) {
            let git = Git(repo: t.repo, runner: runner)
            await #expect(throws: (any Error).self) { try await removeWorktreeFolder(otherWt, git: git, runner: runner) }
            #expect(exists(otherWt + "/o.txt") && !exists(otherWt + ".hangar-removing"))
        }
    }

    /// (c) A main folder that can't be resolved (missing, `~`) refuses instead of skipping the check.
    @Test func refusesWhenMainFolderUnresolvable() async throws {
        let (t, wt) = try await make()
        defer { t.cleanup() }
        for runner in try runners(t) {
            for main in [t.root + "/missing", "~/repo"] {
                let git = Git(repo: main, runner: runner)
                await #expect(throws: (any Error).self) { try await removeWorktreeFolder(wt, git: git, runner: runner) }
                #expect(exists(wt + "/sub/s.txt"))
            }
        }
    }

    /// (d) A symlink to the worktree removes the real folder; a symlink to a subfolder or a plain folder is refused.
    @Test func symlinkedWorktreeActsOnRealFolder() async throws {
        let (t, wt) = try await make()
        defer { t.cleanup() }
        let fm = FileManager.default
        let toSub = t.root + "/to-sub", toPlain = t.root + "/to-plain", plain = t.root + "/plain"
        try fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try "p".write(toFile: plain + "/p.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: toSub, withDestinationPath: wt + "/sub")
        try fm.createSymbolicLink(atPath: toPlain, withDestinationPath: plain)
        let git = Git(repo: t.repo, runner: .local)
        await #expect(throws: (any Error).self) { try await removeWorktreeFolder(toSub, git: git, runner: .local) }
        await #expect(throws: (any Error).self) { try await removeWorktreeFolder(toPlain, git: git, runner: .local) }
        #expect(exists(wt + "/sub/s.txt") && exists(plain + "/p.txt"))
        let link = t.root + "/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: wt)
        try await removeWorktreeFolder(link, git: git, runner: .local).value
        #expect(!exists(wt))
        #expect(!exists(wt + ".hangar-removing"))
    }

    /// The archived worktree is gone; the branch `x` stays.
    private func archived() async throws -> (TempRepo, String, Git) {
        let (t, wt) = try await make()
        let git = Git(repo: t.repo, runner: .local)
        try await removeWorktreeFolder(wt, git: git, runner: .local).value
        return (t, wt, git)
    }

    /// (e) A dangling `.git` symlink still counts as `.git`: nothing is deleted.
    @Test func restoreKeepsFolderWithDanglingGitLink() async throws {
        let (t, wt, git) = try await archived()
        defer { t.cleanup() }
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "mine".write(toFile: wt + "/notes.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: wt + "/.git", withDestinationPath: t.root + "/nowhere")
        let outcome = try await reviveWorktree(wt, branch: "x", git: git, runner: .local)
        #expect(outcome == .failed("\(wt) is not a valid worktree, left in place"))
        #expect(exists(wt + "/notes.txt"))
    }

    /// (e) A folder without `.git` whose name is not the branch's worktree name is left alone.
    @Test func restoreRefusesForeignFolderName() async throws {
        let (t, _, git) = try await archived()
        defer { t.cleanup() }
        let mine = t.root + "/mine"
        try FileManager.default.createDirectory(atPath: mine, withIntermediateDirectories: true)
        try "mine".write(toFile: mine + "/notes.txt", atomically: true, encoding: .utf8)
        let outcome = try await reviveWorktree(mine, branch: "x", git: git, runner: .local)
        guard case .failed = outcome else { Issue.record("\(outcome)"); return }
        #expect(exists(mine + "/notes.txt"))
    }

    /// (e) A non-empty folder without `.git` is kept as `<path>.hangar-orphan-<ts>`; the worktree is re-created.
    @Test func restoreKeepsNonEmptyFolderAsOrphan() async throws {
        let (t, wt, _) = try await archived()
        defer { t.cleanup() }
        for runner in try runners(t) {
            let git = Git(repo: t.repo, runner: runner)
            try? FileManager.default.removeItem(atPath: wt)
            _ = try await t.git("worktree", "prune", in: t.repo)
            try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
            try "mine".write(toFile: wt + "/notes.txt", atomically: true, encoding: .utf8)
            let outcome = try await reviveWorktree(wt, branch: "x", git: git, runner: runner)
            guard case .restoredKeeping(let orphan) = outcome else { Issue.record("\(outcome)"); return }
            #expect(orphan.hasPrefix(wt + ".hangar-orphan-"))
            #expect(exists(orphan + "/notes.txt"))
            #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt) == "x")
            try FileManager.default.removeItem(atPath: orphan)
        }
    }

    /// (e) An empty folder without `.git` simply goes.
    @Test func restoreRemovesEmptyFolder() async throws {
        let (t, wt, git) = try await archived()
        defer { t.cleanup() }
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        #expect(try await reviveWorktree(wt, branch: "x", git: git, runner: .local) == .restored)
        #expect(try await t.git("symbolic-ref", "--short", "HEAD", in: wt) == "x")
    }
}
