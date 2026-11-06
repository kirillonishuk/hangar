import Foundation
import Testing
@testable import Git

@Suite struct AgentWorktreeTests {
    private let list = [WorktreeEntry(path: "/r", branch: "main"),
                        WorktreeEntry(path: "/r/.claude/worktrees/aut-1076", branch: "aut-1076"),
                        WorktreeEntry(path: "/r.worktrees/feat", branch: "feat"),
                        WorktreeEntry(path: "/r.worktrees/gone", branch: "gone", prunable: true)]

    @Test func parsesLockedDetachedPrunable() {
        let out = """
        worktree /r
        HEAD 1111
        branch refs/heads/main

        worktree /r/.claude/worktrees/a
        HEAD 2222
        detached
        locked

        worktree /r/.claude/worktrees/b
        HEAD 3333
        branch refs/heads/b
        locked agent is working

        worktree /r.worktrees/gone
        HEAD 4444
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        #expect(parseWorktreeList(out) == [
            WorktreeEntry(path: "/r", branch: "main"),
            WorktreeEntry(path: "/r/.claude/worktrees/a", branch: nil, locked: true),
            WorktreeEntry(path: "/r/.claude/worktrees/b", branch: "b", locked: true, lockReason: "agent is working"),
            WorktreeEntry(path: "/r.worktrees/gone", branch: "gone", prunable: true),
        ])
    }

    @Test func claudeWorktreesDirIsHidden() {
        // Real porcelain shapes (autoselectMonorepo): locked agent copy, unlocked one with a renamed branch, a lead's copy, a chat copy.
        let out = """
        worktree /r
        HEAD 1111
        branch refs/heads/main

        worktree /r/.claude/worktrees/agent-a605b4d978ee110db
        HEAD 2222
        branch refs/heads/aut-1076-lead10-admin
        locked claude agent agent-a605b4d978ee110db (pid 95835 start Thu Nov  5 14:49:25 2026)

        worktree /r/.claude/worktrees/agent-a820a2326a0bbfb3c
        HEAD 3333
        branch refs/heads/aut-1076-lead07-web

        worktree /r/.claude/worktrees/aut-1076
        HEAD 4444
        branch refs/heads/kirillonishuk/aut-1076-epik-vitrina

        worktree /r/.claude/worktrees/aut-1076-admin
        HEAD 5555
        branch refs/heads/aut-1076-admin

        worktree /r.worktrees/x
        HEAD 6666
        branch refs/heads/x

        worktree /r/.claude/worktrees/agent-abc123
        HEAD 7777
        branch refs/heads/mine

        """
        let l = parseWorktreeList(out)
        #expect(l.map { isClaudeAgentWorktree($0, root: "/r") } == [false, true, true, false, false, false, false])
        // Nothing under .claude/worktrees is offered; the outside copy is.
        #expect(unusedWorktrees(l, used: []).map(\.path) == ["/r.worktrees/x"])
        #expect(unusedWorktrees(l, used: ["/r.worktrees/x"]).isEmpty)
        // Banner: never for agent-<hex>, kept for other copies there.
        #expect(otherWorktree(cwd: "/r/.claude/worktrees/agent-a820a2326a0bbfb3c/src", chatFolder: "/r", in: l) == nil)
        #expect(otherWorktree(cwd: "/r/.claude/worktrees/aut-1076-admin", chatFolder: "/r", in: l)?.branch == "aut-1076-admin")
        #expect(otherWorktree(cwd: "/r/.claude/worktrees/aut-1076", chatFolder: "/r", in: l)?.branch == "kirillonishuk/aut-1076-epik-vitrina")
    }

    @Test func claudeDirIsRelativeToRepoRoot() {
        // A repo that merely sits under a path containing .claude/worktrees is not "inside" it.
        let w = WorktreeEntry(path: "/p/.claude/worktrees/repo.worktrees/agent-a820a2326a0bbfb3c", branch: "b")
        #expect(!isClaudeAgentWorktree(w, root: "/p/.claude/worktrees/repo"))
        #expect(unusedWorktrees([WorktreeEntry(path: "/p/.claude/worktrees/repo", branch: "main"), w], used: []).count == 1)
        let norm: (String) -> String = { $0.replacingOccurrences(of: "/link", with: "/r") }
        #expect(isClaudeAgentWorktree(WorktreeEntry(path: "/link/.claude/worktrees/agent-a820a2326a0bbfb3c", branch: "b"), root: "/link", normalize: norm))
    }

    @Test func agentInAnotherWorktree() {
        // Main-folder chat; the agent entered a worktree nested in the project (its subfolder too).
        #expect(otherWorktree(cwd: "/r/.claude/worktrees/aut-1076", chatFolder: "/r", in: list)?.branch == "aut-1076")
        #expect(otherWorktree(cwd: "/r/.claude/worktrees/aut-1076/src", chatFolder: "/r", in: list)?.branch == "aut-1076")
        // A worktree chat whose agent went to a sibling copy.
        #expect(otherWorktree(cwd: "/r.worktrees/feat", chatFolder: "/r/.claude/worktrees/aut-1076", in: list)?.branch == "feat")
    }

    @Test func agentAtHomeOrUnrelated() {
        #expect(otherWorktree(cwd: "/r/src", chatFolder: "/r", in: list) == nil)  // a subfolder of its own checkout
        #expect(otherWorktree(cwd: "/r.worktrees/feat/a/b", chatFolder: "/r.worktrees/feat", in: list) == nil)
        #expect(otherWorktree(cwd: "/tmp/elsewhere", chatFolder: "/r", in: list) == nil)  // not this repository
        #expect(otherWorktree(cwd: "/r", chatFolder: "/r.worktrees/feat", in: list) == nil)  // the main checkout is never offered
        #expect(otherWorktree(cwd: "/r.worktrees/gone", chatFolder: "/r", in: list) == nil)  // prunable
        #expect(otherWorktree(cwd: "/rr/x", chatFolder: "/r", in: list) == nil)  // a prefix is not a parent
        // A project in a subfolder of the repository: still the main checkout.
        #expect(otherWorktree(cwd: "/r/packages/app/src", chatFolder: "/r/packages/app", in: list) == nil)
    }

    @Test func normalizedPathsCompare() {
        let norm: (String) -> String = { $0.replacingOccurrences(of: "/link", with: "/r") }
        #expect(otherWorktree(cwd: "/link/.claude/worktrees/aut-1076", chatFolder: "/link", in: list, normalize: norm)?.branch == "aut-1076")
        #expect(otherWorktree(cwd: "/link/src", chatFolder: "/r", in: list, normalize: norm) == nil)
    }

    @Test func shortChatNames() {
        #expect(shortChatName(branch: "someone/aut-1076-epik-vitrina") == "aut-1076")
        #expect(shortChatName(branch: "feat/claude-md-refactor") == "claude-md-refactor")
        #expect(shortChatName(branch: "main") == "main")
        #expect(shortChatName(branch: "a/b/AUT-12") == "AUT-12")
        #expect(shortChatName(branch: "aut-1076-epik") == "aut-1076")
        #expect(shortChatName(branch: "aut-1076") == "aut-1076")
        #expect(shortChatName(branch: "release-2026-11") == "release-2026-11")
        #expect(shortChatName(branch: "v1-2-3") == "v1-2-3")
    }

    @Test func spareAndBranch() {
        #expect(unusedWorktrees(list, used: []).map(\.path) == ["/r.worktrees/feat"])  // not main, prunable or under .claude/worktrees
        #expect(unusedWorktrees(list, used: ["/r.worktrees/feat"]).isEmpty)
        #expect(registeredBranch(at: "/r.worktrees/feat", in: list) == "feat")
        #expect(registeredBranch(at: "/r", in: list) == nil)
        #expect(registeredBranch(at: "/r.worktrees/gone", in: list) == nil)
    }

    @Test func nestedAndExcludeLines() {
        #expect(nestedWorktrees(in: "/r", list: list) == [".claude/worktrees/aut-1076"])
        #expect(nestedWorktrees(in: "/r/.claude/worktrees/aut-1076", list: list) == [])
        #expect(excludeLines(for: [".claude/worktrees/a", ".claude/worktrees/b", "wt"]) == ["/.claude/worktrees/", "/wt/"])
    }

    @Test func checkIgnoreAndExcludeOnlyOnRequest() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("worktree", "add", "-q", "-b", "aut", t.repo + "/.claude/worktrees/aut", "main", in: t.repo)
        let git = Git(repo: t.repo)
        let nested = nestedWorktrees(in: t.repo, list: try await git.worktrees()) { realpath($0, nil).map { p in defer { free(p) }; return String(cString: p) } ?? $0 }
        #expect(nested == [".claude/worktrees/aut"])
        #expect(try await git.notIgnored(nested) == nested)
        // Reading never wrote anything.
        let exclude = t.repo + "/.git/info/exclude"
        let before = try? String(contentsOfFile: exclude, encoding: .utf8)
        _ = try await git.worktrees()
        #expect((try? String(contentsOfFile: exclude, encoding: .utf8)) == before)
        // The click: the shown line, once, after a file without a trailing newline.
        try "# mine".write(toFile: exclude, atomically: true, encoding: .utf8)
        let file = try await git.appendToExclude(excludeLines(for: nested))
        _ = try await git.appendToExclude(excludeLines(for: nested))
        #expect(file.hasSuffix("info/exclude"))
        #expect(try String(contentsOfFile: exclude, encoding: .utf8) == "# mine\n/.claude/worktrees/\n")
        #expect(try await git.notIgnored(nested) == [])
        #expect(try t.git("status", "--porcelain", in: t.repo) == "")
    }
}
