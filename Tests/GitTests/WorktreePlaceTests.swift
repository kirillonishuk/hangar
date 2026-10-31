import Foundation
import Testing
@testable import Git

@Suite struct WorktreePlaceTests {
    private func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    private func place(_ t: TempRepo, _ path: String, _ branch: String) async throws -> WorktreePlace {
        worktreePlace(path: path, branch: branch, in: try await Git(repo: t.repo).worktrees()) { real($0) == real($1) }
    }

    @Test func parsesPorcelainWithPrunableAndDetached() {
        let out = """
        worktree /r
        HEAD 1111
        branch refs/heads/main

        worktree /r.worktrees/a
        HEAD 2222
        branch refs/heads/feat/a

        worktree /r.worktrees/gone
        HEAD 3333
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        worktree /r.worktrees/det
        HEAD 4444
        detached

        """
        #expect(parseWorktreeList(out) == [
            WorktreeEntry(path: "/r", branch: "main"),
            WorktreeEntry(path: "/r.worktrees/a", branch: "feat/a"),
            WorktreeEntry(path: "/r.worktrees/gone", branch: "gone", prunable: true),
            WorktreeEntry(path: "/r.worktrees/det", branch: nil),
        ])
    }

    @Test func placeRules() {
        let list = [WorktreeEntry(path: "/r", branch: "feat/x"),
                    WorktreeEntry(path: "/r.worktrees/x", branch: "feat/x"),
                    WorktreeEntry(path: "/r.worktrees/old", branch: "y", prunable: true)]
        #expect(worktreePlace(path: "/r.worktrees/x", branch: "other", in: list) == .inPlace)  // a switched branch is still in place
        #expect(worktreePlace(path: "/r/.claude/worktrees/x", branch: "feat/x", in: list) == .moved(to: "/r.worktrees/x"))
        // Prunable (folder deleted) is not in place; the main checkout is never the new place.
        #expect(worktreePlace(path: "/r.worktrees/old", branch: "y", in: list) == .missing)
        #expect(worktreePlace(path: "/gone", branch: "feat/x", in: [list[0]]) == .missing)
    }

    /// A remote path is compared as written, then resolved on the server: a symlinked stored path is in place, not moved.
    @Test func resolvedPathDecidesBeforeMoved() async {
        let list = [WorktreeEntry(path: "/srv/r", branch: "main"), WorktreeEntry(path: "/data/r.worktrees/x", branch: "x")]
        let place = await worktreePlace(path: "/home/u/r.worktrees/x", branch: "x", in: list) { p in
            p == "/home/u/r.worktrees/x" ? "/data/r.worktrees/x" : nil
        }
        #expect(place == .inPlace)
        // In place as written: no resolution at all.
        #expect(await worktreePlace(path: "/data/r.worktrees/x", branch: "x", in: list) { _ in Issue.record("resolved"); return nil } == .inPlace)
        #expect(await worktreePlace(path: "/gone", branch: "x", in: list) { _ in nil } == .moved(to: "/data/r.worktrees/x"))
    }

    @Test func movedOutOfMainRepoWhileOldFolderStays() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let old = t.repo + "/.claude/worktrees/feat-x"
        try t.git("worktree", "add", "-q", "-b", "feat/x", old, "main", in: t.repo)
        #expect(try await place(t, old, "feat/x") == .inPlace)

        let new = t.worktrees + "/feat-x"
        try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
        try t.git("worktree", "move", old, new, in: t.repo)
        // The old folder still exists inside the main checkout (an agent left a file there): git there answers as the main checkout.
        try FileManager.default.createDirectory(atPath: old + "/.claude", withIntermediateDirectories: true)
        try "x".write(toFile: old + "/.claude/.cc-writes", atomically: true, encoding: .utf8)
        #expect(try t.git("rev-parse", "--show-toplevel", in: old) == real(t.repo))
        #expect(try await place(t, old, "feat/x") == .moved(to: real(new)))
        #expect(try await place(t, new, "feat/x") == .inPlace)
    }

    @Test func deletedFolderIsMissingOrMoved() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let wt = t.worktrees + "/a"
        try t.git("worktree", "add", "-q", "-b", "a", wt, "main", in: t.repo)
        try FileManager.default.removeItem(atPath: wt)
        #expect(try await place(t, wt, "a") == .missing)
        // The branch is checked out again somewhere else: offered as the new place.
        try t.git("worktree", "prune", in: t.repo)
        let other = t.worktrees + "/b"
        try t.git("worktree", "add", "-q", other, "a", in: t.repo)
        #expect(try await place(t, wt, "a") == .moved(to: real(other)))
    }
}
