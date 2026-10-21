import Foundation
import Testing
import Exec
@testable import Git

@Suite struct ChangesTests {
    private func write(_ t: TempRepo, _ path: String, _ text: String) throws {
        let full = t.repo + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// `feat` from `main`: c.txt committed there (3 lines), a.txt modified and u.txt untracked in the working tree.
    private func featRepo() throws -> TempRepo {
        let t = try TempRepo()
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try write(t, "c.txt", "1\n2\n3\n")
        try t.git("add", "c.txt", in: t.repo); try t.git("commit", "-q", "-m", "c", in: t.repo)
        try write(t, "a.txt", "changed\n")
        return t
    }

    @Test func baseVsUncommitted() async throws {
        let t = try featRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let b = try await g.changedFiles(.base("origin/main"))
        #expect(b.mode == .base("origin/main") && !b.baseMissing && !b.truncated)
        #expect(Set(b.files.map(\.path)) == ["c.txt", "a.txt"])
        let c = b.files.first { $0.path == "c.txt" }!
        #expect(c.change == .added && c.added == 3 && c.deleted == 0)
        #expect(b.from == (try t.git("merge-base", "HEAD", "origin/main", in: t.repo)))
        let u = try await g.changedFiles(.uncommitted)
        #expect(u.files.map(\.path) == ["a.txt"])
        #expect(u.from == "HEAD")
    }

    /// The inspector passes its own `status` so one load runs `git status` once.
    @Test func reusesGivenStatus() async throws {
        let t = try featRepo(); defer { t.cleanup() }
        try write(t, "u.txt", "x\n")
        let g = Git(repo: t.repo)
        let st = try await g.status()
        let given = try await g.changedFiles(.uncommitted, status: st)
        #expect(given == (try await g.changedFiles(.uncommitted)))
        let fake = StatusResult(entries: [StatusEntry(path: "other.txt", change: .untracked)], truncated: true)
        let used = try await g.changedFiles(.uncommitted, status: fake)
        #expect(used.files.map(\.path) == ["a.txt", "other.txt"] && used.truncated)
    }

    @Test func untrackedInBothModes() async throws {
        let t = try featRepo(); defer { t.cleanup() }
        try write(t, "u.txt", "x\ny\n")
        let g = Git(repo: t.repo)
        for mode in [DiffMode.base("origin/main"), .uncommitted] {
            let cs = try await g.changedFiles(mode)
            let u = try #require(cs.files.first { $0.path == "u.txt" })
            #expect(u.change == .untracked && u.added == nil && u.deleted == nil)
            let d = try await g.diff(file: u, from: cs.from)
            guard case .text(let h, _, _) = d else { Issue.record("not text"); return }
            #expect(h.count == 1 && h[0].header.hasPrefix("@@ -0,0 +1,2 @@"))
        }
    }

    /// A file literally named `HEAD`: without `--` after the rev git calls the argument ambiguous.
    @Test func fileNamedLikeTheRev() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "HEAD", "one\n")
        try t.git("add", "HEAD", in: t.repo); try t.git("commit", "-q", "-m", "h", in: t.repo)
        try write(t, "HEAD", "two\n")
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        let f = try #require(cs.files.first { $0.path == "HEAD" })
        #expect(f.change == .modified && f.added == 1 && f.deleted == 1)
        guard case .text(let h, _, _) = try await g.diff(file: f, from: cs.from) else { Issue.record("not text"); return }
        #expect(h.count == 1)
    }

    /// `git rm --cached x`: deleted in `diff HEAD` and untracked in status — listed once (as deleted).
    @Test func removedFromIndexListedOnce() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("rm", "-q", "--cached", "a.txt", in: t.repo)
        let cs = try await Git(repo: t.repo).changedFiles(.uncommitted)
        #expect(cs.files.filter { $0.path == "a.txt" }.map(\.change) == [.deleted])
    }

    @Test func renameWithSpaces() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "a.txt", "l1\nl2\nl3\nl4\nl5\n")
        try t.git("add", "a.txt", in: t.repo); try t.git("commit", "-q", "-m", "x", in: t.repo)
        try FileManager.default.createDirectory(atPath: t.repo + "/dir с пробелом", withIntermediateDirectories: true)
        try t.git("mv", "a.txt", "dir с пробелом/b.txt", in: t.repo)
        try write(t, "dir с пробелом/b.txt", "l1\nl2\nL3\nl4\nl5\n")
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        let f = try #require(cs.files.first)
        #expect(cs.files.count == 1 && f.change == .renamed && f.path == "dir с пробелом/b.txt" && f.origPath == "a.txt")
        #expect(f.added == 1 && f.deleted == 1)
        guard case .text(let h, _, _) = try await g.diff(file: f, from: cs.from) else { Issue.record("not text"); return }
        #expect(h.count == 1)
        #expect(h[0].lines.filter { $0.kind != .context }.map(\.text) == ["l3", "L3"])
    }

    @Test func diffStates() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "m.sh", "echo\n"); try write(t, "gone.txt", "p\nq\n")
        try t.git("add", ".", in: t.repo); try t.git("commit", "-q", "-m", "x", in: t.repo)
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 0, 0xFF]).write(to: URL(fileURLWithPath: t.repo + "/p.png"))
        try write(t, "big.txt", (0..<25_000).map { "l\($0)" }.joined(separator: "\n") + "\n")
        try t.git("add", "p.png", in: t.repo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t.repo + "/m.sh")
        try FileManager.default.removeItem(atPath: t.repo + "/gone.txt")
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        func file(_ p: String) throws -> ChangedFile { try #require(cs.files.first { $0.path == p }) }
        let png = try file("p.png")
        #expect(png.added == nil)
        #expect(try await g.diff(file: png, from: cs.from) == .binary)
        #expect(try await g.diff(file: try file("big.txt"), from: cs.from) == .tooLarge(lines: 25_000))
        #expect(try await g.diff(file: try file("m.sh"), from: cs.from) == .text(hunks: [], oldMode: "100644", newMode: "100755"))
        guard case .text(let h, _, _) = try await g.diff(file: try file("gone.txt"), from: cs.from) else { Issue.record("not text"); return }
        #expect(h.flatMap(\.lines).map(\.kind) == [.deleted, .deleted])
    }

    @Test func noCommitsAndMissingBase() async throws {
        let t = try TempRepo(emptyWithBranch: "main"); defer { t.cleanup() }
        try write(t, "s.txt", "staged\n"); try write(t, "u.txt", "untracked\n")
        try t.git("add", "s.txt", in: t.repo)
        let g = Git(repo: t.repo)
        let empty = try t.git("hash-object", "-t", "tree", "/dev/null", in: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        #expect(cs.from == empty)
        #expect(Set(cs.files.map(\.path)) == ["s.txt", "u.txt"])
        for bad in ["origin/gone", "-x"] {
            let r = try await g.changedFiles(.base(bad))
            #expect(r.mode == .uncommitted && r.baseMissing)
            #expect(Set(r.files.map(\.path)) == ["s.txt", "u.txt"])
        }
    }

    @Test func ignoresDiffUserConfig() async throws {
        let t = try featRepo(); defer { t.cleanup() }
        try t.git("config", "diff.noprefix", "true", in: t.repo)
        try t.git("config", "color.ui", "always", in: t.repo)
        try t.git("config", "diff.external", "/bin/false", in: t.repo)
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        let a = try #require(cs.files.first)
        guard case .text(let h, _, _) = try await g.diff(file: a, from: cs.from) else { Issue.record("not text"); return }
        #expect(h.count == 1 && h[0].lines.map(\.kind).contains(.added))
    }

    @Test func untrackedDirectoriesAreNotFiles() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try FileManager.default.createDirectory(atPath: t.repo + "/d", withIntermediateDirectories: true)
        try t.git("init", "-q", "nested", in: t.repo)
        try write(t, "nested/f.txt", "x\n")
        try FileManager.default.createSymbolicLink(atPath: t.repo + "/ls", withDestinationPath: "d")
        try write(t, "empty.txt", "")
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted)
        for p in ["nested/", "ls"] {
            let f = try #require(cs.files.first { $0.path == p })
            #expect(try await g.diff(file: f, from: cs.from) == .notAFile)
        }
        let e = try #require(cs.files.first { $0.path == "empty.txt" })
        #expect(try await g.diff(file: e, from: cs.from) != .notAFile)
    }

    @Test func truncatedWhenStatusCapDropsEntries() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        for i in 0..<4 { try write(t, "u\(i).txt", "x\n") }
        let g = Git(repo: t.repo)
        let cs = try await g.changedFiles(.uncommitted, limit: 3)
        #expect(cs.files.count == 3 && cs.truncated)
        #expect(try await g.changedFiles(.uncommitted, limit: 4).truncated == false)
    }

    /// Status counts a staged-then-reverted file that `diff HEAD` omits: the capped status yields fewer files than the limit.
    @Test func truncatedStatusWithFewerFilesThanLimit() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let original = try String(contentsOfFile: t.repo + "/a.txt", encoding: .utf8)
        try write(t, "a.txt", "staged\n")
        try t.git("add", "a.txt", in: t.repo)
        try write(t, "a.txt", original)
        for i in 0..<2 { try write(t, "u\(i).txt", "x\n") }
        let cs = try await Git(repo: t.repo).changedFiles(.uncommitted, limit: 2)
        #expect(cs.truncated && cs.files.map(\.path) == ["u0.txt"])
    }
}
