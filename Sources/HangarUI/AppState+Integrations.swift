import Exec
import Foundation
import Integration
import Observation
import Workspace

/// The one question a sheet asks (#111): connect Hangar to an agent (its first tab here), or to a new ssh host.
enum IntegrationAsk: Equatable { case agent(MCPAgent), host(String) }

/// One machine of «Где установлено», per agent.
enum MachineMark: Equatable {
    /// Applied: `changed` = when this run wrote the file (nil: nothing to change), `backup` = where the old bytes went.
    case done(changed: Date?, backup: String?)
    /// A host not connected now: applied on connect.
    case offline
    /// A host never asked about: «Подключить…».
    case undecided
    case skipped
    /// The agent is not on that machine.
    case noAgent
    case failed(String)
}

/// Hangar's MCP entry on this Mac, per agent.
enum MCPStatus: Equatable {
    case checking
    /// No bundled helper, or the app runs from a DMG / translocated: nothing is written.
    case unavailable
    /// The agent's CLI is not in the login shell's PATH.
    case noCLI
    case entry(MCPEntry)
    case failed(String)
}

/// What the first-run sheet's switches chose.
struct AgentChoice: Equatable {
    var hooks = true, limits = true, statusline = true, mcp = true
}

/// Runtime state of the integrations (never saved): the marks of «Где установлено», MCP, the questions waiting.
@MainActor @Observable final class IntegrationStatus {
    var marks: [MCPAgent: [String: MachineMark]] = [:]
    var mcp: [MCPAgent: MCPStatus] = [.claude: .checking, .codex: .checking]
    /// The agent's CLI on this Mac; absent key = not looked up yet, nil value = not found.
    var agentCLI: [MCPAgent: String?] = [:]
    /// The user's own status line command (kept in `--then`): what «Ваша» runs; nil = none.
    var userStatusline: String?
    /// Claude's user settings run Hangar's status line command (else Hangar's line cannot show).
    var statuslineIsHangar = false
    /// The sheet shown now, then the queued ones.
    private(set) var asks: [IntegrationAsk] = []
    var ask: IntegrationAsk? { asks.first }

    /// Queues the question once; true when it became the one shown.
    func request(_ ask: IntegrationAsk) -> Bool {
        guard !asks.contains(ask) else { return false }
        asks.append(ask)
        return asks.count == 1
    }

    func answered(_ ask: IntegrationAsk) { asks.removeAll { $0 == ask } }

    /// An answer whose config write failed: it holds for this run, so the tab isn't asked again in a loop.
    @ObservationIgnored var sessionAnswer: [MCPAgent: Bool] = [:]
    /// Hosts whose connect is being decided (`integrateHost` runs once per host at a time).
    @ObservationIgnored var deciding: Set<String> = []
    /// One apply / MCP sync per agent at a time; a request meanwhile runs it once more after it.
    @ObservationIgnored var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var rerun: Set<String> = []

    static let mac = ""
}

extension LeafKind {
    var integrationAgent: MCPAgent? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }
}

/// What `mcp add` runs: the `[agents]` command's first word when it is the agent itself (`/opt/bin/claude --flag`);
/// a wrapper (`npx …`, `env …`) is not asked to `mcp add`, the plain agent name is looked up instead.
func agentExecutable(_ command: String, agent: MCPAgent) -> String {
    guard let first = shellWords(command)?.first, (first as NSString).lastPathComponent == agent.rawValue else { return agent.rawValue }
    return first
}

/// Keys a v0.8 install maps to «on» (#111): Hangar's hooks / notify found in the agent's file, never decided before.
func integrationMigration(_ c: HangarConfig, claude: String?, codex: String?) -> [(key: String, flag: Bool)] {
    var out: [(String, Bool)] = []
    if c.claudeIntegration == nil, claudeState(claude, cli: "") != .notInstalled {
        out += [("claude_integration", true), ("claude_hooks", true), ("claude_limits", true)]
    }
    if c.codexIntegration == nil, codexState(codex, cli: "") != .notInstalled {
        out += [("codex_integration", true), ("codex_notify", true)]
    }
    return out
}

extension HangarConfig {
    func integration(_ agent: MCPAgent) -> Bool? { agent == .claude ? claudeIntegration : codexIntegration }
    func mcp(_ agent: MCPAgent) -> Bool { agent == .claude ? claudeMCP : codexMCP }
    /// Claude's `statusLine` stays wrapped while Hangar's line or the limits need it (#111).
    var wantsStatuslineWrapper: Bool { statusline == .hangar || claudeLimits }
}

/// Integrations by function (#111): one consent, then Hangar keeps its own entries current on this Mac and every agreed
/// host, silently (backups, Hangar's entries only, #96); MCP registered through the agents' own CLIs on this Mac.
extension AppState {
    /// A helper to point the agents at, from an installed app: else nothing is written and nothing asked.
    var integrationReady: Bool { integrationCLI.map { !installBlocked(cli: $0) } ?? false }

    /// The launch's step (after the DEBUG overrides): an older install maps to «on», then the Mac's files and MCP follow
    /// the config, then the projects' status lines.
    public func integrateAtLaunch() async {
        let paths = await integrationFiles()
        let found = integrationMigration(config, claude: (try? readUserFile(paths.claude)) ?? nil, codex: (try? readUserFile(paths.codex)) ?? nil)
        if !found.isEmpty {
            do {
                try editConfig({ text in found.reduce(text) { HangarConfig.updating($0, key: $1.key, literal: $1.flag ? "true" : "false") } }) { c in
                    for (key, _) in found {
                        switch key {
                        case "claude_integration": c.claudeIntegration = true
                        case "codex_integration": c.codexIntegration = true
                        default: break  // the function flags are already on by default
                        }
                    }
                }
                uiLog.info("integration migrated: \(found.map(\.key), privacy: .public)")
            } catch {
                uiLog.error("integration migration: \(String(describing: error), privacy: .public)")
            }
        }
        await applyLocal(.claude)
        await applyLocal(.codex)
        await syncMCP()
        await syncProjectStatuslines(host: nil)
    }

    /// Settings files of this Mac (the login shell's `CLAUDE_CONFIG_DIR` / `CODEX_HOME` once per run).
    func integrationFiles() async -> (claude: URL, codex: URL, claudeJSON: URL) {
        if let cached = integrationPathsCache { return cached }
        var claudeDir: String?
        let paths: (claude: URL, codex: URL)
        if let find = findAgentDirs {
            let dirs = await find()
            claudeDir = dirs.claude
            paths = integrationPaths(home: FileManager.default.homeDirectoryForCurrentUser, claudeConfigDir: dirs.claude, codexHome: dirs.codex)
        } else {
            paths = (claudeSettingsURL, codexConfigURL)
        }
        let json = claudeJSONURL ?? claudeJSONPath(home: FileManager.default.homeDirectoryForCurrentUser, claudeConfigDir: claudeDir)
        let result = (paths.claude, paths.codex, json)
        integrationPathsCache = result
        return result
    }

    /// The agent's CLI on this Mac (login shell), looked up until found.
    func agentCLIPath(_ agent: MCPAgent) async -> String? {
        if let known = integrations.agentCLI[agent], let path = known { return path }
        let path = await findAgentCLI(agent)
        integrations.agentCLI[agent] = .some(path)
        return path
    }

    /// Runs `work` for `key` alone: while one runs, a new request is folded into one more run after it (which reads
    /// the config afresh), so a fast toggle never leaves two writers on the same file and always ends on the last choice.
    @discardableResult
    func serialized(_ key: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let running = integrations.jobs[key] {
            integrations.rerun.insert(key)
            return running
        }
        let task = Task { @MainActor [weak self] in
            repeat {
                self?.integrations.rerun.remove(key)
                await work()
            } while self?.integrations.rerun.contains(key) == true
            self?.integrations.jobs[key] = nil
        }
        integrations.jobs[key] = task
        return task
    }

    /// The Mac's file for `agent` brought to the config: its functions in, the rest of Hangar's entries out.
    /// Hooks don't depend on finding the agent's CLI (an alias or a wrapper still runs them).
    func applyLocal(_ agent: MCPAgent) async {
        await serialized("local-" + agent.rawValue) { [weak self] in await self?.applyLocalNow(agent) }.value
    }

    private func applyLocalNow(_ agent: MCPAgent) async {
        defer { readStatusline() }
        let files = await integrationFiles()
        guard let cli = integrationCLI, !installBlocked(cli: cli), let on = config.integration(agent) else { return }
        let ours = localOwnership(cli: cli)
        let mark: MachineMark
        do {
            let w: FileWrite? = switch agent {
            case .claude: try claudeApplyFile(files.claude, cli: cli, hooks: on && config.claudeHooks,
                                              statusline: on && config.wantsStatuslineWrapper, ours: ours, now: Date())
            case .codex: try codexApplyFile(files.codex, cli: cli, notify: on && config.codexNotify, ours: ours, now: Date())
            }
            if let w { uiLog.info("\(agent.rawValue, privacy: .public) integration written, backup \(w.backup?.path ?? "-", privacy: .public)") }
            mark = .done(changed: w == nil ? nil : Date(), backup: w?.backup.map { tildePath($0.path) })
        } catch {
            uiLog.error("\(agent.rawValue, privacy: .public) integration: \(String(describing: error), privacy: .public)")
            mark = .failed(IntegrationModel.describe(error))
        }
        // An unchanged file keeps the time and copy of an earlier write this run (the tooltip's «last update»).
        if case .done(nil, nil) = mark, case .done? = integrations.marks[agent]?[IntegrationStatus.mac] { return }
        integrations.marks[agent, default: [:]][IntegrationStatus.mac] = mark
    }

    /// «Ваша» needs the user's own command; the hint shows while Claude doesn't run Hangar's line.
    func readStatusline() {
        let text = (try? readUserFile(integrationPathsCache?.claude ?? claudeSettingsURL)) ?? nil
        integrations.userStatusline = userStatuslineCommand(text)
        integrations.statuslineIsHangar = hangarStatuslineCLI(text) != nil
    }

    /// Hangar's MCP server in each agent's user config, through the agent's CLI; deciding is a read of its file.
    func syncMCP(_ only: MCPAgent? = nil) async {
        for agent in [MCPAgent.claude, .codex] where only == nil || only == agent {
            await serialized("mcp-" + agent.rawValue) { [weak self] in await self?.syncMCPNow(agent) }.value
        }
    }

    private func syncMCPNow(_ agent: MCPAgent) async {
        guard let cli = integrationCLI, !installBlocked(cli: cli) else { integrations.mcp[agent] = .unavailable; return }
        guard let agentCLI = await agentCLIPath(agent) else { integrations.mcp[agent] = .noCLI; return }
        let entry = await mcpEntry(agent, cli: cli)
        var status = MCPStatus.entry(entry)
        for argv in mcpCommands(agent, mcpAction(entry, enabled: config.mcp(agent)), agentCLI: agentCLI, cli: cli) {
            let r = (try? await mcpRunner.run(loginShellArgv(argv, shell: userShell), NSHomeDirectory()))
                ?? RunResult(status: -1, stdout: "", stderr: "")
            uiLog.info("mcp \(argv.dropFirst().prefix(3).joined(separator: " "), privacy: .public): \(r.status)")
            guard r.status == 0 else {
                status = .failed(lastLine(r.stderr) ?? L10n.exitStatus(r.status))
                break
            }
            status = .entry(await mcpEntry(agent, cli: cli))
        }
        integrations.mcp[agent] = status
    }

    private func mcpEntry(_ agent: MCPAgent, cli: String) async -> MCPEntry {
        let files = await integrationFiles()
        let ours = localOwnership(cli: cli)
        let text: String?
        do { text = try readUserFile(agent == .claude ? files.claudeJSON : files.codex) } catch { return .unreadable }
        return agent == .claude ? claudeMCPEntry(text, cli: cli, ours: ours) : codexMCPEntry(text, cli: cli, ours: ours)
    }

    // MARK: Hosts

    /// ssh hosts of «Где установлено»: those with projects and those decided.
    var integrationHostList: [String] {
        Set(state.projects.compactMap(\.host) + config.integrationHosts + config.integrationHostsSkipped).sorted()
    }

    /// A host's mark: from this run's apply, else what its decision and connection say.
    func hostMark(_ agent: MCPAgent, _ host: String) -> MachineMark {
        if config.integrationHostsSkipped.contains(host) { return .skipped }
        guard config.integrationHosts.contains(host) else { return .undecided }
        if remote.hosts[host]?.state != .connected { return .offline }
        return integrations.marks[agent]?[host] ?? .offline
    }

    /// Connect (R7, #96, #111): an older `hangar-remote` first; then a decided host follows the config, an undecided one
    /// with an older Hangar's entries joins silently, else its sheet. Off in DEBUG runs without a fake ssh (main.swift).
    func integrateHost(_ host: String) async {
        guard autoUpgradeRemote, !integrations.deciding.contains(host) else { return }
        integrations.deciding.insert(host)
        defer { integrations.deciding.remove(host) }
        let m = ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
        _ = await m.autoUpgradeRemoteScript()
        defer { onIntegrationAnswered?() }
        if !config.integrationHosts.contains(host), !config.integrationHostsSkipped.contains(host) {
            guard config.claudeIntegration == true || config.codexIntegration == true else { return }
            guard await m.hasHangarIntegration() else {
                requestIntegration(.host(host))
                return
            }
            setHostDecision(host, connect: true)
        }
        if config.integrationHosts.contains(host) { await applyHost(host, m) }
        await syncProjectStatuslines(host: host)
    }

    /// The host's files brought to the config, `hangar-remote` installed first if it is not there.
    func applyHost(_ host: String, _ given: ServerCheckModel? = nil) async {
        await serialized("host-" + host) { [weak self] in await self?.applyHostNow(host, given) }.value
    }

    private func applyHostNow(_ host: String, _ given: ServerCheckModel?) async {
        guard autoUpgradeRemote, remote.hosts[host]?.state == .connected else { return }
        let m = given ?? ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
        // Hooks that call a missing `hangar-remote` would fail on every event: nothing is written without it.
        guard await m.ensureRemoteScript() else {
            for agent in [MCPAgent.claude, .codex] where config.integration(agent) != nil {
                integrations.marks[agent, default: [:]][host] = .failed(L10n.intRemoteMissing)
            }
            return
        }
        for agent in [MCPAgent.claude, .codex] {
            guard let on = config.integration(agent) else { continue }
            let mark = await m.applyAgent(agent, hooks: on && (agent == .claude ? config.claudeHooks : config.codexNotify),
                                          statusline: on && config.wantsStatuslineWrapper)
            if case .done(nil, nil) = mark, case .done? = integrations.marks[agent]?[host] { continue }
            integrations.marks[agent, default: [:]][host] = mark
        }
    }

    func setHostDecision(_ host: String, connect: Bool) {
        var hosts = config.integrationHosts.filter { $0 != host }, skipped = config.integrationHostsSkipped.filter { $0 != host }
        if connect { hosts.append(host) } else { skipped.append(host) }
        do {
            try editConfig({
                let t = HangarConfig.updating($0, key: "integration_hosts", literal: HangarConfig.listLiteral(hosts))
                return HangarConfig.updating(t, key: "integration_hosts_skipped", literal: HangarConfig.listLiteral(skipped))
            }) {
                $0.integrationHosts = hosts
                $0.integrationHostsSkipped = skipped
            }
        } catch {
            uiLog.error("integration hosts: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Questions

    /// Whether a leaf of `kind` waits for an answer before it starts (its sheet is asked for here).
    func integrationGate(_ kind: LeafKind, host: String?) -> Bool {
        guard integrationReady, let agent = kind.integrationAgent else { return false }
        guard let on = config.integration(agent) ?? integrations.sessionAnswer[agent] else {
            requestIntegration(.agent(agent))
            return true
        }
        // A new host: its connect decides (silently for an older install, else its sheet) and then lets it go. Turned on
        // after that connect, nothing would decide: the gate starts the decision itself (once; it asks or lets go).
        guard let host, on, autoUpgradeRemote else { return false }
        guard !config.integrationHosts.contains(host), !config.integrationHostsSkipped.contains(host) else { return false }
        if !integrations.deciding.contains(host), integrations.ask != .host(host) { Task { await integrateHost(host) } }
        return true
    }

    func requestIntegration(_ ask: IntegrationAsk) {
        if integrations.request(ask) { onIntegrationAsk?() }
    }

    /// The agent's sheet answered: «Подключить» saves the choice and writes the Mac and the connected hosts before the
    /// waiting tabs start; «Не сейчас» only remembers it. Either way the tabs go.
    func answerAgent(_ agent: MCPAgent, connect: Bool, choice: AgentChoice) async {
        do {
            if connect {
                try editConfig({ text in
                    var t = text
                    func set(_ key: String, _ on: Bool) { t = HangarConfig.updating(t, key: key, literal: on ? "true" : "false") }
                    switch agent {
                    case .claude:
                        set("claude_integration", true); set("claude_hooks", choice.hooks); set("claude_limits", choice.limits)
                        set("claude_mcp", choice.mcp)
                        t = HangarConfig.updating(t, key: "statusline", value: (choice.statusline ? StatuslineMode.hangar : .user).rawValue)
                    case .codex:
                        set("codex_integration", true); set("codex_notify", choice.hooks); set("codex_mcp", choice.mcp)
                    }
                    return t
                }) { c in
                    switch agent {
                    case .claude:
                        c.claudeIntegration = true; c.claudeHooks = choice.hooks; c.claudeLimits = choice.limits; c.claudeMCP = choice.mcp
                        c.statusline = choice.statusline ? .hangar : .user
                    case .codex:
                        c.codexIntegration = true; c.codexNotify = choice.hooks; c.codexMCP = choice.mcp
                    }
                }
            } else {
                try setConfig(agent == .claude ? "claude_integration" : "codex_integration", flag: false) {
                    if agent == .claude { $0.claudeIntegration = false } else { $0.codexIntegration = false }
                }
            }
        } catch {
            // The answer holds for this run (no loop of the same sheet); the user sees why it isn't remembered.
            uiLog.error("integration answer: \(String(describing: error), privacy: .public)")
            integrations.sessionAnswer[agent] = connect
            onIntegrationError?(L10n.saveFailed(error.localizedDescription))
        }
        // The Mac's hooks are in place before its waiting tabs go; hosts follow in the background (their tabs wait for
        // their own connect anyway).
        if connect, config.integration(agent) == true { await applyLocal(agent) }
        integrations.answered(.agent(agent))
        onIntegrationAnswered?()
        if integrations.ask != nil { onIntegrationAsk?() }
        guard connect, config.integration(agent) == true else { return }
        Task { [weak self] in
            guard let self else { return }
            for host in connectedProjectHosts where !config.integrationHostsSkipped.contains(host) {
                if !config.integrationHosts.contains(host) { setHostDecision(host, connect: true) }
                await applyHost(host)
            }
            await syncMCP(agent)
            syncAllStatuslines()
        }
    }

    /// The host's sheet answered: «Подключить» writes it, «Не на этом хосте» remembers that. Its tabs go either way.
    func answerHost(_ host: String, connect: Bool) async {
        setHostDecision(host, connect: connect)
        if connect {
            await applyHost(host)
            await syncProjectStatuslines(host: host)
        }
        integrations.answered(.host(host))
        onIntegrationAnswered?()
        if integrations.ask != nil { onIntegrationAsk?() }
    }

    /// «Подключить…» in «Где установлено»: a skipped host is asked again; an offline one asks once connected.
    func askHost(_ host: String) {
        if config.integrationHostsSkipped.contains(host) {
            var skipped = config.integrationHostsSkipped
            skipped.removeAll { $0 == host }
            try? editConfig({ HangarConfig.updating($0, key: "integration_hosts_skipped", literal: HangarConfig.listLiteral(skipped)) }) {
                $0.integrationHostsSkipped = skipped
            }
        }
        if remote.hosts[host]?.state == .connected { requestIntegration(.host(host)) } else { Task { await remote.connect(host) } }
    }

    private var connectedProjectHosts: [String] {
        Set(state.projects.compactMap(\.host)).sorted().filter { remote.hosts[$0]?.state == .connected }
    }

    // MARK: Settings

    /// A switch of the agent's card: saved, then the Mac and every connected agreed host follow.
    @discardableResult
    func setIntegration(_ agent: MCPAgent, key: String, on: Bool, apply: @escaping (inout HangarConfig) -> Void) -> Task<Void, Never> {
        do { try setConfig(key, flag: on, apply: apply) } catch { uiLog.error("config \(key, privacy: .public): \(String(describing: error), privacy: .public)") }
        return Task { await reapply(agent) }
    }

    func reapply(_ agent: MCPAgent) async {
        await applyLocal(agent)
        for host in config.integrationHosts where remote.hosts[host]?.state == .connected { await applyHost(host) }
        if agent == .claude { syncAllStatuslines() }
    }

    @discardableResult func setMCP(_ agent: MCPAgent, on: Bool) -> Task<Void, Never> {
        do {
            try setConfig(agent == .claude ? "claude_mcp" : "codex_mcp", flag: on) {
                if agent == .claude { $0.claudeMCP = on } else { $0.codexMCP = on }
            }
        } catch {
            uiLog.error("config mcp: \(String(describing: error), privacy: .public)")
        }
        return Task { await syncMCP(agent) }
    }
}

// MARK: Sheets

extension AppState {
    /// «Что изменится» of the agent's sheet: this Mac's file as `choice` would write it, and the MCP registration.
    func previewAgent(_ agent: MCPAgent, choice: AgentChoice) async -> [PlannedChange] {
        guard let cli = integrationCLI else { return [] }
        let files = await integrationFiles()
        let url = agent == .claude ? files.claude : files.codex
        var out: [PlannedChange] = []
        do {
            let original = try readUserFile(url)
            let ours = localOwnership(cli: cli)
            let text = agent == .claude
                ? try claudeApply(original, cli: cli, hooks: choice.hooks, statusline: choice.statusline || choice.limits, ours: ours)
                : try codexApply(original, cli: cli, notify: choice.hooks, ours: ours)
            if let text { out.append(PlannedChange(path: tildePath(url.path), diff: collapsed(lineDiff(original ?? "", text)))) }
        } catch {
            uiLog.error("integration preview: \(String(describing: error), privacy: .public)")
        }
        if choice.mcp, case .entry(let e)? = integrations.mcp[agent], let agentCLI = integrations.agentCLI[agent] ?? nil {
            let commands = mcpCommands(agent, mcpAction(e, enabled: true), agentCLI: agentCLI, cli: cli)
            if !commands.isEmpty {
                let path = agent == .claude ? files.claudeJSON : files.codex
                out.append(PlannedChange(path: tildePath(path.path), diff: commands.map { .added($0.map(shellQuote).joined(separator: " ")) }))
            }
        }
        return out
    }

    /// What a new host gets, per connected agent: its functions as one phrase.
    func hostParts() -> [(agent: MCPAgent, text: String)] {
        var out: [(MCPAgent, String)] = []
        if config.claudeIntegration == true {
            var p: [String] = []
            if config.claudeHooks { p.append(L10n.intPartHooks) }
            if config.claudeLimits { p.append(L10n.intPartLimits) }
            if config.statusline == .hangar { p.append(L10n.intPartStatusline) }
            out.append((.claude, p.isEmpty ? L10n.intNothingOn : p.joined(separator: ", ")))
        }
        if config.codexIntegration == true {
            out.append((.codex, config.codexNotify ? L10n.intPartHooks : L10n.intNothingOn))
        }
        return out
    }

    func previewHost(_ host: String) async -> [PlannedChange] {
        guard remote.hosts[host]?.state == .connected else { return [] }
        let m = ServerCheckModel(host: host, remote: remote, run: ServerCheckModel.sshRun(remote: remote, host: host))
        var out: [PlannedChange] = []
        for agent in [MCPAgent.claude, .codex] {
            guard let on = config.integration(agent), on else { continue }
            if let c = await m.preview(agent, hooks: agent == .claude ? config.claudeHooks : config.codexNotify,
                                       statusline: config.wantsStatuslineWrapper) { out.append(c) }
        }
        return out
    }

    /// «Куда» of the agent's sheet: this Mac, the hosts with projects (an offline one: «при подключении»).
    func askWhereItems() -> [WhereItem] {
        var items = [WhereItem(id: "mac", icon: .mac, name: L10n.intThisMac, mark: .none, help: L10n.intThisMac)]
        for host in Set(state.projects.compactMap(\.host)).sorted() where !config.integrationHostsSkipped.contains(host) {
            let connected = remote.hosts[host]?.state == .connected
            items.append(WhereItem(id: host, icon: .sshHost, name: host, mark: connected ? .none : .note(L10n.intOnConnect),
                                   help: connected ? host : L10n.intTipOffline))
        }
        return items
    }
}
