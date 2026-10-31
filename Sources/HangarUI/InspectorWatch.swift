import AppKit
import Git
import Workspace

/// Keeps the inspector fed with the visible task only: while the inspector is shown, the window is on screen
/// (not occluded, not minimized) and a task is selected, it shows that task and watches its root (only the subfolder
/// for a subfolder project, #44) and git-dir. A remote task has no FSEvents (#47): it reloads on show, when the
/// window becomes key and when an agent is done.
/// Otherwise the stream is stopped — no callbacks, no loads. No timers.
@MainActor final class InspectorWatch {
    private let app: AppState
    private weak var window: NSWindow?
    private(set) var watcher: FileWatcher?
    private var current: (task: UUID, root: String, remote: Bool)?
    /// Test seam: on screen, not occluded, not minimized.
    var windowVisible: () -> Bool = { false }
    /// Bumped on every change of what is watched: a git-dir lookup that finishes late is dropped.
    private var generation = 0
    /// The selected local chat's `HEAD` file alone (the branch button, #114) while the inspector's stream doesn't run
    /// for it; with that stream on, its status loads reload the HEAD (`onStatusLoad`).
    private(set) var headWatcher: FileWatcher?
    private var headTask: UUID?
    /// The git-dir lookup for `headTask` ran or runs.
    private var headPending = false
    private var headGeneration = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(app: AppState, window: NSWindow) {
        self.app = app
        self.window = window
        windowVisible = { [weak window] in
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameKey() }
        })
        app.onLeafDone = { [weak self] leaf in self?.leafDone(leaf) }
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    func root(of task: HangarTask) -> String? {
        let project = app.project(task.projectId)
        switch task.mode {
        case .worktree:
            // Only a checked copy: a moved one's old folder would show the main checkout (#122).
            guard let path = app.gitFolder(of: task.id) else { return nil }
            // A subfolder project: the same subfolder inside the worktree (local only; a remote one shows the whole worktree).
            guard let project, project.host == nil, let sub = subfolderInRepository(project.path),
                  FileManager.default.fileExists(atPath: path + "/" + sub) else { return path }
            return path + "/" + sub
        case .mainFolder: return project?.path ?? (app.state.isFreeChatTask(task) ? app.state.chatsFolder : nil)
        }
    }

    /// Call after any change of the inspector flag, the selection or the window state; cheap when nothing changed.
    func update() {
        // The Git tab loads only while the inspector itself is on screen (a shown diff tab alone keeps the watch, not it).
        defer {
            app.gitPanel.setOnScreen(current != nil && app.state.inspectorVisible)
            updateHeadWatch()
        }
        let task = app.selectedTask
        let want = task.flatMap { t in root(of: t).map { (t.id, $0) } }
        // The shown diff tab is the inspector's data too: it keeps loading (and refreshing) with the inspector hidden.
        guard shouldWatch(inspectorVisible: app.state.inspectorVisible || app.activeDiff != nil, windowVisible: windowVisible(), hasTask: want != nil),
              let task, let (id, root) = want else {
            stop()
            return
        }
        if let current, current.task == id, current.root == root { return }
        stop()
        let app = self.app
        guard let project = app.project(task.projectId) else { return }
        let remote = project.host != nil
        current = (id, root, remote)
        generation += 1
        let gen = generation
        let runner = app.runner(for: project)
        app.inspector.show(taskId: id, root: root, git: { Git(repo: $0, runner: runner) }, remote: remote,
                           baseBranch: { await app.baseBranch(of: task) })
        app.gitPanel.show(taskId: id, root: root, git: { Git(repo: $0, runner: runner) }, remote: remote)
        // `show` of another task drops the open diff: this task's diff tab asks for its file again.
        if let tab = app.diffTabs[id] {
            if let hash = tab.commit {
                if app.gitPanel.diffState(hash: hash, path: tab.path) == nil { app.gitPanel.loadDiff(hash: hash, path: tab.path, origPath: tab.origPath) }
            } else if app.inspector.diffPath != tab.path {
                app.inspector.loadDiff(path: tab.path)
            }
        }
        guard !remote else { uiLog.info("watch remote root=\(root, privacy: .public)"); return }
        Task { [weak self] in
            let git = Git(repo: root)
            let gitDir = try? await git.gitDir()
            let commonDir = gitDir == nil ? nil : try? await git.commonDir()
            // A project in a subfolder of a repository: the ancestors' `.gitignore` files, up to the top level.
            let top = gitDir == nil ? nil : try? await git.toplevel()
            guard let self, gen == self.generation else { return }
            self.start(root: root, top: top, gitDir: gitDir, commonDir: commonDir)
        }
    }

    private func start(root: String, top: String?, gitDir: String?, commonDir: String?) {
        // FSEvents reports real paths (/var → /private/var, symlinked project folders).
        let realRoot = realPath(root)
        let realGit = gitDir.map(realPath), realCommon = commonDir.map(realPath)
        let ignored = app.inspector.ignored
        watcher = FileWatcher(paths: watchPaths(root: realRoot, gitDir: realGit, commonDir: realCommon, top: top.map(realPath)),
                              onChange: { [weak self] parts in
                                  self?.app.inspector.refresh(parts.subtracting(.refs))
                                  if parts.contains(.refs) { self?.app.gitPanel.refresh() }
                              },
                              classify: { events in
                                  let parts = classify(events, root: realRoot, gitDir: realGit, commonDir: realCommon, ignored: ignored.paths)
                                  return refsMoved(events, gitDir: realGit, commonDir: realCommon) ? parts.union(.refs) : parts
                              })
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

    /// While the window is visible: the selected local chat's `HEAD` file (a file path: FSEvents watches just it,
    /// a rename over it included). A remote chat has no FSEvents: its HEAD reloads on focus, `done` and the host connecting.
    private func updateHeadWatch() {
        let task = app.selectedTask
        guard windowVisible(), let task else { stopHeadWatch(); return }
        if headTask != task.id { app.selectedHead(task) }
        guard app.project(task.projectId)?.host == nil, current?.task != task.id, let root = app.gitFolder(of: task.id) else {
            stopHeadWatch()
            headTask = task.id
            return
        }
        if headTask == task.id, headPending { return }
        stopHeadWatch()
        headTask = task.id
        headPending = true
        let id = task.id, gen = headGeneration
        Task { [weak self] in
            let gitDir = try? await Git(repo: root).gitDir()
            // Not a repository: `headPending` stays set, no lookup again until the selection changes.
            guard let self, gen == self.headGeneration, let gitDir else { return }
            let head = realPath(gitDir) + "/HEAD"
            self.headWatcher = FileWatcher(paths: [head], onChange: { [weak self] _ in self?.app.refreshHead(taskId: id) },
                                           classify: { events in events.contains { $0.path == head } ? .status : [] })
        }
    }

    private func stopHeadWatch() {
        headGeneration += 1
        headPending = false
        headWatcher?.stop()
        headWatcher = nil
        headTask = nil
    }

    /// Back from another app or window: a remote task's files may have changed meanwhile.
    private func becameKey() {
        app.refreshHeadsOnFocus()
        if current?.remote == true {
            app.inspector.refresh(.all)
            app.gitPanel.refresh()
        }
    }

    /// An agent of the visible task finished: its changes are likely new.
    private func leafDone(_ leaf: UUID) {
        guard watcher != nil || current != nil, let task = app.selectedTask, current?.task == task.id else { return }
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        guard leaves.contains(where: { $0.id == leaf }) else { return }
        app.inspector.refresh(.status)
        // A remote session has no FSEvents: the agent may have committed.
        if current?.remote == true { app.gitPanel.refresh() }
    }
}

/// `apps/web` for a folder below its repository's top level, nil at the top or outside a repository.
/// shortcut: the top is the nearest ancestor with `.git` on this Mac's disk (sync, unlike `rev-parse`); a `GIT_DIR`
/// setup counts as no subfolder — change when such projects appear.
func subfolderInRepository(_ path: String) -> String? {
    var dir = path
    while dir != "/", !dir.isEmpty {
        if FileManager.default.fileExists(atPath: dir + "/.git") { return dir == path ? nil : String(path.dropFirst(dir.count + 1)) }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
}
