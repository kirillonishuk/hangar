import AgentStatus
import AppKit
import ControlServer
import Exec
import GhosttyBridge
import Git
import History
import Integration
import Observation
import os
import Power
import Usage
import UserNotifications
import Workspace

public let uiLog = Logger(subsystem: "dev.hangar", category: "UI")

/// Single source of UI truth. Every model change goes through `perform`, which schedules a debounced save.
@MainActor @Observable public final class AppState {
    public private(set) var state: WorkspaceState
    /// Changed live from Settings (each change is also written to `configURL`).
    public private(set) var config: HangarConfig {
        didSet {
            if config.keepAwake != oldValue.keepAwake { updateKeepAwake() }
            if config.dockBadge != oldValue.dockBadge { updateDockBadge() }
            if config != oldValue { onBannerPolicy?() }
        }
    }
    /// Runtime-only (not persisted): last terminal title per leaf.
    var leafTitles: [UUID: String] = [:]
    /// True while the sidebar width animates between rail and expanded.
    var sidebarAnimating = false
    /// Row or tab currently edited inline (F2 / double-click).
    var renaming: ActionTarget?
    /// Agent state per leaf (hooks + terminal fallbacks); in memory only.
    var statuses = StatusBoard() {
        didSet {
            updateKeepAwake()
            updateDockBadge()
        }
    }
    /// Sets the Dock badge text ("" clears it); set by the window controller, nil in tests and `swift run` without it.
    @ObservationIgnored var onDockBadge: ((String) -> Void)?
    /// macOS's notification permission for the settings page; nil without an app bundle (no row).
    @ObservationIgnored var notificationAuthorization: (() async -> UNAuthorizationStatus)?
    /// A new permission or question: bounce the Dock once if the app is inactive (set by the window controller).
    @ObservationIgnored var requestAttention: (() -> Void)?
    /// A leaf's attention changed or went (nil): notifications follow it.
    @ObservationIgnored var onAttention: ((UUID, Attention?) -> Void)?
    /// A leaf got focus: its delivered banner is no longer needed.
    @ObservationIgnored var onLeafSeen: ((UUID) -> Void)?
    /// Mute, project mode or a notification setting changed: delivered banners no longer allowed go.
    @ObservationIgnored var onBannerPolicy: (() -> Void)?
    /// The badge text last handed to `onDockBadge`.
    @ObservationIgnored private var dockBadge = ""
    /// Sleep assertion while agents work (spec §5.2); tests swap it before the first event.
    @ObservationIgnored public lazy var keepAwake = KeepAwake()
    /// GitHub releases (#86); its record lives next to state.json. Nothing is read until `start()` (main.swift).
    @ObservationIgnored public lazy var updates: UpdateModel = {
        let model = UpdateModel(stateDir: URL(fileURLWithPath: (socketPath as NSString).deletingLastPathComponent))
        model.enabled = { [weak self] in self?.config.checkUpdates ?? false }
        return model
    }()
    /// Subscription limits from the statusline / codex; in memory only.
    var usage = UsageBoard()
    /// A leaf's agent turned `done` (the inspector refreshes the visible task's changes).
    @ObservationIgnored var onLeafDone: ((UUID) -> Void)?
    /// Limit thresholds crossed (Task 11).
    @ObservationIgnored var onUsageAlerts: (([UsageAlert]) -> Void)?
    /// A codex turn ended: time to refresh its limits (wired to `refreshCodexUsage(afterTurn: true)` in init).
    @ObservationIgnored var onCodexTurn: (() -> Void)?
    /// A host's master is up: waiting and detached leaves of that host launch (set by `TerminalArea`).
    @ObservationIgnored var onHostConnected: ((String) -> Void)?
    /// File tabs with unsaved edits (the tab's dot) and their tsserver status (the status bar), by editor leaf (#83).
    var editorDirty: Set<UUID> = []
    var editorLanguage: [UUID: LanguageStatus] = [:]
    /// Moves an existing file tab's cursor (a line and column) and focuses it; set by `TerminalArea`.
    @ObservationIgnored var onOpenInEditor: ((UUID, String, Int?, Int?) -> Void)?
    /// Settings → Editor changed: every editor and diff page restyles (set by `TerminalArea`).
    @ObservationIgnored var onEditorAppearance: ((EditorAppearance) -> Void)?
    /// Unsaved files of an editor leaf (set by `TerminalArea`, which holds the editors).
    @ObservationIgnored var editorUnsaved: ((UUID) -> [String])?
    /// TS/JS language features of the editors (tsserver, #82).
    @ObservationIgnored lazy var languages: Languages = makeLanguages()
    /// `node` from the login shell, looked up once (#82).
    @ObservationIgnored var localNode: Task<String?, Never>?
    /// The login shell's PATH, looked up once (language servers, #90).
    @ObservationIgnored var loginPath: Task<String?, Never>?
    /// Asks before the diff tab drops an edited buffer (set by `TerminalArea` with the diff editor).
    @ObservationIgnored var confirmLeaveDiff: ((@escaping () -> Void) -> Void)?
    /// Diff tabs with an edited, unsaved working file (quitting asks).
    @ObservationIgnored var diffUnsaved: (() -> Int)?
    /// Files / Changes of the visible task (stage 4).
    let inspector = InspectorModel()
    /// `+N −M` of the sidebar's session rows.
    let sessionBadges = SessionBadges()
    #if DEBUG
    /// Debug hook: the sidebar row drawn as hovered (snapshots can't hover).
    var debugHover: ActionTarget?
    #endif
    /// The inspector's Git tab (fed by `InspectorWatch` like the inspector).
    let gitPanel = GitPanelModel()
    /// The inspector's Search tab (find in files, #91).
    let search = SearchModel()
    /// The temporary diff tab per task (decision #44); in memory only, never in `state.json`.
    var diffTabs: [UUID: DiffTab] = [:]
    @ObservationIgnored let diffCache = DiffContentCache()
    /// `now` for limits and limit-red dots: advanced on app activation, popover open, ↻ and new data — no ticking clock.
    var usageClock = Date()
    var limitsPopoverShown = false
    var inboxShown = false
    /// `now` for «3 мин» in the inbox: taken when it opens, no ticking clock.
    var inboxClock = Date()
    /// «Сессии» (⌘Y) is shown for this project instead of the session area; nil = hidden (SessionsModel.swift).
    var sessionsProjectId: UUID?
    /// Reads codex limits; nil = codex not installed (no Codex row). Default: finds codex on first use.
    @ObservationIgnored var codexRead: (() async throws -> AgentUsage)?
    @ObservationIgnored var codexGate = CodexRefreshGate()
    /// Injectable for tests.
    @ObservationIgnored var clock: () -> Date = Date.init
    @ObservationIgnored var beep: () -> Void = { NSSound.beep() }
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Finds the codex executable (login shell); injectable for tests.
    @ObservationIgnored lazy var findCodex: () async -> String? = { [userShell] in await resolveCodex(runner: .local, shell: userShell) }
    /// Uptime of the last popover close; a click within 0.3 s is that close's own mouse-up.
    @ObservationIgnored var limitsPopoverClosedAt: TimeInterval?
    @ObservationIgnored var inboxClosedAt: TimeInterval?
    /// The last lookup found no codex: look again on the next popover open.
    @ObservationIgnored var codexNotFound = false
    /// CLI/MCP `tasks create` calls in progress: like the new-task sheet's create, they hold off ⌘Q.
    private(set) var controlCreating = 0
    /// Starts, types into and reads terminals for CLI/MCP; set by the terminal area.
    @ObservationIgnored var terminals: TerminalAccess?
    /// Runtime only, never saved; not observed (written on keystrokes).
    @ObservationIgnored private var interaction: Interaction = .typing

    /// Last user interaction for F2; a clicked target that no longer exists counts as `.typing`.
    var lastInteraction: Interaction {
        guard case .chromeClick(let target) = interaction else { return .typing }
        let exists = switch target {
        case .task(let id): state.tasks.contains { $0.id == id }
        case .project(let id): project(id) != nil
        case .tab(let task, let tab): state.tasks.first { $0.id == task }?.tabs.contains { $0.id == tab } == true
        }
        return exists ? interaction : .typing
    }

    /// Click on a sidebar row or tab: remembered as the F2 target; the keyboard stays where it was.
    func chromeClicked(_ target: ActionTarget) { interaction = .chromeClick(target) }

    /// A key event went on to a terminal or text field (called by the key monitor).
    func keyReachedTerminal() { if interaction != .typing { interaction = .typing } }

    /// Hangar consumed a non-F2 shortcut (⌘T, ⌘D, …): the earlier row/tab click is no longer F2's target.
    func hangarShortcutConsumed() { keyReachedTerminal() }

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored let socketPath: String
    @ObservationIgnored let userShell: String
    /// First message from the new-task sheet, consumed when the leaf's surface starts (decision #29).
    @ObservationIgnored var pendingPrompts: [UUID: String] = [:]
    /// Leaves from state.json or an unarchived task → whether they are in the resume set (`resumeSet`).
    @ObservationIgnored private var restoredLeaves: [UUID: Bool] = [:]
    /// The remote tmux kills the last `perform` started.
    @ObservationIgnored var lastKills: [Task<Void, Never>] = []
    /// Called after every mutation (AppKit parts that don't use Observation sync from here).
    @ObservationIgnored var didChange: (() -> Void)?
    /// AppKit parts that build strings once (main menu) rebuild from here.
    @ObservationIgnored var languageDidChange: (() -> Void)?
    @ObservationIgnored let configURL: URL
    /// Past conversations («Сессии»), cached per file across scans.
    @ObservationIgnored let history = ConversationHistory()
    /// Agent integration files (Settings); DEBUG runs point them at temp copies (main.swift).
    @ObservationIgnored public var claudeSettingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    @ObservationIgnored public var codexConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from the login shell (they move the files above); nil keeps the URLs as set.
    @ObservationIgnored public lazy var findAgentDirs: (() async -> (claude: String?, codex: String?))? = { [userShell] in
        await resolveAgentDirs(runner: .local, shell: userShell)
    }
    /// Connect upgrades an older `hangar-remote` and the Claude hooks on the server (#96); DEBUG: only with a fake ssh.
    @ObservationIgnored public var autoUpgradeRemote = true
    /// ssh binary for remote hosts; DEBUG runs may point it at a fake (`HANGAR_SSH`, main.swift) before first use.
    @ObservationIgnored public var sshPath = "/usr/bin/ssh"
    /// The user's ssh config (read-only): its `Host` names fill the remote-project drop-down; DEBUG: `HANGAR_SSH_CONFIG`.
    @ObservationIgnored public var sshConfigPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    /// `Host` names of the ssh config for the SSH HOSTS section (#64); read at launch and on activation.
    var configHostList: [String] = []
    /// Leaves whose tmux session is to be killed once their host is connected again (closed/archived while offline).
    // shortcut: in memory only; a quit or the host's removal while offline leaves those sessions on the server.
    @ObservationIgnored var pendingKills: [String: Set<UUID>] = [:]
    /// `tabs send --wait` callers waiting for their leaf to turn `working`, by waiter token.
    @ObservationIgnored var workingWaiters: [UUID: (leaf: UUID, done: CheckedContinuation<Bool, Never>)] = [:]
    /// How long `tabs send --wait` waits for the turn to start; tests shorten it.
    @ObservationIgnored var sendWaitTimeout: Duration = .seconds(ControlMethod.sendWaitSeconds)
    /// A host's state changed (leaf bars of AppKit views; set by `TerminalArea`).
    @ObservationIgnored var onHostChange: ((String) -> Void)?
    /// ssh hosts of remote projects (#47); tests replace it with `makeRemoteHosts(...)`.
    @ObservationIgnored public lazy var remote: RemoteHosts = makeRemoteHosts(
        paths: SSHPaths(stateDir: (socketPath as NSString).deletingLastPathComponent), sshPath: sshPath,
        isActive: { NSApp?.isActive ?? false })

    public init(state: WorkspaceState, store: StateStore, config: HangarConfig, configURL: URL,
                socketPath: String = defaultStateDirectoryPath() + "/hangar.sock") {
        self.state = state
        self.store = store
        self.config = config
        self.configURL = configURL
        Theme.current = config.theme
        L10n.language = config.language
        userShell = resolveUserShell(passwd: getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) },
                                     env: ProcessInfo.processInfo.environment["SHELL"])
        self.socketPath = socketPath
        markRestored(state.tasks.filter { !$0.archived })
        codexRead = lazyCodexRead()
        onCodexTurn = { [weak self] in Task { await self?.refreshCodexUsage(afterTurn: true) } }
        inspector.onDiffApplied = { [weak self] in self?.pruneDiffSelection() }
        inspector.onStatusLoad = { [weak self] id in self?.refreshBadge(taskId: id) }
        search.launcher = { [weak self] q, target, column in await self?.searchLaunch(q, target, gitColumn: column) }
        search.currentTarget = { [weak self] in self?.searchTarget }
    }

    func isRestored(leafId: UUID) -> Bool { restoredLeaves[leafId] == true }

    /// Judged against every live task, as `spec(for:)` does: an unarchived task's neighbours in its folders count (#89).
    private func markRestored(_ tasks: [HangarTask]) {
        let resuming = resumeSet(for: state)
        for task in tasks {
            for leaf in task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap({ $0 }) {
                restoredLeaves[leaf.id] = resuming.contains(leaf.id)
            }
        }
    }

    /// Context of a leaf's first launch in its view; the new-task prompt is consumed here.
    func launchContext(for leafId: UUID) -> LaunchContext {
        if let prompt = pendingPrompts.removeValue(forKey: leafId) { return .created(prompt: prompt) }
        return restoredLeaves[leafId].map { .restored(inResumeSet: $0) } ?? .created(prompt: nil)
    }

    /// Saves right away (quit): the debounce would not fire.
    public func saveNow() {
        do { try store.saveNow(state) } catch { uiLog.error("state save on quit failed: \(String(describing: error), privacy: .public)") }
    }

    public func perform(_ mutate: (inout WorkspaceState) -> Void) {
        let remoteBefore = liveRemoteLeaves()
        let hostsBefore = Set(state.projects.compactMap(\.host))
        let selectedBefore = state.selectedTaskId
        mutate(&state)
        // Archived or closed leaves drop their status (and their attention) here.
        let live = liveLeafIds
        // A host whose last project went is forgotten (after its sessions are killed).
        lastKills = killSessions(of: remoteBefore.filter { !live.contains($0.key) }, removing: hostsBefore.subtracting(state.projects.compactMap(\.host)))
        let dropped = statuses.leaves.filter { !live.contains($0.key) }
        if !dropped.isEmpty {
            statuses.retain(live)
            for (id, s) in dropped where s.attention != nil { onAttention?(id, nil) }
        }
        // Archived or deleted tasks drop their diff tab.
        if diffTabs.keys.contains(where: { id in !state.tasks.contains { $0.id == id && !$0.archived } }) {
            diffTabs = diffTabs.filter { entry in state.tasks.contains { $0.id == entry.key && !$0.archived } }
        }
        // Another session getting selected (palette, a new or restored one) leaves «Сессии».
        if state.selectedTaskId != selectedBefore, state.selectedTaskId != nil { sessionsProjectId = nil }
        store.scheduleSave(state)
        didChange?()
    }

    // MARK: Queries

    var selectedTask: HangarTask? {
        state.selectedTaskId.flatMap { id in state.tasks.first { $0.id == id && !$0.archived } }
    }

    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

    /// Changes are compared with this (decision #44): a worktree task's `base`, else the project's last base or default branch.
    func baseBranch(of task: HangarTask) async -> String? {
        if case .worktree(_, _, let base) = task.mode { return base }
        guard let project = project(task.projectId) else { return nil }
        if let last = project.lastBaseBranch { return last }
        return try? await git(for: project).defaultBranch()
    }

    /// Branches of the project's worktree tasks (archived too: archive keeps the branch), labelled in the base picker.
    func taskBranches(_ projectId: UUID) -> Set<String> {
        Set(state.tasks.filter { $0.projectId == projectId }.compactMap(\.branch))
    }

    /// Pinned tasks (any project), shown only in the PINNED section.
    var pinnedTasks: [HangarTask] { state.projects.flatMap { state.tasks(in: $0.id).filter(\.pinned) } }

    /// Unpinned active tasks of a project, in order.
    func groupTasks(_ projectId: UUID) -> [HangarTask] { state.tasks(in: projectId).filter { !$0.pinned } }

    var archivedTasks: [HangarTask] { state.tasks.filter(\.archived) }

    /// Visible tasks in sidebar order: pinned, then each expanded project's group.
    var orderedTasks: [HangarTask] { pinnedTasks + state.projects.filter { !$0.collapsed }.flatMap { groupTasks($0.id) } }

    func defaultTitle(_ kind: LeafKind) -> String {
        switch kind {
        case .claude, .codex: kind.rawValue
        case .editor: L10n.editor
        case .shell: (userShell as NSString).lastPathComponent
        case .choose: L10n.paneNew
        }
    }

    /// A file tab is its file's name (#83; «Editor» without one); others go by their terminal title.
    func title(of leaf: Leaf) -> String {
        if leaf.kind == .editor { return leaf.openFile.map { ($0 as NSString).lastPathComponent } ?? defaultTitle(.editor) }
        return leafTitles[leaf.id] ?? defaultTitle(leaf.kind)
    }

    func tabLabel(_ tab: Tab) -> String { tab.label(auto: tab.root.leaves.map(title(of:)).joined(separator: " │ ")) }

    /// Tooltip title: an unsplit, unrenamed editor tab shows its active file's path from the session folder; others their label.
    func tabHelpTitle(_ tab: Tab, taskId: UUID) -> String {
        guard case .leaf(let leaf) = tab.root, leaf.kind == .editor, let file = leaf.openFile,
              tab.customTitle == nil else { return tabLabel(tab) }
        let root = path(of: .task(taskId)).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return root.flatMap { file.hasPrefix($0) ? String(file.dropFirst($0.count)) : nil } ?? file
    }

    /// Folder an action opens/copies: the task's worktree or project folder.
    /// The task's `HANGAR_PORT` (#60); projects and tabs have none.
    func port(of target: ActionTarget) -> Int? {
        guard case .task(let id) = target else { return nil }
        return state.tasks.first { $0.id == id }?.port
    }

    func path(of target: ActionTarget) -> String? {
        switch target {
        case .project(let id): return project(id)?.path
        case .task(let id):
            guard let task = state.tasks.first(where: { $0.id == id }) else { return nil }
            if case .worktree(let path, _, _) = task.mode { return path }
            return project(task.projectId)?.path
        case .tab: return nil
        }
    }

    /// Current name shown in the inline rename field.
    func name(of target: ActionTarget) -> String {
        switch target {
        case .project(let id): return project(id)?.name ?? ""
        case .task(let id): return state.tasks.first { $0.id == id }?.name ?? ""
        case .tab(let task, let tab):
            return state.tasks.first { $0.id == task }?.tabs.first { $0.id == tab }.map(tabLabel) ?? ""
        }
    }

    /// Spec for one launch of `leaf` (its current model version: cwd may have moved since the view was made).
    func spec(for leaf: Leaf, tabId: UUID, context: LaunchContext) throws -> (LaunchSpec, LaunchMode) {
        let leaf = self.leaf(id: leaf.id) ?? leaf
        var mode = launchMode(for: leaf, context)
        // ↩ resumes too: a second agent leaf in the folder without a session id would `--continue` the first one's chat.
        if mode.restoring, leaf.kind == .claude || leaf.kind == .codex, !resumeSet(for: state).contains(leaf.id) { mode.restoring = false }
        // Tabs and the drawer alike get the task's port (#60).
        let port = state.tasks.first { $0.drawer.leaf?.id == leaf.id || $0.tabs.contains { $0.root.leaf(id: leaf.id) != nil } }?.port
        uiLog.info("launch leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public) restoring=\(mode.restoring) prompt=\(mode.initialPrompt != nil)")
        if let host = hostShellHost(ofLeaf: leaf.id) {
            // state.json is editable: a host that is not safe on an ssh command line never launches.
            guard let host = validSSHHost(host) else { throw LaunchError.missingCwd(host) }
            return (sshShellSpec(host: host, sshPath: sshPath), mode)
        }
        if let host = remoteLeafHost(leaf.id) {
            guard let target = remote.target(host) else {
                Task { await remote.connect(host) }
                throw LaunchError.notConnected(host: host)
            }
            return (remoteLaunchSpec(for: leaf, tabId: tabId, target: target,
                                     restoring: mode.restoring, initialPrompt: mode.initialPrompt, port: port), mode)
        }
        let spec = try launchSpec(for: leaf, tabId: tabId, config: config, socketPath: socketPath,
                                  userShell: userShell, restoring: mode.restoring, initialPrompt: mode.initialPrompt, port: port)
        return (spec, mode)
    }

    func leaf(id: UUID) -> Leaf? {
        for task in state.tasks {
            if task.drawer.leaf?.id == id { return task.drawer.leaf }
            for tab in task.tabs { if let leaf = tab.root.leaf(id: id) { return leaf } }
        }
        return nil
    }

    /// Task and tab that own the leaf.
    func location(ofLeaf leafId: UUID) -> (task: UUID, tab: UUID)? {
        for task in state.tasks {
            for tab in task.tabs where tab.root.leaf(id: leafId) != nil { return (task.id, tab.id) }
        }
        return nil
    }

    func location(ofTab tabId: UUID) -> UUID? {
        state.tasks.first { $0.tabs.contains { $0.id == tabId } }?.id
    }

    // MARK: Actions

    @discardableResult func addProject(path: String) -> UUID {
        var id = UUID()
        perform { id = $0.addProject(name: (path as NSString).lastPathComponent, path: path) }
        return id
    }

    /// The new-task sheet remembers its choice (worktree toggle, base) for the next task in this project.
    /// `select: false` (CLI/MCP) leaves the selected task and the sheet's remembered choice as they are (decision #45).
    @discardableResult
    /// `setup` (a new worktree's `NewTaskModel.setupScript`) runs in a second, shell tab started at once behind the agent's.
    func createTask(projectId: UUID, name: String, firstMessage: String, mode: TaskMode, select: Bool = true,
                    setup: String? = nil) -> (task: UUID, tab: UUID) {
        var created = (task: UUID(), tab: UUID())
        var setupTab: UUID?
        perform { s in
            let task = s.addTask(projectId: projectId, name: name, mode: mode)
            var base: String?
            if case .worktree(_, _, let b) = mode { base = b }
            if select {
                s.rememberNewTaskChoice(projectId: projectId, worktree: mode != .mainFolder, base: base)
                s.select(taskId: task)
            }
            let tab = s.addTab(taskId: task, kind: config.defaultAgent)
            created = (task, tab)
            let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty, let leaf = s.tasks.last?.tabs.first(where: { $0.id == tab })?.root.leaves.first {
                pendingPrompts[leaf.id] = message
            }
            if let setup, let i = s.tasks.firstIndex(where: { $0.id == task }) {
                let shell = s.addTab(taskId: task, kind: .shell)
                s.tasks[i].activeTabId = tab
                if let leaf = s.tasks[i].tabs.first(where: { $0.id == shell })?.root.leaves.first { pendingPrompts[leaf.id] = setup }
                setupTab = shell
            }
        }
        if let setupTab { terminals?.start(setupTab) }
        return created
    }

    /// Runs a CLI/MCP task creation, counted in `controlCreating` while it lasts (git may be running).
    func countingCreation<T>(_ work: () async -> T) async -> T {
        controlCreating += 1
        defer { controlCreating -= 1 }
        return await work()
    }

    /// Also the already selected one: a click on it leaves «Сессии».
    func select(taskId: UUID) {
        sessionsProjectId = nil
        perform { $0.select(taskId: taskId) }
    }

    /// Ends inline editing; blank text keeps the old name (the model rejects it).
    func commitRename(_ target: ActionTarget, _ text: String) {
        if renaming == target { renaming = nil }
        perform { s in
            switch target {
            case .task(let id): s.renameTask(id: id, name: text)
            case .project(let id): s.renameProject(id: id, name: text)
            case .tab(let task, let tab): s.renameTab(taskId: task, tabId: tab, title: text)
            }
        }
    }

    func cancelRename() {
        renaming = nil
        didChange?()
    }

    /// Drag within a project group: `index` is among the group's other (unpinned) tasks; pinned siblings keep their slots.
    func moveTask(_ id: UUID, toGroupIndex index: Int) {
        guard let task = state.tasks.first(where: { $0.id == id }) else { return }
        let others = groupTasks(task.projectId).filter { $0.id != id }
        let all = state.tasks(in: task.projectId).map(\.id).filter { $0 != id }
        guard let last = others.last, let lastSlot = all.firstIndex(of: last.id) else { return }
        let slot = index < others.count ? all.firstIndex(of: others[max(index, 0)].id) ?? lastSlot + 1 : lastSlot + 1
        perform { $0.moveTask(id: id, to: slot) }
    }

    func moveProject(_ id: UUID, to index: Int) { perform { $0.moveProject(id: id, to: index) } }
    func archive(taskId: UUID) { perform { $0.archiveTask(id: taskId) } }
    /// Unarchived agents resume like at startup (their surfaces were closed by the archive).
    /// `fresh` (detached from its worktree): the leaves start anew instead of resuming.
    func restore(taskId: UUID, fresh: Bool = false) {
        perform { $0.restoreTask(id: taskId) }
        let tasks = state.tasks.filter { $0.id == taskId }
        if fresh {
            for leaf in tasks.flatMap({ $0.tabs.flatMap(\.root.leaves) + [$0.drawer.leaf].compactMap { $0 } }) { restoredLeaves[leaf.id] = nil }
        } else {
            markRestored(tasks)
        }
    }
    func setPinned(_ taskId: UUID, _ pinned: Bool) { perform { $0.setPinned(taskId: taskId, pinned) } }
    func setCollapsed(projectId: UUID, _ collapsed: Bool) { perform { $0.setProjectCollapsed(id: projectId, collapsed) } }

    func addTab(_ kind: LeafKind) {
        guard let task = selectedTask else { return }
        deactivateDiff()
        perform { $0.addTab(taskId: task.id, kind: kind) }
    }

    /// Opens a past conversation as a new tab of the selected session: the leaf starts restored with its id,
    /// so the usual resume launch runs `claude --resume <id>` / `codex resume <id>`.
    func openConversation(_ c: Conversation) {
        guard let task = selectedTask, let id = validSessionId(c.id) else { return }
        deactivateDiff()
        var leafId: UUID?
        perform { leafId = $0.addResumeTab(taskId: task.id, kind: c.agent == .claude ? .claude : .codex, cwd: c.cwd, sessionId: id) }
        if let leafId { restoredLeaves[leafId] = true }
    }

    func activate(tabId: UUID) {
        guard let task = selectedTask else { return }
        deactivateDiff()
        perform { s in
            if let i = s.tasks.firstIndex(where: { $0.id == task.id }) { s.tasks[i].activeTabId = tabId }
        }
    }

    /// Files, Changes, ⌘P, diff ↩, links, Go to Definition: the file's own tab in the selected task (#83) — focused if
    /// open, else new (`preview`: a Files click, which reuses the task's preview tab). Without a selected task — nothing.
    func openInEditor(path: String, line: Int?, column: Int? = nil, preview: Bool = false) {
        guard let task = selectedTask else { return }
        deactivateDiff()  // the file's tab is shown instead
        var opened: (tab: UUID, leaf: UUID)?
        perform { opened = $0.openFileTab(taskId: task.id, path: path, line: line, column: column, preview: preview) }
        guard let opened else { return }
        activate(tabId: opened.tab)
        onOpenInEditor?(opened.leaf, path, line, column)
    }

    /// A file tab's buffer became dirty or clean: its dot; the first edit pins a preview tab.
    func editorDirtyChanged(leafId: UUID, dirty: Bool) {
        if dirty { editorDirty.insert(leafId) } else { editorDirty.remove(leafId) }
        guard dirty, let loc = location(ofLeaf: leafId),
              state.tasks.first(where: { $0.id == loc.task })?.tabs.first(where: { $0.id == loc.tab })?.preview == true else { return }
        perform { $0.pinTab(taskId: loc.task, tabId: loc.tab) }
    }

    /// ⌥⌘1 / ⌥⌘2 / ⌥⌘3, ⇧⌘F and the status line's change counter: shows the inspector on that segment. Changes and Git
    /// only for git projects; while the inspector hasn't loaded this task yet, its load resets a non-git one to Files.
    func showInspector(_ segment: InspectorModel.Segment) {
        guard let task = selectedTask else { return }
        if segment == .changes || segment == .git, inspector.shownTaskId == task.id, !inspector.isGit { return }
        inspector.segment = segment
        if !state.inspectorVisible { perform { $0.inspectorVisible = true } }
    }

    /// ⌘1…8: n-th tab of the selected task; ⌘9: its last tab.
    func activate(tabNumber n: Int) {
        guard let task = selectedTask, let i = tabIndex(number: n, count: task.tabs.count) else { return }
        activate(tabId: task.tabs[i].id)
    }

    /// ⌘⇧[ / ⌘⇧]: previous/next task in sidebar order, wrapping around.
    func selectTask(offset: Int) {
        let tasks = orderedTasks
        guard !tasks.isEmpty else { return }
        let current = tasks.firstIndex { $0.id == state.selectedTaskId }
        let next = current.map { ($0 + offset + tasks.count) % tasks.count } ?? (offset > 0 ? 0 : tasks.count - 1)
        select(taskId: tasks[next].id)
    }

    func closeLeaf(_ leafId: UUID) {
        guard let loc = location(ofLeaf: leafId) else { return }
        perform { $0.closeLeaf(taskId: loc.task, tabId: loc.tab, leafId: leafId) }
    }

    /// Splits `leafId` (the focused leaf) with a new shell in the task's cwd.
    func split(leafId: UUID, axis: Workspace.Axis) {
        guard let loc = location(ofLeaf: leafId) else { return }
        perform { $0.split(taskId: loc.task, tabId: loc.tab, leafId: leafId, axis: axis, kind: .shell) } // chooser arrives in Task 4
    }

    func setTitle(_ title: String, leafId: UUID) { leafTitles[leafId] = title }

    /// A surface got keyboard focus: the model's focused leaf follows (⌘D splits it; restored on launch).
    func focused(leafId: UUID) {
        onLeafSeen?(leafId)
        guard let loc = location(ofLeaf: leafId),
              state.tasks.first(where: { $0.id == loc.task })?.tabs.first(where: { $0.id == loc.tab })?.focusedLeafId != leafId
        else { return }
        perform { $0.setFocusedLeaf(taskId: loc.task, tabId: loc.tab, leafId: leafId) }
    }

    // MARK: Settings

    var language: Language { config.language }

    /// Writes only `key` in config.toml, then applies the change; a failed write changes nothing.
    func setConfig(_ key: String, _ value: String, apply: (inout HangarConfig) -> Void) throws {
        try HangarConfig.save(key: key, value: value, to: configURL)
        apply(&config)
        uiLog.info("config \(key, privacy: .public) = \(value, privacy: .public)")
    }

    /// Bare `true` / `false` key (notifications).
    func setConfig(_ key: String, flag: Bool, apply: (inout HangarConfig) -> Void) throws {
        try HangarConfig.save(key: key, literal: flag ? "true" : "false", to: configURL)
        apply(&config)
        uiLog.info("config \(key, privacy: .public) = \(flag)")
    }

    private func updateKeepAwake() { keepAwake.update(working: workingLeafCount, enabled: config.keepAwake) }

    /// Called on status and setting changes only (no timer); hands the label over only when it changes.
    func updateDockBadge() {
        guard let onDockBadge else { return }
        let label = dockBadgeLabel(count: attentionCount(attentionItems), enabled: config.dockBadge)
        guard label != dockBadge else { return }
        dockBadge = label
        onDockBadge(label)
    }

    /// Settings → Оформление, live: SwiftUI observes `Theme.current`, AppKit views get `hangarThemeDidChange`,
    /// open terminals and editor pages are reconfigured.
    func setTheme(_ theme: AppTheme) throws {
        try setConfig("theme", theme.rawValue) { $0.theme = theme }
        Theme.current = theme
        applyTerminalColors()
        onEditorAppearance?(EditorAppearance(config))
    }

    func setTerminalBackground(_ background: HangarConfig.TerminalBackground) throws {
        try setConfig("terminal_background", background.rawValue) { $0.terminalBackground = background }
        applyTerminalColors()
    }

    private func applyTerminalColors() {
        GhosttyApp.shared.update(colors: Theme.terminalColors(force: config.terminalBackground == .hangar))
    }

    func setLanguage(_ language: Language) throws {
        try setConfig("language", language.rawValue) { $0.language = language }
        L10n.language = language
        languageDidChange?()
        didChange?()
    }
}

/// `NSDockTile.badgeLabel`: the count, or "" (no badge) at 0 or when turned off.
func dockBadgeLabel(count: Int, enabled: Bool) -> String { enabled && count > 0 ? String(count) : "" }

/// Text of the alert shown at launch for a problem with state.json; nil when there is nothing to tell.
@MainActor public func loadAlert(for result: LoadResult) -> String? {
    switch result {
    case .empty, .loaded: nil
    case .recoveredFromCorrupt(let backup): L10n.stateCorrupt(backup.path)
    case .unreadable(let url): L10n.stateUnreadable(url.path)
    }
}

/// Leaves of `tasks` that start with `restoring: true`; callers pass all live tasks (startup, unarchive and every launch).
/// Without per-tab session ids `--continue` / `resume --last` pick the latest conversation in a cwd, so at most one
/// claude/codex leaf without an id per (kind, host, cwd) continues, and only if no leaf there has an id (#89): that
/// leaf's conversation is likely the latest one, and `--continue` would attach a second tab to it. The rest start fresh.
/// Leaves with an id always resume; shell and editor leaves are always restored. `host`: a project's ssh host, nil if local.
func resumeSet(for state: WorkspaceState) -> Set<UUID> {
    resumeSet(for: state.tasks.filter { !$0.archived }, host: { id in state.projects.first { $0.id == id }?.host })
}

func resumeSet(for tasks: [HangarTask], host: (UUID) -> String?) -> Set<UUID> {
    struct Key: Hashable { var kind: LeafKind; var host: String?; var cwd: String }
    var agents: [(leaf: Leaf, key: Key)] = []
    var result = Set<UUID>()
    for task in tasks {
        let host = host(task.projectId)
        for leaf in task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap({ $0 }) {
            switch leaf.kind {
            case .shell, .editor, .choose: result.insert(leaf.id)
            case .claude, .codex:
                var cwd = leaf.cwd
                while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
                agents.append((leaf, Key(kind: leaf.kind, host: host, cwd: cwd)))
            }
        }
    }
    // A folder with a known conversation has no `--continue` slot left.
    var claimed = Set(agents.filter { validSessionId($0.leaf.agentSessionId) != nil }.map(\.key))
    for (leaf, key) in agents {
        if validSessionId(leaf.agentSessionId) != nil || claimed.insert(key).inserted { result.insert(leaf.id) }
    }
    return result
}

/// Index of the tab ⌘<number> selects among `count` tabs: 1…8 by position, 9 the last one (as VS Code and browsers).
func tabIndex(number n: Int, count: Int) -> Int? {
    let i = n == 9 ? count - 1 : n - 1
    return (0..<count).contains(i) ? i : nil
}
