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

    private func root(of task: HangarTask) -> String? {
        let project = app.project(task.projectId)
        switch task.mode {
        case .worktree(let path, _, _):
            // A subfolder project: the same subfolder inside the worktree (local only; a remote one shows the whole worktree).
            guard let project, project.host == nil, let sub = subfolderInRepository(project.path),
                  FileManager.default.fileExists(atPath: path + "/" + sub) else { return path }
            return path + "/" + sub
        case .mainFolder: return project?.path
        }
    }

    /// Call after any change of the inspector flag, the selection or the window state; cheap when nothing changed.
    func update() {
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
        // `show` of another task drops the open diff: this task's diff tab asks for its file again.
        if let path = app.diffTabs[id]?.path, app.inspector.diffPath != path { app.inspector.loadDiff(path: path) }
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

    /// Back from another app or window: a remote task's files may have changed meanwhile.
    private func becameKey() {
        if current?.remote == true { app.inspector.refresh(.all) }
    }

    /// An agent of the visible task finished: its changes are likely new.
    private func leafDone(_ leaf: UUID) {
        guard watcher != nil || current != nil, let task = app.selectedTask, current?.task == task.id else { return }
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        if leaves.contains(where: { $0.id == leaf }) { app.inspector.refresh(.status) }
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
