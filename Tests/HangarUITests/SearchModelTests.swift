import Exec
import Foundation
import Git
import Testing
@testable import HangarUI
import Workspace

/// The Search tab's model (#91): streaming, one search at a time, debounce, outcomes.
@MainActor @Suite struct SearchModelTests {
    /// A fake engine: `sh` prints git-grep-like records (`-z`) built from its arguments, no shell code from the query.
    private func printing(_ records: [(String, Int, String)]) -> SearchLaunch {
        let format = String(repeating: #"%s\0%s\0%s\0%s\n"#, count: records.count)
        return SearchLaunch(executable: "/usr/bin/printf", args: [format] + records.flatMap { [$0.0, String($0.1), "1", $0.2] },
                            cwd: "/", engine: .gitGrep)
    }

    @Test func streamsResultsGroupedByFile() async {
        let model = SearchModel()
        model.launcher = { _, _, _ in self.printing([("a.txt", 1, "foo"), ("b/c.txt", 3, "x foo"), ("a.txt", 9, "foo foo")]) }
        model.text = "foo"
        model.setTarget(SearchTarget(root: "/r"))
        #expect(model.status == .running)
        await model.running?.value
        #expect(model.status == .done)
        #expect(model.engine == .gitGrep)
        #expect(model.results.files.map(\.path) == ["a.txt", "b/c.txt"])
        #expect(model.results.files[0].hits.map(\.line) == [1, 9])
        #expect(model.results.matches == 4 && model.results.lines == 3)
    }

    @Test func emptyQueryOrNoRootIsIdle() async {
        let model = SearchModel()
        var launches = 0
        model.launcher = { _, _, _ in launches += 1; return self.printing([]) }
        model.setTarget(SearchTarget(root: "/r"))
        #expect(model.status == .idle && model.running == nil)
        model.setTarget(nil)
        model.text = "foo"
        model.run()
        #expect(model.status == .idle && launches == 0)
    }

    /// Typing restarts one timer; only the last text is searched.
    @Test func typingIsDebounced() async throws {
        let model = SearchModel()
        model.debounceDelay = .milliseconds(50)
        var queries: [String] = []
        model.launcher = { q, _, _ in queries.append(q.text); return self.printing([]) }
        model.setTarget(SearchTarget(root: "/r"))
        model.text = "f"
        model.text = "fo"
        model.text = "foo"
        // A busy main actor (full parallel run) delays the timer: wait for it, generously.
        for _ in 0..<600 where queries.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        await model.running?.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(queries == ["foo"])
        // A toggle searches at once.
        model.caseSensitive = true
        await model.running?.value
        #expect(queries == ["foo", "foo"])
    }

    /// A new query terminates the running process; the old results never show up.
    @Test func newQueryTerminatesTheRunningSearch() async throws {
        let dir = NSTemporaryDirectory() + "hangar-search-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pidFile = dir + "/pid"
        let model = SearchModel()
        model.launcher = { q, _, _ in
            guard q.text == "slow" else { return self.printing([("new.txt", 1, "fast")]) }
            return SearchLaunch(executable: "/bin/sh", args: ["-c", #"echo $$ > "$1"; exec sleep 30"#, "sh", pidFile], cwd: "/", engine: .gitGrep)
        }
        model.text = "slow"
        model.setTarget(SearchTarget(root: "/r"))
        var pid: pid_t?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let slow = try #require(pid)
        model.text = "fast"
        model.run()
        await model.running?.value
        #expect(model.status == .done)
        #expect(model.results.files.map(\.path) == ["new.txt"])
        var gone = false
        for _ in 0..<60 where !gone {
            gone = kill(slow, 0) != 0
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(gone)
    }

    @Test func notConnectedHost() async {
        let model = SearchModel()
        model.launcher = { _, _, _ in nil }
        model.text = "foo"
        model.setTarget(SearchTarget(root: "/srv/app", host: "dev"))
        await model.running?.value
        #expect(model.status == .offline("dev"))
    }

    /// git before 2.19: a usage error about --column reruns without it.
    @Test func oldGitRetriesWithoutColumn() async {
        let model = SearchModel()
        var columns: [Bool] = []
        model.launcher = { _, _, column in
            columns.append(column)
            if column { return SearchLaunch(executable: "/bin/sh", args: ["-c", "echo 'error: unknown option `column`' >&2; exit 129"], cwd: "/", engine: .gitGrep) }
            return SearchLaunch(executable: "/usr/bin/printf", args: [#"x.txt\0%s\0a b\n"#, "4"], cwd: "/", engine: .gitGrep, gitColumn: false)
        }
        model.text = "b"
        model.setTarget(SearchTarget(root: "/r"))
        await model.running?.value
        #expect(columns == [true, false])
        #expect(model.results.files.first?.hits.first?.column == 3)
    }

    @Test func outcomes() {
        let none = SearchResults()
        var some = SearchResults()
        some.lines = 1
        var capped = SearchResults()
        capped.truncated = true
        #expect(searchOutcome(.ripgrep, RunResult(status: 1, stdout: "", stderr: ""), results: none, host: nil) == .done)
        #expect(searchOutcome(.ripgrep, RunResult(status: 2, stdout: "", stderr: "x: Permission denied"), results: some, host: nil) == .done)
        #expect(searchOutcome(.ripgrep, RunResult(status: 2, stdout: "", stderr: "regex parse error:\n  (\n"), results: none, host: nil)
                == .failed("regex parse error:"))
        #expect(searchOutcome(.gitGrep, RunResult(status: 15, stdout: "", stderr: ""), results: capped, host: nil) == .done)
        #expect(searchOutcome(.gitGrep, RunResult(status: 128, stdout: "", stderr: "fatal: bad"), results: none, host: nil) == .failed("fatal: bad"))
        #expect(searchOutcome(.gitGrep, RunResult(status: 255, stdout: "", stderr: ""), results: none, host: "dev") == .offline("dev"))
    }

    /// ⇧⌘F shows the inspector on Search (also for a plain folder) and asks the field for focus.
    @Test func showSearch() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hg-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/r/app")
        s.selectedTaskId = s.addTask(projectId: p, name: "a")
        let app = AppState(state: s, store: StateStore(directory: dir), config: HangarConfig(), configURL: dir.appendingPathComponent("c.toml"))
        #expect(!app.state.inspectorVisible)
        app.showSearch()
        #expect(app.state.inspectorVisible)
        #expect(app.inspector.segment == .search)
        #expect(app.search.focusRequest == 1)
    }
}
