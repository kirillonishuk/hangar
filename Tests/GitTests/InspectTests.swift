import Foundation
import Testing
import Exec
@testable import Git

@Suite struct InspectTests {
    private func write(_ t: TempRepo, _ path: String, _ text: String = "x\n") throws {
        let full = t.repo + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    @Test func statusKinds() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "d.txt"); try write(t, "b.txt", "bbbb bbbb bbbb\nline two\nline three\n")
        try t.git("add", "d.txt", "b.txt", in: t.repo); try t.git("commit", "-q", "-m", "more", in: t.repo)
        try write(t, "a.txt", "changed\n")
        try write(t, "n.txt"); try t.git("add", "n.txt", in: t.repo)
        try FileManager.default.removeItem(atPath: t.repo + "/d.txt")
        try write(t, "u/x.txt")
        try t.git("mv", "b.txt", "c с пробелом.txt", in: t.repo)
        let r = try await Git(repo: t.repo).status()
        #expect(!r.truncated)
        #expect(Set(r.entries) == [
            StatusEntry(path: "a.txt", origPath: nil, change: .modified),
            StatusEntry(path: "n.txt", origPath: nil, change: .added),
            StatusEntry(path: "d.txt", origPath: nil, change: .deleted),
            StatusEntry(path: "u/x.txt", origPath: nil, change: .untracked),
            StatusEntry(path: "c с пробелом.txt", origPath: "b.txt", change: .renamed),
        ])
    }

    @Test func statusParsesSpecialPaths() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let names = ["it's \"q\" %{x}.txt", "-dash.txt", "back`tick.txt", "папка/файл.txt"]
        for n in names { try write(t, n) }
        let r = try await Git(repo: t.repo).status()
        #expect(Set(r.entries.map(\.path)) == Set(names))
        #expect(r.entries.allSatisfy { $0.change == .untracked })
    }

    @Test func statusConflict() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "other", in: t.repo)
        try write(t, "a.txt", "other\n"); try t.git("commit", "-qam", "o", in: t.repo)
        try t.git("checkout", "-q", "main", in: t.repo)
        try write(t, "a.txt", "main\n"); try t.git("commit", "-qam", "m", in: t.repo)
        _ = try? t.git("merge", "other", in: t.repo)
        let r = try await Git(repo: t.repo).status()
        #expect(r.entries == [StatusEntry(path: "a.txt", origPath: nil, change: .conflicted)])
    }

    @Test func statusIgnoresUserConfig() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("config", "status.showUntrackedFiles", "no", in: t.repo)
        try write(t, "u/x.txt")
        let r = try await Git(repo: t.repo).status()
        #expect(r.entries.map(\.path) == ["u/x.txt"])
    }

    @Test func statusTruncated() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        for i in 0..<12 { try write(t, "f\(i).txt") }
        let r = try await Git(repo: t.repo).status(limit: 10)
        #expect(r.entries.count == 10)
        #expect(r.truncated)
    }

    @Test func listFilesRespectsGitignore() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, ".gitignore", "build/\n"); try write(t, "src/m.swift")
        try t.git("add", ".gitignore", "src", in: t.repo); try t.git("commit", "-q", "-m", "s", in: t.repo)
        try write(t, "build/o.bin"); try write(t, "new.txt")
        let g = Git(repo: t.repo)
        let l = try await g.listFiles()
        #expect(!l.truncated)
        #expect(Set(l.paths) == ["src/m.swift", "new.txt", "a.txt", ".gitignore"])
        let small = try await g.listFiles(limit: 2)
        #expect(small.truncated && small.paths.count == 2)
    }

    @Test func ignoredPathsCollapseDirectories() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, ".gitignore", "node_modules/\nbuild/\n*.o\n"); try write(t, "build/keep.txt")
        try t.git("add", "-f", ".gitignore", "build/keep.txt", in: t.repo); try t.git("commit", "-q", "-m", "s", in: t.repo)
        try write(t, "node_modules/a/i.js"); try write(t, "node_modules/b/j.js"); try write(t, "build/out.bin")
        try write(t, "src/x.o"); try write(t, "src/m.swift")
        let ignored = try await Git(repo: t.repo).ignoredPaths()
        // A directory with a tracked file inside is not ignored as a whole.
        #expect(Set(ignored) == ["node_modules/", "build/out.bin", "src/x.o"])
    }

    @Test func listFilesMarksDirectorySymlinks() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "d/x.txt")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: t.repo + "/dl", withDestinationPath: "d")
        try fm.createSymbolicLink(atPath: t.repo + "/fl", withDestinationPath: "a.txt")
        try t.git("add", "d", "dl", "fl", in: t.repo); try t.git("commit", "-q", "-m", "s", in: t.repo)
        try fm.createSymbolicLink(atPath: t.repo + "/ul", withDestinationPath: "d")
        let l = try await Git(repo: t.repo).listFiles()
        #expect(Set(l.paths) == ["a.txt", "d/x.txt", "dl", "fl", "ul"])
        #expect(l.dirLinks == ["dl", "ul"])
        #expect(FileListing.limit == 200_000)
        // No `ls-files --format` (git 2.38+): the same listing on older git.
        let noFormat = Runner { args, cwd in
            if args.contains(where: { $0.hasPrefix("--format") }) { return RunResult(status: 129, stdout: "", stderr: "unknown option") }
            return try await Runner.local.run(args, cwd)
        }
        let old = try await Git(repo: t.repo, runner: noFormat).listFiles()
        #expect(old == l)
    }

    @Test func commonDirOfWorktree() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let main = try await Git(repo: t.repo).gitDir()
        #expect(try await Git(repo: t.repo).commonDir() == main)
        let wt = t.worktrees + "/wt"
        try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
        try t.git("worktree", "add", "-q", "-b", "wtb", wt, in: t.repo)
        #expect(try await Git(repo: wt).commonDir() == main)
    }

    @Test func toplevelFromSubdir() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "sub/f.txt"); try t.git("add", "sub", in: t.repo); try t.git("commit", "-q", "-m", "s", in: t.repo)
        let real = String(cString: realpath(t.repo, nil))
        let g = Git(repo: t.repo + "/sub")
        #expect(try await g.toplevel() == real)
        #expect(try await g.gitDir().hasSuffix("/.git"))
        let wt = t.worktrees + "/wt"
        try FileManager.default.createDirectory(atPath: t.worktrees, withIntermediateDirectories: true)
        try t.git("worktree", "add", "-q", "-b", "wtb", wt, in: t.repo)
        #expect(try await Git(repo: wt).gitDir().contains("/worktrees/"))
    }

    @Test func inspectorCommandsDoNotWriteIndex() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let index = t.repo + "/.git/index"
        func mtime() throws -> Date { try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as! Date }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "touched\n".write(toFile: t.repo + "/a.txt", atomically: true, encoding: .utf8)
        let before = try mtime()
        let g = Git(repo: t.repo)
        _ = try await g.status(); _ = try await g.listFiles()
        let cs = try await g.changedFiles(.uncommitted)
        _ = try await g.diff(file: try #require(cs.files.first), from: cs.from)
        #expect(try mtime() == before)
    }

    /// Every git call of an inspector load (probes, base branch, changes, diff) passes `--no-optional-locks`.
    @Test func inspectorCallsPassNoOptionalLocks() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "a.txt", "changed\n")
        let calls = Calls()
        let g = Git(repo: t.repo, runner: Runner { args, cwd in
            await calls.add(args)
            return try await Runner.local.run(args, cwd)
        })
        _ = await g.isRepository()
        _ = try await g.defaultBranch()
        let cs = try await g.changedFiles(.base("main"))
        _ = try await g.diff(file: try #require(cs.files.first), from: cs.from)
        let missing = await calls.all.filter { $0.dropFirst().first != "--no-optional-locks" }
        #expect(missing.isEmpty, "\(missing)")
    }

    private actor Calls {
        var all: [[String]] = []
        func add(_ args: [String]) { all.append(args) }
    }

    @Test func notARepository() async throws {
        let dir = NSTemporaryDirectory() + "hangar-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await #expect(throws: GitError.self) { _ = try await Git(repo: dir).status() }
    }
}
