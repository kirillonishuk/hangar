import Exec
import Foundation
import Integration
import Testing
import Workspace
@testable import HangarUI

private let cli = "/Applications/Hangar.app/Contents/Helpers/hangar"
private let moved = "/Users/me/Apps/Hangar.app/Contents/Helpers/hangar"

/// The agents' `mcp` commands as run (the login-shell prefix dropped); `claude mcp add` also writes the fake `.claude.json`.
private final class FakeAgents: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }
    var status: Int32 = 0
    let claudeJSON: URL
    /// The fake Codex home: `codex mcp add` writes its `config.toml`.
    let codexConfig: URL

    init(claudeJSON: URL) {
        self.claudeJSON = claudeJSON
        codexConfig = claudeJSON.deletingLastPathComponent().appendingPathComponent("codex")
    }

    var runner: Runner {
        Runner { [self] args, _ in
            let argv = Array(args.dropFirst(6))
            lock.withLock { _calls.append(argv) }
            if status == 0, argv.starts(with: ["/fake/claude", "mcp", "add"]) {
                let entry = #"{"mcpServers": {"hangar": {"type": "stdio", "command": "\#(argv[argv.count - 2])", "args": ["mcp"], "env": {}}}}"#
                try entry.write(to: claudeJSON, atomically: true, encoding: .utf8)
            }
            if status == 0, argv.starts(with: ["/fake/codex", "mcp", "add"]) {
                let toml = "[mcp_servers.hangar]\ncommand = \"\(argv[argv.count - 2])\"\nargs = [\"mcp\"]\n"
                try FileManager.default.createDirectory(at: codexConfig, withIntermediateDirectories: true)
                try toml.write(to: codexConfig.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
            return RunResult(status: status, stdout: "", stderr: status == 0 ? "" : "boom\n")
        }
    }
}

/// Temp copies only (#111): the user's real ~/.claude, ~/.claude.json and ~/.codex are never touched; the agents' CLIs are fakes.
@MainActor @Suite struct IntegrationsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-integrations-\(UUID())")
    var claudeURL: URL { dir.appendingPathComponent("claude/settings.json") }
    var codexURL: URL { dir.appendingPathComponent("codex/config.toml") }
    var claudeJSON: URL { dir.appendingPathComponent("claude.json") }
    var configURL: URL { dir.appendingPathComponent("config.toml") }

    private func makeApp(_ config: String = "", agents: FakeAgents? = nil, found: Set<MCPAgent> = [.claude, .codex]) throws -> AppState {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let app = AppState(state: WorkspaceState(), store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: try HangarConfig.parse(config), configURL: configURL)
        app.claudeSettingsURL = claudeURL
        app.codexConfigURL = codexURL
        app.claudeJSONURL = claudeJSON
        app.findAgentDirs = nil
        app.integrationCLI = cli
        app.findAgentCLI = { found.contains($0) ? "/fake/\($0.rawValue)" : nil }
        app.mcpRunner = (agents ?? FakeAgents(claudeJSON: claudeJSON)).runner
        return app
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func migrationMapsAnOlderInstallToOn() throws {
        let hooks = try claudeInstall(nil, cli: moved), notify = try codexInstall(nil, cli: moved)
        #expect(integrationMigration(HangarConfig(), claude: hooks, codex: notify).map(\.key)
                == ["claude_integration", "claude_hooks", "claude_limits", "codex_integration", "codex_notify"])
        #expect(integrationMigration(HangarConfig(), claude: "{}", codex: nil).isEmpty)
        var decided = HangarConfig()
        decided.claudeIntegration = false
        decided.codexIntegration = false
        #expect(integrationMigration(decided, claude: hooks, codex: notify).isEmpty)
    }

    /// v0.8 → #111: installed means «on» (no sheet), the moved app's entries follow it, MCP is registered by the CLIs.
    @Test func launchMigratesRetargetsAndRegistersMCP() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let agents = FakeAgents(claudeJSON: claudeJSON)
        let app = try makeApp(agents: agents)
        try write(try claudeInstall(#"{"model": "opus"}"#, cli: moved), claudeURL)
        try write(#"{"numStartups": 4}"#, claudeJSON)

        await app.integrateAtLaunch()
        #expect(app.config.claudeIntegration == true)
        #expect(try HangarConfig.parse(read(configURL) ?? "").claudeIntegration == true)
        #expect(app.config.codexIntegration == nil)
        #expect(read(claudeURL) == (try claudeInstall(#"{"model": "opus"}"#, cli: cli)))
        #expect(!app.integrationGate(.claude, host: nil))
        #expect(app.integrations.ask == nil)
        #expect(read(codexURL)?.contains("notify") != true)  // codex undecided: no notify (only its own `mcp add`)
        #expect(agents.calls == [["/fake/claude", "mcp", "add", "--scope", "user", "hangar", "--", cli, "mcp"],
                                 ["/fake/codex", "mcp", "add", "hangar", "--", cli, "mcp"]])
        #expect(app.integrations.mcp[.claude] == .entry(.current))
        #expect(app.integrations.marks[.claude]?[IntegrationStatus.mac] != nil)

        // Again: nothing to change, nothing run.
        await app.integrateAtLaunch()
        #expect(agents.calls.count == 2)
    }

    @Test func mcpLeavesForeignAndFollowsTheSwitch() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let agents = FakeAgents(claudeJSON: claudeJSON)
        let app = try makeApp("claude_mcp = false\n", agents: agents, found: [.claude])
        // Someone else's `hangar`: never touched, even with the switch off.
        try write(#"{"mcpServers": {"hangar": {"command": "npx", "args": ["x"]}}}"#, claudeJSON)
        await app.syncMCP(.claude)
        #expect(agents.calls.isEmpty)
        #expect(app.integrations.mcp[.claude] == .entry(.foreign))
        // Ours and off: removed.
        try write(#"{"mcpServers": {"hangar": {"command": "\#(cli)", "args": ["mcp"]}}}"#, claudeJSON)
        await app.syncMCP(.claude)
        #expect(agents.calls == [["/fake/claude", "mcp", "remove", "--scope", "user", "hangar"]])
        // On, with an older path: remove + add.
        await app.setMCP(.claude, on: true).value
        try write(#"{"mcpServers": {"hangar": {"command": "\#(moved)", "args": ["mcp"]}}}"#, claudeJSON)
        await app.syncMCP(.claude)
        #expect(agents.calls.suffix(2) == [["/fake/claude", "mcp", "remove", "--scope", "user", "hangar"],
                                          ["/fake/claude", "mcp", "add", "--scope", "user", "hangar", "--", cli, "mcp"]])
        // No codex CLI on this Mac: nothing run, the row says so.
        await app.syncMCP(.codex)
        #expect(app.integrations.mcp[.codex] == .noCLI)
        // A failing CLI: the error, retried at the next launch.
        agents.status = 1
        await app.setMCP(.claude, on: false).value
        try write(#"{"mcpServers": {"hangar": {"command": "\#(cli)", "args": ["mcp"]}}}"#, claudeJSON)
        await app.syncMCP(.claude)
        #expect(app.integrations.mcp[.claude] == .failed("boom"))
    }

    /// The first claude tab waits for one sheet; «Не сейчас» writes only the decision; the tab then starts.
    @Test func firstRunAsksOnceAndNotNowWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp()
        var asked = 0, answered = 0
        app.onIntegrationAsk = { asked += 1 }
        app.onIntegrationAnswered = { answered += 1 }
        #expect(!app.integrationGate(.shell, host: nil))
        #expect(app.integrationGate(.claude, host: nil))
        #expect(app.integrationGate(.claude, host: nil))
        #expect(app.integrations.ask == .agent(.claude))
        #expect(asked == 1)

        await app.answerAgent(.claude, connect: false, choice: AgentChoice())
        #expect(app.config.claudeIntegration == false)
        #expect(read(configURL)?.contains("claude_integration = false") == true)
        #expect(!FileManager.default.fileExists(atPath: claudeURL.path))
        #expect(app.integrations.ask == nil)
        #expect(answered == 1)
        #expect(!app.integrationGate(.claude, host: nil))
        // Codex has its own question.
        #expect(app.integrationGate(.codex, host: nil))
        #expect(app.integrations.ask == .agent(.codex))
    }

    /// «Подключить»: the choice is saved and the hooks are in the file before the waiting tabs are let go.
    @Test func connectWritesBeforeTheTabStarts() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp()
        try write(#"{"statusLine": {"type": "command", "command": "mine"}}"#, claudeURL)
        #expect(app.integrationGate(.claude, host: nil))
        var stateAtStart: IntegrationState?
        app.onIntegrationAnswered = { [claudeURL] in
            stateAtStart = claudeState(try? String(contentsOf: claudeURL, encoding: .utf8), cli: cli)
        }
        var choice = AgentChoice()
        choice.limits = false
        choice.statusline = false
        await app.answerAgent(.claude, connect: true, choice: choice)
        let config = try HangarConfig.parse(read(configURL) ?? "")
        #expect(config.claudeIntegration == true && config.claudeHooks && !config.claudeLimits && config.statusline == .user)
        // Neither Hangar's line nor limits: the user's statusLine stays as it was, the hooks are in.
        #expect(stateAtStart == .installedStatuslineByUser || stateAtStart == .outdated)
        let text = try #require(read(claudeURL))
        #expect(text.contains("\(cli) event prompt") && text.contains("\"command\": \"mine\""))
        #expect(!app.integrationGate(.claude, host: nil))
    }

    @Test func noInstallableAppNoQuestion() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp()
        app.integrationCLI = nil
        #expect(!app.integrationGate(.claude, host: nil))
        app.integrationCLI = "/Volumes/Hangar/Hangar.app/Contents/Helpers/hangar"
        #expect(!app.integrationGate(.claude, host: nil))
        #expect(app.integrations.ask == nil)
    }

    @Test func hostDecisionsAreBookkept() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeApp("claude_integration = true\n")
        #expect(app.hostMark(.claude, "dev") == .undecided)
        // A remote claude tab of an undecided host waits for its connect to decide.
        #expect(app.integrationGate(.claude, host: "dev"))
        app.setHostDecision("dev", connect: false)
        #expect(app.hostMark(.claude, "dev") == .skipped)
        #expect(!app.integrationGate(.claude, host: "dev"))
        app.setHostDecision("dev", connect: true)
        #expect(app.config.integrationHosts == ["dev"] && app.config.integrationHostsSkipped.isEmpty)
        #expect(app.hostMark(.claude, "dev") == .offline)  // not connected in this test
        let saved = try HangarConfig.parse(read(configURL) ?? "")
        #expect(saved.integrationHosts == ["dev"] && saved.integrationHostsSkipped.isEmpty)
        #expect(app.integrationHostList == ["dev"])
    }

    @Test func cliPathPrefersHelpers() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("X.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let bare = try #require(Bundle(path: app.path))
        #expect(hangarCLIPath(bundle: bare) == nil)
        let helper = helpers.appendingPathComponent("hangar")
        FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let bundle = try #require(Bundle(path: app.path))
        #expect(hangarCLIPath(bundle: bundle) == helper.path)
    }

    @Test func limitsOffDropsUsage() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let off = try makeApp("claude_limits = false\n")
        #expect(!off.config.claudeLimits)
        #expect(off.config.wantsStatuslineWrapper)  // Hangar's line still needs the wrapper
        var c = off.config
        c.statusline = .user
        #expect(!c.wantsStatuslineWrapper)
    }
}
