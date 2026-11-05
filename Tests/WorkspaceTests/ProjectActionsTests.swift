import Foundation
import Testing
@testable import Workspace

/// Project actions (HD-133): the repository file, the merge with settings, approvals, restart vs a new tab, persistence.
@Suite struct ProjectActionsTests {
    @Test func repoFileParses() {
        let json = #"{"actions":[{"name":" Dev server ","command":"pnpm dev"},{"name":"Test","command":"pnpm test","restart":false}]}"#
        let r = parseRepoActions(Data(json.utf8))
        #expect(r.error == nil)
        #expect(r.actions == [ProjectAction(name: "Dev server", command: "pnpm dev"), ProjectAction(name: "Test", command: "pnpm test", restart: false)])
        #expect(parseRepoActions(nil) == RepoActions())
    }

    @Test func badRepoFileIsReportedNotThrown() {
        #expect(parseRepoActions(Data("{oops".utf8)).error?.contains("not valid JSON") == true)
        #expect(parseRepoActions(Data("[]".utf8)).error?.contains("expected") == true)
        #expect(parseRepoActions(Data(repeating: 0x20, count: repoActionsMaxBytes + 1)).error?.contains("64 KB") == true)
        // Good entries still count; bad and duplicate ones are named.
        let json = #"{"actions":[{"name":"Lint","command":"npm run lint"},{"name":""},{"command":"x"},{"name":"Lint","command":"y"},{"name":"R","command":"r","restart":"yes"},{"name":"Q","command":"q","restart":1}]}"#
        let r = parseRepoActions(Data(json.utf8))
        #expect(r.actions == [ProjectAction(name: "Lint", command: "npm run lint")])
        #expect(r.error?.contains("action 2") == true && r.error?.contains("action 3") == true)
        #expect(r.error?.contains("\"Lint\" is already defined") == true)
        #expect(r.error?.contains("action 5") == true && r.error?.contains("action 6") == true)
    }

    @Test func settingsWinOverRepoByName() {
        let merged = mergedActions(settings: [ProjectAction(name: "Test", command: "make test")],
                                   repo: [ProjectAction(name: "Dev", command: "pnpm dev"), ProjectAction(name: "Test", command: "rm -rf /")])
        #expect(merged.map(\.name) == ["Test", "Dev"])
        #expect(merged.map(\.source) == [.settings, .repo])
        #expect(merged[0].action.command == "make test")
    }

    @Test func approvalFollowsTheExactCommand() throws {
        let repo = ResolvedAction(ProjectAction(name: "Dev", command: "pnpm dev"), source: .repo)
        #expect(actionNeedsApproval(repo, approved: nil))
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        s.approveAction(projectId: p, command: "pnpm dev")
        s.approveAction(projectId: p, command: "pnpm dev")
        let approved = try #require(s.projects.first?.approvedActions)
        #expect(approved.count == 1 && approved[0].count == 64)
        #expect(!actionNeedsApproval(repo, approved: approved))
        // A changed command asks again; the project's own actions never ask.
        #expect(actionNeedsApproval(ResolvedAction(ProjectAction(name: "Dev", command: "pnpm dev --host"), source: .repo), approved: approved))
        #expect(!actionNeedsApproval(ResolvedAction(ProjectAction(name: "X", command: "anything"), source: .settings), approved: nil))
    }

    @Test func restartReusesTheActionLeafElseANewTab() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        let t = s.addTask(projectId: p, name: "Main")
        let dev = ProjectAction(name: "Dev", command: "pnpm dev")
        let task = { s.tasks.first { $0.id == t }! }
        #expect(actionRunPlan(dev, in: task()) == .newTab)
        let added = s.addActionTab(taskId: t, name: "Dev")
        let made = try #require(added)
        let leaf = try #require(task().tabs.last?.root.leaves.first)
        #expect(leaf.id == made.leaf && leaf.action == "Dev" && leaf.kind == .shell && leaf.cwd == "/tmp/app" && task().activeTabId == made.tab)
        #expect(actionRunPlan(dev, in: task()) == .restart(tab: made.tab, leaf: made.leaf))
        #expect(actionRunPlan(ProjectAction(name: "Dev", command: "pnpm dev", restart: false), in: task()) == .newTab)
        #expect(actionRunPlan(ProjectAction(name: "Test", command: "t"), in: task()) == .newTab)

        let renewedId = s.renewActionLeaf(made.leaf)
        let renewed = try #require(renewedId)
        let tab = try #require(task().tabs.first { $0.id == made.tab })
        #expect(renewed != made.leaf && tab.root.leaves.map(\.id) == [renewed] && tab.focusedLeafId == renewed)
        #expect(tab.root.leaves[0].action == "Dev")
        #expect(s.renewActionLeaf(UUID()) == nil)
    }

    @Test func settingsListIsCleanedAndPersisted() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/tmp/app")
        s.setActions(projectId: p, [ProjectAction(name: " Dev ", command: " pnpm dev "), ProjectAction(name: "", command: "x"),
                                    ProjectAction(name: "Lint", command: "  ", restart: false)])
        #expect(s.projects[0].actions == [ProjectAction(name: "Dev", command: "pnpm dev")])
        s.setLastAction(projectId: p, "Dev")
        let t = s.addTask(projectId: p, name: "Main")
        s.addActionTab(taskId: t, name: "Dev")
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(decoded.projects[0].actions == s.projects[0].actions && decoded.projects[0].lastAction == "Dev")
        #expect(decoded.tasks[0].tabs.last?.root.leaves.first?.action == "Dev")
        s.setActions(projectId: p, [])
        #expect(s.projects[0].actions == nil)
        // Older files have no actions at all.
        let old = #"{"id":"\#(UUID().uuidString)","name":"x","location":{"local":{"path":"/x"}}}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        #expect(project.actions == nil && project.approvedActions == nil && project.lastAction == nil)
    }
}

/// Suggestions from the repository (HD-133): package.json scripts of the root and workspace packages, Makefile, justfile.
@Suite struct ActionDiscoveryTests {
    @Test func monorepoScriptsByPackage() {
        let root: [String: String] = [
            "package.json": #"{"packageManager":"pnpm@10.28.2","scripts":{"lint":"biome lint","dev":"turbo dev","preinstall":"npx only-allow pnpm","build":"turbo build"}}"#,
            "pnpm-workspace.yaml": "packages:\n  - apps/*\n  - 'packages/*' # libs\n  - '!**/test/**'\n\ncatalog:\n  zod: ^3\n",
            "lock:pnpm-lock.yaml": "",
        ]
        #expect(workspaceGlobs(packageJSON: root["package.json"], pnpmWorkspace: root["pnpm-workspace.yaml"]) == ["apps/*", "packages/*"])
        let packages = ["apps/cms": #"{"name":"@acme/cms","scripts":{"dev":"vite","translations:add":"x","build":"vite build"}}"#,
                        "packages/ui": #"{"name":"@acme/ui"}"#]
        let groups = actionSuggestions(root: root, packages: packages)
        #expect(groups.map(\.folder) == ["", "apps/cms"])
        #expect(groups[0].actions.map(\.name) == ["dev", "build", "lint"])  // lifecycle scripts never offered
        #expect(groups[0].actions[0] == ProjectAction(name: "dev", command: "pnpm run dev"))
        #expect(groups[1].actions.map(\.name) == ["cms: dev", "cms: build", "cms: translations:add"])
        #expect(groups[1].actions[0] == ProjectAction(name: "cms: dev", command: "pnpm run dev", folder: "apps/cms"))
    }

    @Test func packageManagerAndWorkspacesFallbacks() {
        #expect(packageManager(lockfiles: ["yarn.lock"], packageJSON: "{}") == .yarn)
        #expect(packageManager(lockfiles: ["bun.lock"], packageJSON: nil) == .bun)
        #expect(packageManager(lockfiles: [], packageJSON: "{}") == .npm)
        #expect(packageManager(lockfiles: ["package-lock.json"], packageJSON: #"{"packageManager":"yarn@4"}"#) == .yarn)
        #expect(workspaceGlobs(packageJSON: #"{"workspaces":["apps/*","../evil","/abs","a b","x;rm"]}"#, pnpmWorkspace: nil) == ["apps/*"])
        #expect(workspaceGlobs(packageJSON: #"{"workspaces":{"packages":["libs/*"]}}"#, pnpmWorkspace: nil) == ["libs/*"])
    }

    @Test func makeAndJust() {
        let make = "CC := clang\nVAR = a:b\n.PHONY: build test\nbuild: deps\n\t$(CC) x\ntest:\n%.o: %.c\n# note: x\n"
        #expect(makeTargets(make) == ["build", "test"])
        let just = "set shell := [\"bash\"]\nalias b := build\nversion := \"1\"\nbuild target='x':\n    cargo build\n_private:\ntest: build\n"
        #expect(justRecipes(just) == ["build", "test"])
        let groups = actionSuggestions(root: ["Makefile": make, "justfile": just], packages: [:])
        #expect(groups.first?.actions.map(\.command) == ["make build", "make test", "just build", "just test"])
    }

    @Test func dumpAndFolders() {
        let dump = parseDiscoveryDump("\u{1e}package.json\n{\"a\":1}\n\u{1e}lock:yarn.lock\n\u{1e}apps/web\n{}")
        #expect(dump == ["package.json": "{\"a\":1}\n", "lock:yarn.lock": "", "apps/web": "{}"])
        #expect(actionFolder("./apps/cms/") == "apps/cms" && actionFolder("") == nil && actionFolder("../x") == nil)
        #expect(actionFolder("/abs") == nil && actionFolder("a/../b") == nil && actionFolder("~/x") == nil)
        #expect(actionFolderInvalid("../x") && !actionFolderInvalid("  "))
        #expect(ProjectAction(name: "d", command: "c", folder: "apps/cms").cwd(in: "/w/") == "/w/apps/cms")
        #expect(ProjectAction(name: "d", command: "c").cwd(in: "/w") == "/w")
        // The repository file may give a folder too.
        let r = parseRepoActions(Data(#"{"actions":[{"name":"cms","command":"pnpm dev","folder":"apps/cms"},{"name":"x","command":"y","folder":"../up"}]}"#.utf8))
        #expect(r.actions == [ProjectAction(name: "cms", command: "pnpm dev", folder: "apps/cms")] && r.error?.contains("action 2") == true)
        #expect(mergedActions(settings: [], repo: r.actions, hidden: ["cms"]).isEmpty)
    }
}
