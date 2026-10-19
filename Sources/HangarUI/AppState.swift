import AppKit
import Exec
import Observation
import os
import Workspace

let uiLog = Logger(subsystem: "dev.hangar", category: "UI")

/// Single source of UI truth. Every model change goes through `perform`, which schedules a debounced save.
@MainActor @Observable public final class AppState {
    public private(set) var state: WorkspaceState
    /// Changed live from Settings (each change is also written to `configURL`).
    public private(set) var config: HangarConfig
    /// Runtime-only (not persisted): last terminal title per leaf.
    var leafTitles: [UUID: String] = [:]
    /// True while the sidebar width animates between rail and expanded.
    var sidebarAnimating = false
    /// Row or tab currently edited inline (F2 / double-click).
    var renaming: ActionTarget?
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
    @ObservationIgnored private var pendingPrompts: [UUID: String] = [:]
    /// Leaves from state.json or an unarchived task → whether they are in the resume set (`resumeSet`).
    @ObservationIgnored private var restoredLeaves: [UUID: Bool] = [:]
    /// Called after every mutation (AppKit parts that don't use Observation sync from here).
    @ObservationIgnored var didChange: (() -> Void)?
    /// AppKit parts that build strings once (main menu) rebuild from here.
    @ObservationIgnored var languageDidChange: (() -> Void)?
    @ObservationIgnored let configURL: URL
    /// Ghostty took this background at launch; a change applies after restart.
    @ObservationIgnored let launchTerminalBackground: HangarConfig.TerminalBackground

    public init(state: WorkspaceState, store: StateStore, config: HangarConfig, configURL: URL) {
        self.state = state
        self.store = store
        self.config = config
        self.configURL = configURL
        launchTerminalBackground = config.terminalBackground
        L10n.language = config.language
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        userShell = shell.isEmpty ? "/bin/zsh" : shell
        socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hangar/hangar.sock").path
        markRestored(state.tasks.filter { !$0.archived })
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
        mutate(&state)
        store.scheduleSave(state)
        didChange?()
    }

    // MARK: Queries

    var selectedTask: HangarTask? {
        state.selectedTaskId.flatMap { id in state.tasks.first { $0.id == id && !$0.archived } }
    }

    func project(_ id: UUID) -> Project? { state.projects.first { $0.id == id } }

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
        let mode = launchMode(for: leaf, context)
        uiLog.info("launch leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public) restoring=\(mode.restoring) prompt=\(mode.initialPrompt != nil)")
        let spec = try launchSpec(for: leaf, tabId: tabId, config: config, socketPath: socketPath,
                                  userShell: userShell, restoring: mode.restoring, initialPrompt: mode.initialPrompt)
        return (spec, mode)
    }

    private func leaf(id: UUID) -> Leaf? {
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

    func createTask(projectId: UUID, name: String, firstMessage: String) {
        perform { s in
            let task = s.addTask(projectId: projectId, name: name)
            s.select(taskId: task)
            let tab = s.addTab(taskId: task, kind: config.defaultAgent)
            let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty, let leaf = s.tasks.last?.tabs.first(where: { $0.id == tab })?.root.leaves.first {
                pendingPrompts[leaf.id] = message
            }
        }
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
    func restore(taskId: UUID) {
        perform { $0.restoreTask(id: taskId) }
        markRestored(state.tasks.filter { $0.id == taskId })
    }
    func setPinned(_ taskId: UUID, _ pinned: Bool) { perform { $0.setPinned(taskId: taskId, pinned) } }
    func setCollapsed(projectId: UUID, _ collapsed: Bool) { perform { $0.setProjectCollapsed(id: projectId, collapsed) } }

    func addTab(_ kind: LeafKind) {
        guard let task = selectedTask else { return }
        perform { $0.addTab(taskId: task.id, kind: kind) }
    }

    func activate(tabId: UUID) {
        guard let task = selectedTask else { return }
        perform { s in
            if let i = s.tasks.firstIndex(where: { $0.id == task.id }) { s.tasks[i].activeTabId = tabId }
        }
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

    func setLanguage(_ language: Language) throws {
        try setConfig("language", language.rawValue) { $0.language = language }
        L10n.language = language
        languageDidChange?()
        didChange?()
    }
}

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
            if leaf.agentSessionId != nil { result.insert(leaf.id); return }
            if claimed.insert(Key(kind: leaf.kind, cwd: leaf.cwd)).inserted { result.insert(leaf.id) }
        }
    }
    for task in tasks {
        for tab in task.tabs { tab.root.leaves.forEach(visit) }
        if let leaf = task.drawer.leaf { visit(leaf) }
    }
    return result
}
