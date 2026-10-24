import AgentStatus
import AppKit
import ControlServer
import Exec
import Git
import Integration
import Observation
import os
import Power
import Usage
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
    /// A leaf started waiting: bounce the Dock once if the app is inactive (set by the window controller).
    @ObservationIgnored var requestAttention: (() -> Void)?
    /// The badge text last handed to `onDockBadge`.
    @ObservationIgnored private var dockBadge = ""
    /// Sleep assertion while agents work (spec §5.2); tests swap it before the first event.
    @ObservationIgnored public lazy var keepAwake = KeepAwake()
    /// Subscription limits from the statusline / codex; in memory only.
    var usage = UsageBoard()
    /// `message` of the leaf's last hook event (notification body).
    var lastNotificationMessage: [UUID: String] = [:]
    /// A leaf's agent state changed (notifications, Task 9).
    @ObservationIgnored var onTransition: ((Transition) -> Void)?
    /// A leaf's agent turned `done` (the inspector refreshes the visible task's changes).
    @ObservationIgnored var onLeafDone: ((UUID) -> Void)?
    /// Limit thresholds crossed (Task 11).
    @ObservationIgnored var onUsageAlerts: (([UsageAlert]) -> Void)?
    /// A codex turn ended: time to refresh its limits (wired to `refreshCodexUsage(afterTurn: true)` in init).
    @ObservationIgnored var onCodexTurn: (() -> Void)?
    /// A host's master is up: waiting and detached leaves of that host launch (set by `TerminalArea`).
    @ObservationIgnored var onHostConnected: ((String) -> Void)?
    /// Opens an absolute path (optionally at a line) in the selected task's editor; set by `TerminalArea`.
    @ObservationIgnored var onOpenInEditor: ((String, Int?) -> Void)?
    /// Files / Changes of the visible task (stage 4).
    let inspector = InspectorModel()
    /// The temporary diff tab per task (decision #44); in memory only, never in `state.json`.
    var diffTabs: [UUID: DiffTab] = [:]
    @ObservationIgnored let diffCache = DiffContentCache()
    /// `now` for limits and limit-red dots: advanced on app activation, popover open, ↻ and new data — no ticking clock.
    var usageClock = Date()
    var limitsPopoverShown = false
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
    /// Agent integration files (Settings); DEBUG runs point them at temp copies (main.swift).
    @ObservationIgnored public var claudeSettingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    @ObservationIgnored public var codexConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    /// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` from the login shell (they move the files above); nil keeps the URLs as set.
    @ObservationIgnored public lazy var findAgentDirs: (() async -> (claude: String?, codex: String?))? = { [userShell] in
        await resolveAgentDirs(runner: .local, shell: userShell)
    }
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
    /// Ghostty took this background at launch; a change applies after restart.
    @ObservationIgnored let launchTerminalBackground: HangarConfig.TerminalBackground

    public init(state: WorkspaceState, store: StateStore, config: HangarConfig, configURL: URL,
                socketPath: String = defaultStateDirectoryPath() + "/hangar.sock") {
        self.state = state
        self.store = store
        self.config = config
        self.configURL = configURL
        launchTerminalBackground = config.terminalBackground
        L10n.language = config.language
        userShell = resolveUserShell(passwd: getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) },
                                     env: ProcessInfo.processInfo.environment["SHELL"])
        self.socketPath = socketPath
        markRestored(state.tasks.filter { !$0.archived })
        codexRead = lazyCodexRead()
        onCodexTurn = { [weak self] in Task { await self?.refreshCodexUsage(afterTurn: true) } }
        inspector.onDiffApplied = { [weak self] in self?.pruneDiffSelection() }
    }

    func isRestored(leafId: UUID) -> Bool { restoredLeaves[leafId] == true }

    private func markRestored(_ tasks: [HangarTask]) {
        let resuming = resumeSet(for: tasks)
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
        mutate(&state)
        // Archived or closed leaves drop their status (and their message) here.
        let live = liveLeafIds
        // A host whose last project went is forgotten (after its sessions are killed).
        lastKills = killSessions(of: remoteBefore.filter { !live.contains($0.key) }, removing: hostsBefore.subtracting(state.projects.compactMap(\.host)))
        if statuses.leaves.keys.contains(where: { !live.contains($0) }) { statuses.retain(live) }
        if lastNotificationMessage.keys.contains(where: { !live.contains($0) }) {
            lastNotificationMessage = lastNotificationMessage.filter { live.contains($0.key) }
        }
        // Archived or deleted tasks drop their diff tab.
        if diffTabs.keys.contains(where: { id in !state.tasks.contains { $0.id == id && !$0.archived } }) {
            diffTabs = diffTabs.filter { entry in state.tasks.contains { $0.id == entry.key && !$0.archived } }
        }
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
        case .editor: (config.editor as NSString).lastPathComponent
        case .shell: (userShell as NSString).lastPathComponent
        }
    }

    func title(of leaf: Leaf) -> String { leafTitles[leaf.id] ?? defaultTitle(leaf.kind) }

    func tabLabel(_ tab: Tab) -> String { tab.label(auto: tab.root.leaves.map(title(of:)).joined(separator: " │ ")) }

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
            return (remoteLaunchSpec(for: leaf, tabId: tabId, target: target, editor: config.editor,
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

    func select(taskId: UUID) { perform { $0.select(taskId: taskId) } }

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

    func activate(tabId: UUID) {
        guard let task = selectedTask else { return }
        deactivateDiff()
        perform { s in
            if let i = s.tasks.firstIndex(where: { $0.id == task.id }) { s.tasks[i].activeTabId = tabId }
        }
    }

    /// Inspector clicks: the task's Helix, else a new editor tab (decision #44). Without a selected task — nothing.
    func openInEditor(path: String, line: Int?) {
        guard selectedTask != nil else { return }
        deactivateDiff()  // the editor tab (also a new one) is shown instead
        onOpenInEditor?(path, line)
    }

    /// ⌥⌘1 / ⌥⌘2 and the status line's change counter: shows the inspector on that segment. Changes only for git
    /// projects; while the inspector hasn't loaded this task yet, its load resets a non-git one to Files.
    func showInspector(_ segment: InspectorModel.Segment) {
        guard let task = selectedTask else { return }
        if segment == .changes, inspector.shownTaskId == task.id, !inspector.isGit { return }
        inspector.segment = segment
        if !state.inspectorVisible { perform { $0.inspectorVisible = true } }
    }

    /// ⌘1…9: n-th tab of the selected task.
    func activate(tabNumber n: Int) {
        guard let task = selectedTask, task.tabs.indices.contains(n - 1) else { return }
        activate(tabId: task.tabs[n - 1].id)
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
        perform { $0.split(taskId: loc.task, tabId: loc.tab, leafId: leafId, axis: axis, kind: .shell) }
    }

    func setTitle(_ title: String, leafId: UUID) { leafTitles[leafId] = title }

    /// A surface got keyboard focus: the model's focused leaf follows (⌘D splits it; restored on launch).
    func focused(leafId: UUID) {
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

    /// Unarchived tasks whose combined state is waiting (archived leaves already dropped their status).
    var waitingTaskCount: Int { state.tasks.filter { !$0.archived && state(of: $0) == .waiting }.count }

    /// Called on status and setting changes only (no timer); hands the label over only when it changes.
    func updateDockBadge() {
        guard let onDockBadge else { return }
        let label = dockBadgeLabel(waiting: waitingTaskCount, enabled: config.dockBadge)
        guard label != dockBadge else { return }
        dockBadge = label
        onDockBadge(label)
    }

    func setLanguage(_ language: Language) throws {
        try setConfig("language", language.rawValue) { $0.language = language }
        L10n.language = language
        languageDidChange?()
        didChange?()
    }
}

/// `NSDockTile.badgeLabel`: the count, or "" (no badge) at 0 or when turned off.
func dockBadgeLabel(waiting: Int, enabled: Bool) -> String { enabled && waiting > 0 ? String(waiting) : "" }

/// Text of the alert shown at launch for a problem with state.json; nil when there is nothing to tell.
@MainActor public func loadAlert(for result: LoadResult) -> String? {
    switch result {
    case .empty, .loaded: nil
    case .recoveredFromCorrupt(let backup): L10n.stateCorrupt(backup.path)
    case .unreadable(let url): L10n.stateUnreadable(url.path)
    }
}

/// Leaves of `tasks` that start with `restoring: true` (at startup: all live tasks; on unarchive: that task).
/// Without per-tab session ids `--continue` / `resume --last` pick the latest conversation in a cwd, so among
/// claude/codex leaves without an id only the first per (kind, cwd) continues; later ones start fresh.
/// Leaves with an id always resume; shell and editor leaves are always restored.
func resumeSet(for state: WorkspaceState) -> Set<UUID> { resumeSet(for: state.tasks.filter { !$0.archived }) }

func resumeSet(for tasks: [HangarTask]) -> Set<UUID> {
    struct Key: Hashable { var kind: LeafKind; var cwd: String }
    var claimed = Set<Key>()
    var result = Set<UUID>()
    func visit(_ leaf: Leaf) {
        switch leaf.kind {
        case .shell, .editor: result.insert(leaf.id)
        case .claude, .codex:
            if validSessionId(leaf.agentSessionId) != nil { result.insert(leaf.id); return }
            if claimed.insert(Key(kind: leaf.kind, cwd: leaf.cwd)).inserted { result.insert(leaf.id) }
        }
    }
    for task in tasks {
        for tab in task.tabs { tab.root.leaves.forEach(visit) }
        if let leaf = task.drawer.leaf { visit(leaf) }
    }
    return result
}
