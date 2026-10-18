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

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored let socketPath: String
    @ObservationIgnored let userShell: String
    /// First message from the new-task sheet, consumed when the leaf's surface starts (decision #29).
    @ObservationIgnored private var pendingPrompts: [UUID: String] = [:]
    /// Leaves that came from state.json: agents resume instead of starting fresh.
    @ObservationIgnored private var restoredLeaves: Set<UUID> = []
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
        restoredLeaves = Set(state.tasks.flatMap { $0.tabs.flatMap { $0.root.leaves.map(\.id) } })
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

    /// Visible tasks in sidebar order: pinned, then each project's group.
    var orderedTasks: [HangarTask] { pinnedTasks + state.projects.flatMap { groupTasks($0.id) } }

    func defaultTitle(_ kind: LeafKind) -> String {
        switch kind {
        case .claude, .codex: kind.rawValue
        case .editor: (config.editor as NSString).lastPathComponent
        case .shell: (userShell as NSString).lastPathComponent
        }
    }

    func title(of leaf: Leaf) -> String { leafTitles[leaf.id] ?? defaultTitle(leaf.kind) }

    func tabLabel(_ tab: Tab) -> String { tab.root.leaves.map(title(of:)).joined(separator: " │ ") }

    func spec(for leaf: Leaf, tabId: UUID) throws -> LaunchSpec {
        let prompt = pendingPrompts.removeValue(forKey: leaf.id)
        return try launchSpec(for: leaf, tabId: tabId, config: config, socketPath: socketPath,
                              userShell: userShell, restoring: restoredLeaves.contains(leaf.id), initialPrompt: prompt)
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

    func addProject(path: String) {
        perform { $0.addProject(name: (path as NSString).lastPathComponent, path: path) }
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

    func rename(taskId: UUID, to name: String) { perform { $0.renameTask(id: taskId, name: name) } }
    func rename(projectId: UUID, to name: String) { perform { $0.renameProject(id: projectId, name: name) } }
    func archive(taskId: UUID) { perform { $0.archiveTask(id: taskId) } }
    func restore(taskId: UUID) { perform { $0.restoreTask(id: taskId) } }
    func setPinned(_ taskId: UUID, _ pinned: Bool) { perform { $0.setPinned(taskId: taskId, pinned) } }
    func setCollapsed(projectId: UUID, _ collapsed: Bool) { perform { $0.setProjectCollapsed(id: projectId, collapsed) } }

    func addTab(_ kind: LeafKind) {
        guard let task = selectedTask else { return }
        perform { $0.addTab(taskId: task.id, kind: kind) }
    }

    func closeTab(_ tabId: UUID) {
        guard let task = selectedTask else { return }
        perform { $0.closeTab(taskId: task.id, tabId: tabId) }
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
