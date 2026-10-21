import Foundation
import Testing
import ControlServer

@Suite struct CLICommandsTests {
    @Test func parsesEveryCommand() {
        let table: [([String], CLIParse)] = [
            (["tasks", "create", "--project", "p", "--name", "N", "--worktree", "--base", "origin/main", "--prompt", "do it"],
             .call(.tasksCreate(project: "p", name: "N", worktree: true, base: "origin/main", prompt: "do it"), json: false)),
            (["tasks", "create", "--name", "N", "--project", "p"],
             .call(.tasksCreate(project: "p", name: "N", worktree: false, base: nil, prompt: nil), json: false)),
            (["tabs", "send", "--tab", "ab12", "hello", "world", "--enter"],
             .call(.tabsSend(tab: "ab12", text: "hello world", keys: [.enter]), json: false)),
            (["tabs", "send", "hi", "--enter", "--tab", "ab12", "--key", "ctrl-c"],
             .call(.tabsSend(tab: "ab12", text: "hi", keys: [.ctrlC, .enter]), json: false)),
            (["tabs", "send", "--tab", "x", "--key", "escape", "--key", "down"],
             .call(.tabsSend(tab: "x", text: nil, keys: [.escape, .down]), json: false)),
            (["tabs", "read", "--tab", "x", "--lines", "20", "--json"], .call(.tabsRead(tab: "x", lines: 20), json: true)),
            (["tabs", "read", "--tab", "x"], .call(.tabsRead(tab: "x", lines: 100), json: false)),
            (["tabs", "open", "--kind", "codex", "--task", "t", "--prompt", "go"], .call(.tabsOpen(task: "t", kind: .codex, prompt: "go"), json: false)),
            (["projects", "add", "../x"], .call(.projectsAdd(path: "/tmp/a/x"), json: false)),
            (["projects", "add", "/abs/./y/"], .call(.projectsAdd(path: "/abs/y"), json: false)),
            (["projects", "list", "--json"], .call(.projectsList, json: true)),
            (["tasks", "list", "--project", "p"], .call(.tasksList(project: "p"), json: false)),
            (["tasks", "list"], .call(.tasksList(project: nil), json: false)),
            (["tasks", "archive", "--yes", "--task", "t"], .call(.tasksArchive(task: "t"), json: false)),
        ]
        for (args, expected) in table {
            #expect(parseCLI(args, cwd: "/tmp/a/b") == expected, "\(args)")
        }
    }

    @Test func textAfterDoubleDash() {
        #expect(parseCLI(["tabs", "send", "--tab", "x", "--", "--enter"], cwd: "/") == .call(.tabsSend(tab: "x", text: "--enter", keys: []), json: false))
    }

    @Test func usageErrors() {
        let table: [[String]] = [
            ["tasks", "create", "--project", "p", "--name", "N", "--base", "main"],
            ["tasks", "list", "--frob"],
            ["tasks", "create", "--project", "p"],
            ["tabs", "read", "--tab", "x", "--lines", "abc"],
            ["tabs", "read", "--tab", "x", "--lines", "0"],
            ["tabs", "open", "--task", "t", "--kind", "diff"],
            ["tabs", "send", "--tab", "x"],
            ["tabs", "send", "--tab", "x", "--key", "home"],
            ["tabs", "send", "hi"],
            ["tabs", "read", "--tab"],
            ["projects", "add"],
            ["projects", "add", ""],
            ["projects", "add", "a", "b"],
            ["projects", "list", "extra"],
            ["projects", "frob"],
            ["tasks", "create", "--project", "p", "--project", "q", "--name", "N"],
            ["tasks"],
            [],
        ]
        for args in table {
            if case .usage = parseCLI(args, cwd: "/") {} else { Issue.record("\(args) → \(parseCLI(args, cwd: "/"))") }
        }
        #expect(parseCLI(["tasks", "archive", "--task", "t"], cwd: "/") == .confirmRequired("refusing to archive without --yes"))
    }

    @Test func jsonModeFollowsTheGrammar() {
        #expect(jsonRequested(["tasks", "list", "--frob", "--json"]))
        #expect(jsonRequested(["tasks", "archive", "--json", "--task", "t"]))
        #expect(jsonRequested(["frob", "x", "--json"]))  // unknown command: raw argv fallback
        #expect(!jsonRequested(["tabs", "open", "--task", "--json"]))  // the value of --task
        #expect(!jsonRequested(["tabs", "send", "--tab", "x", "--key", "--json"]))
        #expect(!jsonRequested(["tabs", "send", "--tab", "x", "--", "--json"]))
        #expect(!jsonRequested(["frob", "--", "--json"]))
        #expect(!jsonRequested(["tasks", "list"]))
    }

    @Test func timeoutsPerCommand() {
        #expect(requestTimeout(.tasksCreate(project: "p", name: "n", worktree: true, base: nil, prompt: nil)) == 300)
        #expect(requestTimeout(.tabsRead(tab: "x", lines: 1)) == 10)
        #expect(requestTimeout(.projectsList) == 10)
    }

    @Test func humanFormat() throws {
        let taskId = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000001")!
        let t1 = UUID(uuidString: "11112222-0000-0000-0000-000000000002")!
        let t2 = UUID(uuidString: "33334444-0000-0000-0000-000000000003")!
        let task = TaskInfo(id: taskId, name: "Fix login", project: UUID(), projectName: "web", status: "working", mode: "worktree",
                            path: "/w", branch: "fix-login", base: "main", tabs: [
                                TabInfo(id: t1, kind: .claude, title: "Claude", status: "working", leaves: []),
                                TabInfo(id: t2, kind: .shell, title: "zsh", status: "idle", leaves: []),
                            ])
        let data = try JSONEncoder().encode(TasksResult(tasks: [task]))
        #expect(formatHuman(.tasksList(project: nil), result: data) == """
        abcdef12  working  web/Fix login  ⎇ fix-login
            11112222  claude  working  Claude
            33334444  shell  idle  zsh
        """)

        let main = TaskInfo(id: taskId, name: "N", project: UUID(), projectName: "web", status: "idle", mode: "main-folder",
                            path: "/w", branch: nil, base: nil, tabs: [TabInfo(id: t1, kind: .claude, title: "C", status: "idle", leaves: [])])
        #expect(formatHuman(.tasksList(project: nil), result: try JSONEncoder().encode(TasksResult(tasks: [main])))
                == "abcdef12  idle  web/N\n    11112222  claude  idle  C")
        let create = ControlCall.tasksCreate(project: "p", name: "N", worktree: false, base: nil, prompt: nil)
        #expect(formatHuman(create, result: try JSONEncoder().encode(TaskResult(task: main)))
                == "task abcdef12-0000-0000-0000-000000000001 tab 11112222-0000-0000-0000-000000000002")

        let p = ProjectInfo(id: taskId, name: "web", path: "/src/web", exists: true)
        #expect(formatHuman(.projectsList, result: try JSONEncoder().encode(ProjectsResult(projects: [p]))) == "abcdef12  web  /src/web")
        #expect(formatHuman(.projectsAdd(path: "/src/web"), result: try JSONEncoder().encode(ProjectAddResult(project: p, added: false)))
                == "abcdef12-0000-0000-0000-000000000001  /src/web  (already added)")
        #expect(formatHuman(.projectsAdd(path: "/src/web"), result: try JSONEncoder().encode(ProjectAddResult(project: p, added: true)))
                == "abcdef12-0000-0000-0000-000000000001  /src/web")
        let tab = TabInfo(id: t1, kind: .shell, title: "zsh", status: "idle", leaves: [])
        #expect(formatHuman(.tabsOpen(task: "t", kind: .shell, prompt: nil), result: try JSONEncoder().encode(TabResult(task: taskId, tab: tab)))
                == "tab 11112222-0000-0000-0000-000000000002")
        #expect(formatHuman(.tabsSend(tab: "x", text: "a", keys: []), result: try JSONEncoder().encode(SendResult(tab: t1, leaf: t2))) == "")
        #expect(formatHuman(.tabsRead(tab: "x", lines: 5), result: try JSONEncoder().encode(ScreenResult(tab: t1, leaf: t2, text: "$ ls\nfoo", lines: 2, truncated: false)))
                == "$ ls\nfoo")
        #expect(formatHuman(.tasksArchive(task: "t"), result: try JSONEncoder().encode(ArchiveResult(task: taskId, archived: true)))
                == "archived abcdef12-0000-0000-0000-000000000001")
    }
}
