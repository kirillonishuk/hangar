import Foundation
import Testing
import Exec
@testable import Git

@Suite struct HistoryTests {
    private func write(_ t: TempRepo, _ path: String, _ text: String) throws {
        let full = t.repo + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// Commits everything staged/changed with `message`, as `author`, at unix `date`.
    private func commitAll(_ t: TempRepo, _ message: String, author: String = "Test", email: String = "test@example.com",
                           date: Int? = nil) throws {
        try t.git("add", "-A", in: t.repo)
        var env = ["GIT_AUTHOR_NAME": author, "GIT_AUTHOR_EMAIL": email]
        if let date { env["GIT_AUTHOR_DATE"] = "\(date) +0000"; env["GIT_COMMITTER_DATE"] = "\(date) +0000" }
        try t.run(["commit", "-q", "--allow-empty", "-m", message], in: t.repo, extraEnv: env)
    }

    private func head(_ t: TempRepo) throws -> String { try t.git("rev-parse", "HEAD", in: t.repo) }

    // MARK: Branches

    @Test func branchesWithUpstreamTracking() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try t.commit(file: "f1.txt", on: "feat")
        try t.git("push", "-q", "-u", "origin", "feat", in: t.repo)
        try t.git("reset", "-q", "--hard", "HEAD~1", in: t.repo)
        try t.commit(file: "f2.txt", on: "feat")
        try t.commit(file: "f3.txt", on: "feat")
        try t.git("branch", "-q", "lonely", "main", in: t.repo)
        let b = try await Git(repo: t.repo).branches()
        #expect(b.head == GitHead(branch: "feat", hash: try head(t)))
        #expect(b.local.map(\.name) == ["feat", "lonely", "main"])
        let feat = try #require(b.local.first { $0.name == "feat" })
        #expect(try feat.isHead && !feat.isRemote && feat.hash == head(t))
        #expect(feat.upstream == "origin/feat" && feat.ahead == 2 && feat.behind == 1 && !feat.upstreamGone)
        let main = try #require(b.local.first { $0.name == "main" })
        #expect(!main.isHead && main.upstream == "origin/main" && main.ahead == 0 && main.behind == 0)
        let lonely = try #require(b.local.first { $0.name == "lonely" })
        #expect(lonely.upstream == nil && lonely.ahead == 0 && lonely.behind == 0)
        // origin/HEAD is a symbolic ref: skipped.
        #expect(b.remote.map(\.name) == ["origin/feat", "origin/main"])
        #expect(b.remote.allSatisfy { $0.isRemote && $0.upstream == nil && !$0.isHead })
        #expect(b.remote.allSatisfy { $0.lastCommit.timeIntervalSince1970 > 0 })
    }

    @Test func branchesUpstreamGone() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try t.git("push", "-q", "-u", "origin", "feat", in: t.repo)
        try t.git("push", "-q", "origin", "--delete", "feat", in: t.repo)
        let b = try await Git(repo: t.repo).branches()
        let feat = try #require(b.local.first { $0.name == "feat" })
        #expect(feat.upstream == "origin/feat" && feat.upstreamGone && feat.ahead == 0)
    }

    @Test func branchesDetachedHead() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.commit(file: "b.txt", on: "main")
        try t.git("checkout", "-q", "--detach", "HEAD~1", in: t.repo)
        let b = try await Git(repo: t.repo).branches()
        #expect(try b.head.branch == nil && b.head.hash == head(t))
        #expect(b.local.allSatisfy { !$0.isHead })
    }

    @Test func branchesEmptyRepo() async throws {
        let t = try TempRepo(emptyWithBranch: "trunk"); defer { t.cleanup() }
        let b = try await Git(repo: t.repo).branches()
        #expect(b.head == GitHead(branch: "trunk", hash: nil))
        #expect(b.local.isEmpty && b.remote.isEmpty)
    }

    @Test func branchNamesWithSlashesAndUnicode() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("branch", "-q", "feature/ветка-ü", in: t.repo)
        let b = try await Git(repo: t.repo).branches()
        #expect(b.local.map(\.name).contains("feature/ветка-ü"))
    }

    // MARK: Log

    @Test func logParsesFields() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "x.txt", "x\n")
        try commitAll(t, "Привет 🚀 ünï — subject\n\nbody line", author: "Jürgen Ö", email: "j@ex.de", date: 1_700_000_000)
        try t.git("tag", "v1.0", in: t.repo)
        let page = try await Git(repo: t.repo).log()
        #expect(!page.hasMore)
        #expect(page.commits.count == 2)
        let c = page.commits[0]
        #expect(try c.hash == head(t) && c.hash.count == 40)
        #expect(c.parents == [try t.git("rev-parse", "HEAD~1", in: t.repo)])
        #expect(c.subject == "Привет 🚀 ünï — subject")
        #expect(c.authorName == "Jürgen Ö" && c.authorEmail == "j@ex.de")
        #expect(c.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(c.refs == [CommitRef(kind: .branch, name: "main", isHead: true), CommitRef(kind: .tag, name: "v1.0")])
        let root = page.commits[1]
        #expect(root.parents.isEmpty)
        #expect(root.refs == [CommitRef(kind: .remote, name: "origin/main")])
    }

    @Test func logDetachedHeadRef() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.commit(file: "b.txt", on: "main")
        try t.git("checkout", "-q", "--detach", "HEAD~1", in: t.repo)
        let c = try await Git(repo: t.repo).log(filters: LogFilters(ref: .head)).commits
        #expect(c.count == 1)
        #expect(c[0].refs.contains(CommitRef(kind: .head, name: "HEAD", isHead: true)))
    }

    @Test func logEmptyRepo() async throws {
        let t = try TempRepo(emptyWithBranch: "main"); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        #expect(try await g.log() == LogPage(commits: [], hasMore: false))
        #expect(try await g.log(filters: LogFilters(ref: .head)) == LogPage(commits: [], hasMore: false))
    }

    @Test func logMergeTopoOrder() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try t.commit(file: "f.txt", on: "feat", date: 1_700_000_100)
        try t.commit(file: "m.txt", on: "main", date: 1_700_000_200)
        try t.run(["merge", "-q", "--no-ff", "-m", "merge feat", "feat"], in: t.repo,
                  extraEnv: ["GIT_COMMITTER_DATE": "1700000300 +0000", "GIT_AUTHOR_DATE": "1700000300 +0000"])
        let commits = try await Git(repo: t.repo).log().commits
        #expect(commits.count == 4)
        #expect(commits[0].parents.count == 2 && commits[0].subject == "merge feat")
        // Topological: every commit comes before its parents.
        let index = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.hash, $0) })
        for (i, c) in commits.enumerated() { for p in c.parents { #expect(index[p]! > i) } }
        let rows = layoutGraph(commits: commits)
        #expect(rows[0].isMerge && rows.last!.isRoot && rows.map(\.width).max() == 2)
    }

    @Test func logPagination() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        for i in 1...6 { try commitAll(t, "n\(i)") }
        let g = Git(repo: t.repo)
        let full = try await g.log().commits
        #expect(full.count == 7)
        let p1 = try await g.log(limit: 3, skip: 0)
        let p2 = try await g.log(limit: 3, skip: 3)
        let p3 = try await g.log(limit: 3, skip: 6)
        #expect(p1.hasMore && p2.hasMore && !p3.hasMore)
        #expect(p1.commits.count == 3 && p2.commits.count == 3 && p3.commits.count == 1)
        #expect(p1.commits + p2.commits + p3.commits == full)
        #expect(try await g.log(limit: 7).hasMore == false)
        #expect(try await g.log(limit: 3, skip: 50).commits.isEmpty)
        #expect(Git.defaultLogLimit == 200)
    }

    @Test func logRefFilter() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try t.commit(file: "f.txt", on: "feat")
        try t.commit(file: "m.txt", on: "main")
        let g = Git(repo: t.repo)
        #expect(try await g.log(filters: LogFilters(ref: .all)).commits.count == 3)
        #expect(try await g.log(filters: LogFilters(ref: .head)).commits.map(\.subject) == ["c m.txt", "c a.txt"])
        #expect(try await g.log(filters: LogFilters(ref: .ref("feat"))).commits.map(\.subject) == ["c f.txt", "c a.txt"])
        await #expect(throws: GitError.self) { try await g.log(filters: LogFilters(ref: .ref("nope"))) }
    }

    @Test func logAuthorDatePathFilters() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "src/a.swift", "1\n"); try commitAll(t, "alice one", author: "Alice Smith", email: "alice@x.io", date: 1_700_000_000)
        try write(t, "docs/b.md", "1\n"); try commitAll(t, "bob one", author: "Bob", email: "bob@y.io", date: 1_700_100_000)
        try write(t, "src/a.swift", "2\n"); try commitAll(t, "alice two", author: "Alice Smith", email: "alice@x.io", date: 1_700_200_000)
        let g = Git(repo: t.repo)
        func subjects(_ f: LogFilters) async throws -> [String] { try await g.log(filters: f).commits.map(\.subject) }
        #expect(try await subjects(LogFilters(author: "ALICE")) == ["alice two", "alice one"])
        #expect(try await subjects(LogFilters(author: "bob@y.io")) == ["bob one"])
        // Fixed string, not a regex.
        #expect(try await subjects(LogFilters(author: "A.ice")) == [])
        // git stops the walk at the first commit older than `since`: the (newer) fixture root behind it is not reached.
        #expect(try await subjects(LogFilters(since: Date(timeIntervalSince1970: 1_700_050_000))) == ["alice two", "bob one"])
        #expect(try await subjects(LogFilters(until: Date(timeIntervalSince1970: 1_700_150_000), path: "src")).first == "alice one")
        #expect(try await subjects(LogFilters(since: Date(timeIntervalSince1970: 1_700_050_000),
                                              until: Date(timeIntervalSince1970: 1_700_150_000))) == ["bob one"])
        #expect(try await subjects(LogFilters(path: "docs/b.md")) == ["bob one"])
        #expect(try await subjects(LogFilters(path: "src")) == ["alice two", "alice one"])
        #expect(try await subjects(LogFilters(author: "alice", path: "src")) == ["alice two", "alice one"])
    }

    @Test func logTextFilter() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try commitAll(t, "Fix the Ünicode bug")
        try commitAll(t, "add feature [x]")
        let target = try head(t)
        try commitAll(t, "other")
        let g = Git(repo: t.repo)
        func subjects(_ text: String) async throws -> [String] { try await g.log(filters: LogFilters(text: text)).commits.map(\.subject) }
        #expect(try await subjects("fix THE") == ["Fix the Ünicode bug"])
        #expect(try await subjects("[x]") == ["add feature [x]"])  // fixed string
        #expect(try await subjects("nothing-like-this") == [])
        // A hash prefix finds the commit even though its subject doesn't match.
        #expect(try await subjects(String(target.prefix(8))) == ["add feature [x]"])
        #expect(try await subjects(target.uppercased()) == ["add feature [x]"])
        // Control characters are stripped before use.
        #expect(try await subjects("fi\u{01}x\u{7F} the\n") == ["Fix the Ünicode bug"])
    }

    @Test func logRejectsOptionLikeInput() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let g = Git(repo: t.repo)
        let out = t.root + "/pwned"
        await #expect(throws: GitError.self) { try await g.log(filters: LogFilters(ref: .ref("--output=" + out))) }
        await #expect(throws: GitError.self) { try await g.log(filters: LogFilters(ref: .ref(" -all"))) }
        // Author, text and path are values of their own options or pathspecs: harmless literals.
        #expect(try await g.log(filters: LogFilters(author: "--output=" + out)).commits.isEmpty)
        #expect(try await g.log(filters: LogFilters(text: "--output=" + out)).commits.isEmpty)
        #expect(try await g.log(filters: LogFilters(path: "--output=" + out)).commits.isEmpty)
        #expect(try await g.log(filters: LogFilters(path: ":(glob)**")).commits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out))
        // Blank filters are no filters.
        #expect(try await g.log(filters: LogFilters(author: " \u{01} ", path: "", text: "\n")).commits.count == 1)
        await #expect(throws: GitError.self) { try await g.log(limit: 0) }
        await #expect(throws: GitError.self) { try await g.log(skip: -1) }
    }

    @Test func logOverSSHMatchesLocalAndCapsOutput() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try commitAll(t, "über ssh")
        let ssh = try FakeSSH.make(dir: t.root + "/fake")
        let remote = Git(repo: t.repo, runner: .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path))
        let local = Git(repo: t.repo)
        #expect(try await remote.log() == local.log())
        #expect(try await remote.branches() == local.branches())
        let filters = LogFilters(author: "it's \"q\" $(x)", text: "`x`")
        #expect(try await remote.log(filters: filters) == local.log(filters: filters))
        // A stream cut by `maxOutput` (git may still exit 0) throws: never a short page or a cut message.
        let full = try await local.log().commits
        var threw = 0
        for cap in [64, 150, 100_000] {
            let capped = Git(repo: t.repo, runner: .ssh(host: "dev", controlPath: t.root + "/cm", sshPath: ssh.path, maxOutput: cap))
            if let page = try? await capped.log() { #expect(page.commits == full) } else { threw += 1 }
            if let d = try? await capped.commit(hash: full[0].hash) { #expect(d.commit == full[0] && d.message == "über ssh") }
        }
        #expect(threw == 2)
        #expect(throws: GitError.self) { try parseCommits("abc\0") }
    }

    // MARK: Commit details

    @Test func commitDetailsFiles() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "keep.txt", "1\n2\n3\n")
        try write(t, "gone.txt", "a\nb\n")
        try write(t, "old name.txt", "same\ncontent\nhere\nfor\nrename\n")
        try commitAll(t, "setup")
        try write(t, "keep.txt", "1\nTWO\n3\n4\n")
        try FileManager.default.removeItem(atPath: t.repo + "/gone.txt")
        try t.git("mv", "old name.txt", "новое имя.txt", in: t.repo)
        try Data([0, 1, 2, 255]).write(to: URL(fileURLWithPath: t.repo + "/blob.bin"))
        try write(t, "new.txt", "n\n")
        try commitAll(t, "Многострочное\n\nТело сообщения\nвторая строка", author: "Ann", email: "ann@x.io")
        let d = try await Git(repo: t.repo).commit(hash: try head(t))
        #expect(try d.commit.hash == head(t) && d.commit.authorName == "Ann")
        #expect(d.commit.subject == "Многострочное")
        #expect(d.message == "Многострочное\n\nТело сообщения\nвторая строка")
        #expect(!d.truncated)
        let byPath = Dictionary(uniqueKeysWithValues: d.files.map { ($0.path, $0) })
        #expect(byPath.count == 5)
        #expect(byPath["keep.txt"] == ChangedFile(path: "keep.txt", change: .modified, added: 2, deleted: 1))
        #expect(byPath["gone.txt"] == ChangedFile(path: "gone.txt", change: .deleted, added: 0, deleted: 2))
        #expect(byPath["новое имя.txt"] == ChangedFile(path: "новое имя.txt", origPath: "old name.txt", change: .renamed, added: 0, deleted: 0))
        #expect(byPath["blob.bin"] == ChangedFile(path: "blob.bin", change: .added, added: nil, deleted: nil))
        #expect(byPath["new.txt"] == ChangedFile(path: "new.txt", change: .added, added: 1, deleted: 0))
    }

    @Test func commitDetailsRootAndMerge() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        let root = try t.git("rev-list", "--max-parents=0", "HEAD", in: t.repo)
        let r = try await Git(repo: t.repo).commit(hash: root)
        #expect(r.commit.parents.isEmpty && r.files.map(\.path) == ["a.txt"] && r.files[0].change == .added)
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try t.commit(file: "f.txt", on: "feat")
        try t.commit(file: "m.txt", on: "main")
        try t.git("merge", "-q", "--no-ff", "-m", "merge", "feat", in: t.repo)
        let m = try await Git(repo: t.repo).commit(hash: try head(t))
        #expect(m.commit.parents.count == 2)
        // Against the first parent: what the merge brought into main.
        #expect(m.files.map(\.path) == ["f.txt"])
    }

    @Test func commitDetailsEmptyAndInvalid() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try commitAll(t, "empty")
        let g = Git(repo: t.repo)
        let d = try await g.commit(hash: try head(t))
        #expect(d.files.isEmpty && d.message == "empty")
        await #expect(throws: GitError.self) { try await g.commit(hash: "--all") }
        await #expect(throws: GitError.self) { try await g.commit(hash: "HEAD~1") }  // hashes only
        await #expect(throws: GitError.self) { try await g.commit(hash: "deadbeefdeadbeef") }
    }

    @Test func commitDetailsTruncated() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        for i in 0..<6 { try write(t, "f\(i).txt", "\(i)\n") }
        try commitAll(t, "many")
        let d = try await Git(repo: t.repo).commit(hash: try head(t), fileLimit: 4)
        #expect(d.files.count == 4 && d.truncated)
    }

    // MARK: Diff stat

    @Test func diffStatAgainstBaseIncludesUncommitted() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try t.git("checkout", "-q", "-b", "feat", in: t.repo)
        try write(t, "c.txt", "1\n2\n3\n"); try commitAll(t, "c")
        try t.commit(file: "later.txt", on: "main")              // base moves on: merge-base semantics, not a two-dot diff
        try t.git("checkout", "-q", "feat", in: t.repo)
        try write(t, "a.txt", "changed\n")                        // 1 added, 1 deleted, uncommitted
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: t.repo + "/bin.dat")); try t.git("add", "bin.dat", in: t.repo)
        try write(t, "u.txt", "untracked\n")                     // untracked: listed in Changes without counts
        let g = Git(repo: t.repo)
        let s = try await g.diffStat(base: "main")
        #expect(s == DiffStat(files: 3, added: 4, deleted: 1))
        // Same numbers as the inspector's Changes list.
        let cs = try await g.changedFiles(.base("main"))
        #expect(cs.files.compactMap(\.added).reduce(0, +) == s.added)
        #expect(cs.files.compactMap(\.deleted).reduce(0, +) == s.deleted)
    }

    @Test func diffStatFallbacks() async throws {
        let t = try TempRepo(); defer { t.cleanup() }
        try write(t, "a.txt", "x\ny\n")
        let g = Git(repo: t.repo)
        // A missing (or option-like) base falls back to uncommitted changes, as Changes does.
        #expect(try await g.diffStat(base: "nope") == g.diffStat(base: "HEAD"))
        #expect(try await g.diffStat(base: "--cached").added == 2)
        let e = try TempRepo(emptyWithBranch: "main"); defer { e.cleanup() }
        try "x\n".write(toFile: e.repo + "/n.txt", atomically: true, encoding: .utf8)
        try e.git("add", "n.txt", in: e.repo)
        #expect(try await Git(repo: e.repo).diffStat(base: "main") == DiffStat(files: 1, added: 1, deleted: 0))
    }
}
