import Exec
import Foundation
import Testing
@testable import Git

@Suite struct TextSearchArgsTests {
    @Test func ripgrepDefaultsAndToggles() {
        let plain = ripgrepArgs(SearchQuery(text: "foo"))
        #expect(plain == ["--json", "--no-config", "--hidden", "--no-require-git", "--max-columns", "2000", "--max-columns-preview",
                          "--ignore-case", "--fixed-strings", "--max-count", "201", "--glob=!.git",
                          "-e", "foo", "--", "."])
        let all = ripgrepArgs(SearchQuery(text: "fo+", caseSensitive: true, regex: true, wholeWord: true,
                                          include: ["*.swift", "src/**"], exclude: ["node_modules"]))
        #expect(all.contains("--case-sensitive") && !all.contains("--ignore-case"))
        #expect(!all.contains("--fixed-strings") && all.contains("--word-regexp"))
        #expect(Array(all.suffix(8)) == ["--glob=!.git", "--glob=*.swift", "--glob=src/**", "--glob=!node_modules", "-e", "fo+", "--", "."])
    }

    @Test func gitGrepDefaultsAndToggles() {
        let repo = gitGrepArgs(SearchQuery(text: "foo"), noIndex: false)
        #expect(repo == ["git", "-c", "core.quotePath=false", "-c", "grep.fullName=false", "grep", "--no-color", "-n", "-z", "-I", "--column",
                         "--untracked", "-i", "-F", "-e", "foo", "--"])
        let plain = gitGrepArgs(SearchQuery(text: "a|b", caseSensitive: true, regex: true, wholeWord: true,
                                            include: ["*.ts"], exclude: ["/build/", "src/gen"]), noIndex: true, column: false)
        #expect(!plain.contains("--column") && !plain.contains("--untracked") && !plain.contains("-i"))
        #expect(plain.contains("--no-index") && plain.contains("--exclude-standard") && plain.contains("-E") && plain.contains("-w"))
        #expect(Array(plain.drop { $0 != "-e" }) == ["-e", "a|b", "--", ":(glob)**/*.ts", ":(glob)**/*.ts/**",
                                                       ":(exclude,glob)build", ":(exclude,glob)build/**",
                                                       ":(exclude,glob)src/gen", ":(exclude,glob)src/gen/**"])
    }

    /// Whatever is typed stays one argv element after `-e`: never an option, never shell code.
    @Test func hostileQueriesStayOneArgument() {
        for text in ["-rf", "--files", "--pre=sh", #"foo"bar'baz"#, "$(touch /tmp/pwned)", "a; rm -rf ~", "`id`", "a\nb"] {
            for args in [ripgrepArgs(SearchQuery(text: text)), gitGrepArgs(SearchQuery(text: text), noIndex: false)] {
                let e = args.firstIndex(of: "-e")!
                #expect(args[e + 1] == text)
                #expect(args[e + 2] == "--")
                #expect(args.filter { $0 == text }.count == 1)
            }
        }
        // A glob can't become an option either.
        #expect(ripgrepArgs(SearchQuery(text: "x", include: ["--pre=sh"])).contains("--glob=--pre=sh"))
        #expect(gitGrepArgs(SearchQuery(text: "x", include: ["--no-index"]), noIndex: false).contains(":(glob)**/--no-index"))
    }

    @Test func globFields() {
        #expect(searchGlobs(" *.swift, src/** ,, {a,b}.ts ,") == ["*.swift", "src/**", "{a,b}.ts"])
        #expect(searchGlobs("   ").isEmpty)
        #expect(gitPathspecs("./docs/*.md", exclude: false) == [":(glob)docs/*.md", ":(glob)docs/*.md/**"])
        #expect(gitPathspecs("/", exclude: true).isEmpty)
    }
}

@Suite struct TextSearchParseTests {
    private func rg(_ lines: [String]) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    private let rgSample = [
        #"{"type":"begin","data":{"path":{"text":"./src/a b/привет.txt"}}}"#,
        #"{"type":"match","data":{"path":{"text":"./src/a b/привет.txt"},"lines":{"text":"привет foo bar\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"start":13,"end":16}]}}"#,
        #"{"type":"match","data":{"path":{"text":"./src/a b/привет.txt"},"lines":{"text":"😀 foo foo\r\n"},"line_number":7,"absolute_offset":30,"submatches":[{"match":{"text":"foo"},"start":5,"end":8},{"match":{"text":"foo"},"start":9,"end":12}]}}"#,
        #"{"type":"end","data":{"path":{"text":"./src/a b/привет.txt"},"binary_offset":null,"stats":{"matches":3}}}"#,
        #"{"type":"begin","data":{"path":{"bytes":"/w=="}}}"#,
        #"{"type":"match","data":{"path":{"bytes":"/w=="},"lines":{"text":"foo\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"start":0,"end":3}]}}"#,
        // "\xff foo\n": not UTF-8, so rg sends base64 bytes; offsets are into those bytes.
        #"{"type":"match","data":{"path":{"text":"bin.txt"},"lines":{"bytes":"/yBmb28K"},"line_number":2,"absolute_offset":0,"submatches":[{"match":{"bytes":"Zm9v"},"start":2,"end":5}]}}"#,
        #"{"data":{"elapsed_total":{"human":"0.01s","nanos":1,"secs":0},"stats":{"matches":4}},"type":"summary"}"#,
    ]

    @Test func ripgrepJSON() {
        var p = SearchParser(engine: .ripgrep, query: SearchQuery(text: "foo"))
        let more = p.feed(rg(rgSample))
        #expect(more)
        p.finish()
        let r = p.results
        // Sorted once at the end, not in rg's (thread) order.
        #expect(r.files.map(\.path) == ["bin.txt", "src/a b/привет.txt"])
        let a = r.files[1].hits
        // UTF-16 columns: «привет » is 7 units (13 bytes); 😀 is 2 units (4 bytes).
        #expect(a[0] == SearchHit(line: 1, column: 8, preview: "привет foo bar", ranges: [7..<10]))
        #expect(a[1] == SearchHit(line: 7, column: 4, preview: "😀 foo foo", ranges: [3..<6, 7..<10]))
        #expect(r.files[0].hits == [SearchHit(line: 2, column: 3, preview: "\u{FFFD} foo", ranges: [2..<5])])
        #expect(r.lines == 3 && r.matches == 4 && !r.truncated)
    }

    /// While streaming, groups keep arrival order (a later line of an earlier file joins its group, nothing moves);
    /// `finish` sorts them by path once, case-insensitively, so identical searches end in one order.
    @Test func groupsStreamInArrivalOrderAndEndSorted() {
        func match(_ path: String) -> String {
            #"{"type":"match","data":{"path":{"text":"\#(path)"},"lines":{"text":"foo\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"foo"},"start":0,"end":3}]}}"#
        }
        var p = SearchParser(engine: .ripgrep, query: SearchQuery(text: "foo"))
        _ = p.feed(rg([match("b.ts"), match("Summary.tsx"), match("a.ts")]))
        #expect(p.results.files.map(\.path) == ["b.ts", "Summary.tsx", "a.ts"])
        _ = p.feed(rg([match("b.ts"), match("c.ts")]))
        #expect(p.results.files.map(\.path) == ["b.ts", "Summary.tsx", "a.ts", "c.ts"])
        #expect(p.results.files[0].hits.count == 2)
        p.finish()
        #expect(p.results.files.map(\.path) == ["a.ts", "b.ts", "c.ts", "Summary.tsx"])
    }

    /// Chunks split lines (and multibyte characters) anywhere.
    @Test func ripgrepChunksSplitAnywhere() {
        let data = rg(rgSample)
        var whole = SearchParser(engine: .ripgrep, query: SearchQuery(text: "foo"))
        _ = whole.feed(data)
        whole.finish()
        for size in [1, 7, 64] {
            var p = SearchParser(engine: .ripgrep, query: SearchQuery(text: "foo"))
            var i = 0
            while i < data.count {
                _ = p.feed(data.subdata(in: i..<min(data.count, i + size)))
                i += size
            }
            p.finish()
            #expect(p.results == whole.results)
        }
    }

    @Test func ripgrepLastLineWithoutNewline() {
        var p = SearchParser(engine: .ripgrep, query: SearchQuery(text: "foo"))
        _ = p.feed(Data(rgSample[1].utf8))
        #expect(p.results.lines == 0)
        p.finish()
        #expect(p.results.lines == 1)
    }

    @Test func gitGrepNullSeparated() {
        let out = "dir: x/a:b c.txt\u{0}12\u{0}15\u{0}  let привет = Foo + foo\n"
            + "Папка/файл.md\u{0}3\u{0}1\u{0}foo\n"
            + "garbage line without separators\n"
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "foo"))
        _ = p.feed(Data(out.utf8))
        p.finish()
        let r = p.results
        #expect(r.files.map(\.path) == ["dir: x/a:b c.txt", "Папка/файл.md"])
        // Case-insensitive like `git grep -i`: both matches marked; the indent is dropped from the preview.
        #expect(r.files[0].hits == [SearchHit(line: 12, column: 16, preview: "let привет = Foo + foo", ranges: [13..<16, 19..<22])])
        #expect(r.files[1].hits == [SearchHit(line: 3, column: 1, preview: "foo", ranges: [0..<3])])
    }

    @Test func gitGrepToggles() {
        func ranges(_ q: SearchQuery, _ line: String) -> [Range<Int>] {
            var p = SearchParser(engine: .gitGrep, query: q)
            _ = p.feed(Data("f\u{0}1\u{0}1\u{0}\(line)\n".utf8))
            return p.results.files.first?.hits.first?.ranges ?? []
        }
        #expect(ranges(SearchQuery(text: "Foo", caseSensitive: true), "foo Foo") == [4..<7])
        #expect(ranges(SearchQuery(text: "fo+", regex: true), "x fooo") == [2..<6])
        #expect(ranges(SearchQuery(text: "fo+"), "fo+ fo") == [0..<3])  // fixed string
        #expect(ranges(SearchQuery(text: "foo", wholeWord: true), "foobar foo_x (foo)") == [14..<17])
        #expect(ranges(SearchQuery(text: "(", regex: true), "(x") == [])  // ICU can't read it: line shown, nothing marked
    }

    /// Old git without --column: path NUL line NUL text.
    @Test func gitGrepWithoutColumn() {
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "b"), gitColumn: false)
        _ = p.feed(Data("x.txt\u{0}4\u{0}a b\n".utf8))
        #expect(p.results.files.first?.hits == [SearchHit(line: 4, column: 3, preview: "a b", ranges: [2..<3])])
    }

    @Test func caps() {
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "x"), total: 3, perFile: 2)
        let lines = (1...3).map { "a\u{0}\($0)\u{0}1\u{0}x\n" } + (1...3).map { "b\u{0}\($0)\u{0}1\u{0}x\n" }
        let first = p.feed(Data(lines.prefix(4).joined().utf8))
        #expect(first)
        #expect(p.results.files[0].hits.count == 2 && p.results.files[0].truncated)
        #expect(p.results.lines == 3 && !p.results.truncated)
        let fourth = p.feed(Data(lines[4].utf8))
        #expect(!fourth)  // a 4th line is past the total: stop
        #expect(p.results.truncated && p.results.lines == 3)
        let after = p.feed(Data(lines[0].utf8))
        #expect(!after)
    }

    /// The total cap is checked before a new file's group exists: no empty trailing group.
    @Test func totalCapAddsNoEmptyGroup() {
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "x"), total: 1, perFile: 5)
        _ = p.feed(Data("a\u{0}1\u{0}1\u{0}x\nb\u{0}1\u{0}1\u{0}x\n".utf8))
        #expect(p.results.truncated)
        #expect(p.results.files.map(\.path) == ["a"])
    }

    /// A line over `maxLineBytes` (a minified file) is skipped unbuffered, also across chunks; the next lines parse.
    @Test func overlongLinesAreSkipped() {
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "x"))
        let huge = Data(("big\u{0}1\u{0}1\u{0}" + String(repeating: "x", count: SearchLimits.maxLineBytes + 10)).utf8)
        var more = true
        for start in stride(from: 0, to: huge.count, by: 65_536) { more = p.feed(huge.subdata(in: start..<min(start + 65_536, huge.count))) && more }
        more = p.feed(Data("tail-of-big\nok\u{0}2\u{0}1\u{0}x\n".utf8)) && more
        #expect(more)
        p.finish()
        #expect(p.results.files.map(\.path) == ["ok"])
        #expect(p.results.skippedLines == 1)
        // Skipping to the end of output without a newline adds nothing either.
        var q = SearchParser(engine: .gitGrep, query: SearchQuery(text: "x"))
        _ = q.feed(huge)
        q.finish()
        #expect(q.results.files.isEmpty && q.results.skippedLines == 1)
    }

    /// git grep lines are highlighted again only in a bounded prefix: a match far out keeps git's column, no ranges.
    @Test func gitGrepHighlightIsBounded() {
        var p = SearchParser(engine: .gitGrep, query: SearchQuery(text: "needle"))
        let far = String(repeating: "a", count: 5000) + "needle"
        _ = p.feed(Data("f\u{0}1\u{0}5001\u{0}\(far)\nf\u{0}2\u{0}3\u{0}aaneedle\n".utf8))
        let hits = p.results.files.first?.hits ?? []
        #expect(hits.count == 2)
        #expect(hits[0].column == 5001 && hits[0].ranges.isEmpty)
        #expect(hits[1].column == 3 && !hits[1].ranges.isEmpty)
    }

    @Test func previewKeepsTheMatchInView() {
        let long = String(repeating: "a", count: 100) + "MATCH" + String(repeating: "b", count: 500)
        let (text, ranges) = searchPreview(long, [100..<105])
        #expect(text.hasPrefix("…") && text.hasSuffix("…"))
        #expect(text.utf16.count == 1 + SearchLimits.preview + 1)
        let u = Array(text.utf16)
        #expect(String(decoding: u[ranges[0]], as: UTF16.self) == "MATCH")
        #expect(ranges == [41..<46])
        // A surrogate pair at the cut is never split.
        let emoji = String(repeating: "😀", count: 30) + "x"
        let (e, er) = searchPreview(emoji, [60..<61], max: 10, lead: 3)
        #expect(!e.contains("\u{FFFD}") && String(decoding: Array(e.utf16)[er[0]], as: UTF16.self) == "x")
    }

    @Test func utf16Conversion() {
        let bytes = Array("aé😀b".utf8)  // 1 + 2 + 4 + 1 bytes
        #expect(utf16Offsets(of: [8, 0, 3, 7, 1, 99], in: bytes) == [5, 0, 2, 4, 1, 5])
    }
}

/// Real git grep (and rg when installed) in a repository with ignored, untracked and odd paths.
@Suite struct TextSearchEndToEndTests {
    private func fixture() throws -> TempRepo {
        let repo = try TempRepo(emptyWithBranch: "main")
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo.repo + "/src/вложенная папка", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo.repo + "/node_modules/lib", withIntermediateDirectories: true)
        try "привет needle\n-dash needle\n".write(toFile: repo.repo + "/src/вложенная папка/a:b c.txt", atomically: true, encoding: .utf8)
        try "needle\n".write(toFile: repo.repo + "/node_modules/lib/x.js", atomically: true, encoding: .utf8)
        try "ignored.txt\n".write(toFile: repo.repo + "/.gitignore", atomically: true, encoding: .utf8)
        try repo.git("add", "-A", in: repo.repo)
        try repo.git("commit", "-qm", "init", in: repo.repo)
        try "needle\n".write(toFile: repo.repo + "/ignored.txt", atomically: true, encoding: .utf8)
        try "untracked needle\n".write(toFile: repo.repo + "/new.txt", atomically: true, encoding: .utf8)
        return repo
    }

    private func search(_ executable: String, _ args: [String], _ engine: SearchEngine, _ q: SearchQuery, in dir: String) async throws -> SearchResults {
        let box = Box(SearchParser(engine: engine, query: q))
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        let r = try await streamProcess(executable, args, cwd: dir, env: env) { box.feed($0) }
        #expect(r.status == 0, "\(r.stderr)")
        return box.finish()
    }

    @Test func gitGrep() async throws {
        let repo = try fixture()
        defer { try? FileManager.default.removeItem(atPath: repo.root) }
        let q = SearchQuery(text: "NEEDLE", exclude: ["node_modules"])
        let r = try await search("/usr/bin/env", gitGrepArgs(q, noIndex: false), .gitGrep, q, in: repo.repo)
        #expect(r.files.map(\.path).sorted() == ["new.txt", "src/вложенная папка/a:b c.txt"])
        let file = try #require(r.files.first { $0.path.hasSuffix("a:b c.txt") })
        #expect(file.hits.map(\.line) == [1, 2])
        #expect(file.hits[0].column == 8 && file.hits[0].ranges == [7..<13])
        // A query starting with `-` is a pattern, not an option.
        let dash = SearchQuery(text: "-dash")
        let d = try await search("/usr/bin/env", gitGrepArgs(dash, noIndex: false), .gitGrep, dash, in: repo.repo)
        #expect(d.files.map(\.path) == ["src/вложенная папка/a:b c.txt"])
        // A subfolder root: paths relative to it.
        let sub = try await search("/usr/bin/env", gitGrepArgs(q, noIndex: false), .gitGrep, q, in: repo.repo + "/src")
        #expect(sub.files.map(\.path) == ["вложенная папка/a:b c.txt"])
    }

    @Test func gitGrepPlainFolder() async throws {
        let dir = NSTemporaryDirectory() + "hangar-search-\(UUID().uuidString)/папка с пробелом"
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "needle\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let q = SearchQuery(text: "needle", include: ["*.txt"])
        let r = try await search("/usr/bin/env", gitGrepArgs(q, noIndex: true), .gitGrep, q, in: dir)
        #expect(r.files.map(\.path) == ["a.txt"])
    }

    @Test(.enabled(if: installedRipgrep != nil)) func ripgrep() async throws {
        let repo = try fixture()
        defer { try? FileManager.default.removeItem(atPath: repo.root) }
        let q = SearchQuery(text: "NEEDLE", exclude: ["node_modules"])
        let r = try await search(installedRipgrep!, ripgrepArgs(q), .ripgrep, q, in: repo.repo)
        #expect(r.files.map(\.path).sorted() == ["new.txt", "src/вложенная папка/a:b c.txt"])
        let file = try #require(r.files.first { $0.path.hasSuffix("a:b c.txt") })
        #expect(file.hits[0].column == 8 && file.hits[0].ranges == [7..<13])
    }
}

private let installedRipgrep = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: SearchParser
    init(_ parser: SearchParser) { self.parser = parser }
    func feed(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return parser.feed(data) }
    func finish() -> SearchResults { lock.lock(); defer { lock.unlock() }; parser.finish(); return parser.results }
}
