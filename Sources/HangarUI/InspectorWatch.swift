import AppKit
import Git
import Workspace

/// Keeps the inspector fed with the visible task only: while the inspector is shown, the window is on screen
/// (not occluded, not minimized) and a task is selected, it shows that task and watches its root and git-dir.
/// Otherwise the stream is stopped — no callbacks, no loads. No timers.
@MainActor final class InspectorWatch {
    private let app: AppState
    private weak var window: NSWindow?
    private var watcher: FileWatcher?
    private var current: (task: UUID, root: String)?
    /// Bumped on every change of what is watched: a git-dir lookup that finishes late is dropped.
    private var generation = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(app: AppState, window: NSWindow) {
        self.app = app
        self.window = window
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        app.onLeafDone = { [weak self] leaf in self?.leafDone(leaf) }
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    private var windowVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func root(of task: HangarTask) -> String? {
        switch task.mode {
        case .worktree(let path, _, _): path
        case .mainFolder: app.project(task.projectId)?.path
        }
    }

    /// Call after any change of the inspector flag, the selection or the window state; cheap when nothing changed.
    func update() {
        let task = app.selectedTask
        let want = task.flatMap { t in root(of: t).map { (t.id, $0) } }
        // The shown diff tab is the inspector's data too: it keeps loading (and refreshing) with the inspector hidden.
        guard shouldWatch(inspectorVisible: app.state.inspectorVisible || app.activeDiff != nil, windowVisible: windowVisible, hasTask: want != nil),
              let task, let (id, root) = want else {
            stop()
            return
        }
        if let current, current.task == id, current.root == root { return }
        stop()
        current = (id, root)
        generation += 1
        let gen = generation
        let app = self.app
        app.inspector.show(taskId: id, root: root, baseBranch: { await app.baseBranch(of: task) })
        // `show` of another task drops the open diff: this task's diff tab asks for its file again.
        if let path = app.diffTabs[id]?.path, app.inspector.diffPath != path { app.inspector.loadDiff(path: path) }
        Task { [weak self] in
            let git = Git(repo: root)
            let gitDir = try? await git.gitDir()
            let commonDir = gitDir == nil ? nil : try? await git.commonDir()
            guard let self, gen == self.generation else { return }
            self.start(root: root, gitDir: gitDir, commonDir: commonDir)
        }
    }

    private func start(root: String, gitDir: String?, commonDir: String?) {
        // FSEvents reports real paths (/var → /private/var, symlinked project folders).
        let realRoot = realPath(root)
        let realGit = gitDir.map(realPath), realCommon = commonDir.map(realPath)
        let ignored = app.inspector.ignored
        watcher = FileWatcher(paths: watchPaths(root: realRoot, gitDir: realGit, commonDir: realCommon),
                              onChange: { [weak self] parts in self?.app.inspector.refresh(parts) },
                              classify: { classify($0, root: realRoot, gitDir: realGit, commonDir: realCommon, ignored: ignored.paths) })
        uiLog.info("watch start root=\(root, privacy: .public)")
    }

    private func stop() {
        generation += 1
        guard current != nil || watcher != nil else { return }
        if let current { uiLog.info("watch stop root=\(current.root, privacy: .public)") }
        watcher?.stop()
        watcher = nil
        current = nil
    }

    /// An agent of the visible task finished: its changes are likely new.
    private func leafDone(_ leaf: UUID) {
        guard watcher != nil || current != nil, let task = app.selectedTask, current?.task == task.id else { return }
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        if leaves.contains(where: { $0.id == leaf }) { app.inspector.refresh(.status) }
    }
}
