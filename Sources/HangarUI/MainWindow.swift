import AppKit
import Git
import GhosttyBridge
import SwiftUI
import Workspace

/// Empty background that drags the window (titlebar zone is covered by our content).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { window.performDrag(with: event); return }
            // fullSizeContentView hides the real titlebar, so honour the system double-click setting here.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Titlebar row, tab bar row, terminal area, task status line.
final class TaskColumnController: NSViewController {
    let terminalArea: TerminalArea
    private let titleBar: NSHostingView<TitleBarView>
    let tabBar: NSHostingView<TabBarView>
    private let statusBar: NSHostingView<TaskStatusBar>
    /// «Задача в архиве · Отменить» over the bottom of the terminals.
    let archiveUndo: ArchiveUndo
    private let toast: NSHostingView<UndoToastView>

    init(app: AppState) {
        terminalArea = TerminalArea(app: app)
        let undo = ArchiveUndo()
        archiveUndo = undo
        toast = NSHostingView(rootView: UndoToastView(undo: undo) { [weak undo] id in undo?.onUndo(id) })
        titleBar = NSHostingView(rootView: TitleBarView(app: app))
        tabBar = NSHostingView(rootView: TabBarView(app: app, ctx: ActionContext(app: app)))
        statusBar = NSHostingView(rootView: TaskStatusBar(app: app))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        titleBar.sizingOptions = []
        tabBar.sizingOptions = []
        statusBar.sizingOptions = []
        toast.sizingOptions = [.intrinsicContentSize]
        for sub in [titleBar, tabBar, terminalArea, statusBar, toast] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: v.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Theme.titleBarHeight),
            tabBar.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Theme.tabBarHeight),
            terminalArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalArea.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),
            toast.centerXAnchor.constraint(equalTo: terminalArea.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor, constant: -(Theme.drawerBarHeight + Theme.toastBottom)),  // above the TERMINAL bar
        ])
        view = v
    }
}

/// The persisted inspector width within the drag limits (state.json may hold anything).
func clampInspectorWidth(_ w: CGFloat) -> CGFloat {
    min(max(w, Theme.inspectorMin), Theme.inspectorMax)
}

public final class MainWindowController: NSWindowController, NSWindowDelegate {
    let app: AppState
    let split = NSSplitViewController()
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem
    let column: TaskColumnController
    nonisolated(unsafe) private var keyMonitor: Any?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?
    private var sheetWindow: NSWindow?
    private var inspectorWatch: InspectorWatch?
    private var newTaskModel: NewTaskModel?
    /// The open «Удалённый проект» / «Сервер» sheet's models (debug hooks drive them).
    private(set) var remoteProjectModel: RemoteProjectModel?
    private(set) var serverModel: ServerCheckModel?
    private(set) var remoteProjectAdd: ((String, String) -> Void)?
    #if DEBUG
    var newTaskModelForDebug: NewTaskModel? { newTaskModel }
    #endif
    private var sidebarAnimation: Timer?
    private var didApplyInitialLayout = false
    private let configWarning: String?
    lazy var settings = SettingsWindowController(app: app)

    public init(app: AppState, configWarning: String?) {
        self.app = app
        self.configWarning = configWarning
        column = TaskColumnController(app: app)
        TerminalSurfaceView.clipboardPromptText = L10n.clipboardPromptText

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.backgroundColor = Theme.bg
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = Theme.windowMinSize

        let splitView = HangarSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        split.splitView = splitView

        let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
        sidebarHost.sizingOptions = []
        // Plain item: a `sidebar` item on macOS 26 floats over the content (Liquid Glass), not a full-height column.
        sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .init(260)
        split.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: column)
        split.addSplitViewItem(content)
        let inspectorHost = NSHostingController(rootView: InspectorView(app: app))
        inspectorHost.sizingOptions = []
        inspectorItem = NSSplitViewItem(viewController: inspectorHost)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = Theme.inspectorMin
        inspectorItem.maximumThickness = Theme.inspectorMax
        inspectorItem.holdingPriority = .init(260)  // window resizes go to the terminal area
        inspectorItem.isCollapsed = !app.state.inspectorVisible
        split.addSplitViewItem(inspectorItem)

        window.contentViewController = split
        window.setContentSize(Theme.windowSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HangarMainWindow")
        inspectorWatch = InspectorWatch(app: app, window: window)

        sidebarHost.rootView = AnyView(SidebarView(app: app, ctx: ctx))
        column.tabBar.rootView = TabBarView(app: app, ctx: ctx)
        // Undo selects the task again only if the archive left nothing selected (it was the selected one).
        column.archiveUndo.onUndo = { [weak self] id in
            guard let self else { return }
            let reselect = self.app.selectedTask == nil
            Task { await restoreArchivedTask(id, ctx: self.ctx, reselect: reselect) }
        }
        splitView.onDragEnd = { [weak self, weak splitView] in
            switch splitView?.draggedDivider {
            case 0: self?.sidebarDragEnded()
            case 1: self?.inspectorDragEnded()
            default: break
            }
        }

        app.didChange = { [weak self] in
            guard let self else { return }
            self.syncInspector()
            self.column.terminalArea.sync()
            self.inspectorWatch?.update()
            // Inline rename ended and the field editor left the window without a responder.
            // Checked on the next turn: the field editor resigns after the commit/cancel that triggered this.
            DispatchQueue.main.async {
                if self.app.renaming == nil, let window = self.window, window.firstResponder === window { self.column.terminalArea.focusActiveLeaf() }
            }
        }
        column.terminalArea.onAddProject = { [weak self] in self?.chooseProjectKind() }
        app.languageDidChange = { [weak self] in
            self?.installMainMenu()
            self?.settings.updateTitle()
        }
        installMainMenu()
        installKeyMonitor()
        // Passed reset times and «обновлено …» are recomputed when the user comes back, not by a timer.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.app.refreshUsageClock()
                // The SSH HOSTS list follows ~/.ssh/config edits made while Hangar was in the background (no watcher).
                self?.app.reloadConfigHosts()
            }
        }
        app.reloadConfigHosts()
        #if DEBUG
        installDebugHooks()
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didApplyInitialLayout, let window else { return }
        didApplyInitialLayout = true
        // Position the divider only after the split view has its real size, else setPosition is ignored.
        window.contentView?.layoutSubtreeIfNeeded()
        applySidebarWidth()
        if app.state.inspectorVisible { applyInspectorWidth() }
        column.terminalArea.sync()
        inspectorWatch?.update()
        if let configWarning { showConfigWarning(configWarning) }
    }

    // MARK: Sidebar width

    private var targetSidebarWidth: CGFloat {
        app.state.sidebarCollapsed ? Theme.sidebarRailWidth
            : min(max(CGFloat(app.state.sidebarWidth), Theme.sidebarMin), Theme.sidebarMax)
    }

    private func setSidebarBounds(collapsed: Bool) {
        sidebarItem.minimumThickness = collapsed ? Theme.sidebarRailWidth : Theme.sidebarMin
        sidebarItem.maximumThickness = collapsed ? Theme.sidebarRailWidth : Theme.sidebarMax
    }

    private func applySidebarWidth() {
        setSidebarBounds(collapsed: app.state.sidebarCollapsed)
        split.splitView.setPosition(targetSidebarWidth, ofDividerAt: 0)
    }

    private func sidebarDragEnded() {
        guard !app.state.sidebarCollapsed else { return }
        let width = Double(sidebarItem.viewController.view.frame.width)
        guard abs(width - app.state.sidebarWidth) >= 1 else { return }
        uiLog.info("sidebar width \(width)")
        app.perform { $0.sidebarWidth = width }
    }

    // MARK: Inspector width

    private func applyInspectorWidth() {
        let view = split.splitView
        view.layoutSubtreeIfNeeded()
        let width = clampInspectorWidth(CGFloat(app.state.inspectorWidth))
        view.setPosition(view.bounds.width - width - view.dividerThickness, ofDividerAt: 1)
    }

    /// Follows `inspectorVisible` (⌘⌥I, titlebar button); expanding restores the saved width.
    private func syncInspector() {
        let collapsed = !app.state.inspectorVisible
        guard inspectorItem.isCollapsed != collapsed else { return }
        inspectorItem.isCollapsed = collapsed
        if !collapsed, didApplyInitialLayout { applyInspectorWidth() }
    }

    private func inspectorDragEnded() {
        guard app.state.inspectorVisible, !inspectorItem.isCollapsed else { return }
        let width = Double(inspectorItem.viewController.view.frame.width)
        guard abs(width - app.state.inspectorWidth) >= 1 else { return }
        uiLog.info("inspector width \(width)")
        app.perform { $0.inspectorWidth = width }
    }

    /// Animates only the width (ease-in-out); the rows keep their markers in place.
    private func toggleSidebar() {
        sidebarAnimation?.invalidate()
        let from = sidebarItem.viewController.view.frame.width
        app.perform { $0.sidebarCollapsed.toggle() }
        if Motion.reduced { applySidebarWidth(); return }
        let to = targetSidebarWidth
        sidebarItem.minimumThickness = min(from, to, Theme.sidebarRailWidth)
        sidebarItem.maximumThickness = Theme.sidebarMax
        app.sidebarAnimating = true
        animation = (from, to, CACurrentMediaTime())
        // A timer only while animating (≈0.18 s), never when idle.
        sidebarAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepSidebarAnimation() }
        }
    }

    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?

    private func stepSidebarAnimation() {
        guard let (from, to, start) = animation else { return }
        let t = min(1, (CACurrentMediaTime() - start) / Theme.sidebarAnimation)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        split.splitView.setPosition(from + (to - from) * eased, ofDividerAt: 0)
        guard t >= 1 else { return }
        sidebarAnimation?.invalidate()
        sidebarAnimation = nil
        animation = nil
        app.sidebarAnimating = false
        applySidebarWidth()
    }

    // MARK: Keys

    /// Before the terminal surface: Ghostty would otherwise consume ⌘T/⌘W/⌘D/⌘N/⌘1…9 as its own bindings.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // ⌘⇧L also closes the limits popover while it has the keyboard.
        if app.limitsPopoverShown, !event.isARepeat, shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) == .limits {
            app.toggleLimitsPopover()
            return true
        }
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        let consumed = route(event, in: window)
        // A key that goes on to a terminal or field ends the "just clicked a row/tab" state (F2 then passes through).
        if !consumed, firstResponderKind != .other { app.keyReachedTerminal() }
        return consumed
    }

    private func route(_ event: NSEvent, in window: NSWindow) -> Bool {
        // The inline rename field: ↩ must reach it, not relaunch the terminal.
        let editingText = window.firstResponder is NSText
        // Before the shortcuts: ⌘W closes the diff tab, not the hidden tab; with focus in the TERMINAL panel keys go there.
        let diffActive = app.activeDiff != nil && column.terminalArea.drawer.focusedLeaf == nil
        if let key = diffKeyRoute(keyCode: event.keyCode, modifiers: event.modifierFlags, diffActive: diffActive, editingText: editingText) {
            app.hangarShortcutConsumed()
            switch key {
            case .up: app.diffNeighbour(-1)
            case .down: app.diffNeighbour(1)
            case .enter: if !event.isARepeat { app.openActiveDiffInEditor() }
            case .toggleMode: if !event.isARepeat { app.inspector.toggleMode() }
            case .close: if !event.isARepeat { app.closeDiff() }
            }
            return true
        }
        if let sc = shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            if sc == .rename {
                switch f2Route(firstResponderKind, lastInteraction: app.lastInteraction, selectedTask: app.selectedTask?.id) {
                case .passthrough: return false
                case .rename(let target): Action.rename.perform(target, ctx)
                case .ignore: break
                }
                return true
            }
            // Held keys must not open/close/split dozens of tabs; the repeat is swallowed, not sent to the terminal.
            let once: [Shortcut] = [.closeTab, .newTab, .splitRight, .splitDown, .toggleDrawer, .limits, .revealInFinder, .copyPath]
            app.hangarShortcutConsumed()
            if event.isARepeat && once.contains(sc) { return true }
            switch drawerRoute(sc, drawerFocused: column.terminalArea.drawer.focusedLeaf != nil, diffActive: app.activeDiff != nil) {
            case .ignore: break
            case .collapseDrawer: if let id = app.selectedTask?.id { column.terminalArea.toggleDrawer(taskId: id) }
            case .perform: perform(sc)
            }
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 36, mods.isEmpty, !editingText { return column.terminalArea.relaunchFocusedIfExited() }  // ↩
        return false
    }

    /// Services for `Action.perform`; built on demand (closures hold the controller weakly).
    var ctx: ActionContext {
        ActionContext(
            app: app,
            addProject: { [weak self] in self?.chooseProjectKind() },
            addLocalProject: { [weak self] in self?.chooseProject() },
            addRemoteProject: { [weak self] in self?.presentRemoteProject() },
            connectHost: { [weak self] in self?.presentConnectHost() },
            checkServer: { [weak self] host in self?.presentServer(host) },
            newTask: { [weak self] id in self?.presentNewTask(projectId: id) },
            projectSettings: { [weak self] id in self?.presentProjectSettings(id) },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            openSettings: { [weak self] in self?.showSettings(nil) },
            toggleDrawer: { [weak self] id in self?.column.terminalArea.toggleDrawer(taskId: id) },
            confirm: { [weak self] message, info, button, then in self?.confirm(message, info, button, then) },
            confirmWithCheckbox: { [weak self] message, info, button, checkbox, then in
                self?.confirm(message, info, button, checkbox: checkbox, then)
            },
            showError: { [weak self] message, info in self?.showError(message, info) },
            didArchive: { [weak self] id in self?.column.archiveUndo.show(id) })
    }

    private var firstResponderKind: FirstResponderKind {
        guard let responder = window?.firstResponder else { return .other }
        let view = responder as? NSView
        return responderKind(isText: responder is NSText, inTerminalArea: view?.isDescendant(of: column.terminalArea) == true,
                             isDiff: sequence(first: view, next: { $0?.superview }).contains { $0 is DiffHostView })
    }

    /// Keyboard target of a registry action (F2 is routed in `handleKeyDown`): the selected task, or its active tab.
    private func keyTarget(for action: Action) -> ActionTarget? {
        guard let task = app.selectedTask else { return nil }
        switch action {
        case .splitRight, .splitDown, .closeTab:
            return column.terminalArea.activeTab.map { .tab(task: task.id, tab: $0.id) }
        default: return .task(task.id)
        }
    }

    func perform(_ sc: Shortcut) {
        if let action = Action.allCases.first(where: { $0.shortcut == sc }) {
            if let target = keyTarget(for: action) { action.perform(target, ctx) }
            return
        }
        switch sc {
        case .newTask: presentNewTask(projectId: nil)
        case .newTab: app.addTab(.shell)
        case .closeTab, .splitRight, .splitDown, .rename, .archiveTask, .toggleDrawer, .revealInFinder, .copyPath:
            break  // Action registry above (F2: handleKeyDown)
        case .tab(let n): app.activate(tabNumber: n)
        case .prevTask: app.selectTask(offset: -1)
        case .nextTask: app.selectTask(offset: 1)
        case .toggleInspector: app.perform { $0.inspectorVisible.toggle() }
        case .toggleSidebar: toggleSidebar()
        case .addProject: chooseProjectKind()
        // shortcut: ⌘, is also the app menu's key (discoverable there, and it serves other windows); the menu alone misses it
        // while a terminal has focus (Ghostty's default super+comma binding takes the key first). Drop this if that binding goes.
        case .settings: showSettings(nil)
        case .inspectorFiles: app.showInspector(.files)
        case .inspectorChanges: app.showInspector(.changes)
        case .limits: app.toggleLimitsPopover()
        case .prevTab: cycleTab(-1)
        case .nextTab: cycleTab(1)
        case .focusSplit(let direction):
            if !column.terminalArea.focusSplit(direction), let step = direction.taskFallback { app.selectTask(offset: step) }
        }
    }

    /// ⌃Tab / ⌃⇧Tab: the task's tabs, then its diff tab, wrapping.
    private func cycleTab(_ offset: Int) {
        guard let task = app.selectedTask else { return }
        let diff = app.diffTabs[task.id]
        let slots = task.tabs.map { TabSlot.tab($0.id) } + (diff == nil ? [] : [.diff])
        let current: TabSlot? = diff?.active == true ? .diff : task.activeTabId.map { .tab($0) }
        switch cycled(slots, from: current, by: offset) {
        case .tab(let id): app.activate(tabId: id)
        case .diff: app.activateDiff()
        case nil: break
        }
    }

    // MARK: Notifications

    private var notifier: Notifier?

    /// The app is active and the main window is on screen (a key Settings window or sheet doesn't hide it) (a notification for a hidden leaf is due otherwise).
    private var windowVisible: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Posts macOS notifications for agents that wait or finish out of sight; a click reveals the leaf.
    /// No-op outside an .app bundle.
    public func enableNotifications() {
        guard let notifier = Notifier.makeIfAvailable() else { return }
        self.notifier = notifier
        notifier.onOpen = { [weak self] in self?.reveal(leafId: $0) }
        app.onTransition = { [weak self] t in
            guard let self, let n = notice(for: t, app: self.app, leafVisible: leafVisible(t.leaf, app: self.app, windowVisible: self.windowVisible)) else { return }
            self.notifier?.post(n)
        }
        app.onUsageAlerts = { [weak self] alerts in
            guard let self else { return }
            for n in limitNotices(alerts, app: self.app) { self.notifier?.post(n) }
        }
    }

    public func reveal(leafId: UUID) {
        app.reveal(leafId: leafId)
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        column.terminalArea.focus(leafId: leafId)
    }

    @objc func showSettings(_ sender: Any?) { settings.present(over: window) }

    /// Rebuilt on every language switch (menus keep the titles they were built with).
    /// Quit plus a standard Edit menu, so text fields (new-task sheet, rename) get copy/paste/undo.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: L10n.settingsEllipsis, action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.menuHide, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L10n.menuEdit)
        edit.addItem(withTitle: L10n.undo, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Projects, tasks

    /// «+ проект», ⌘⇧N, the empty state: «Локальная папка…» / «Удалённый (SSH)…» at the pointer (keyboard: mid-window).
    private func chooseProjectKind(thenNewTask: Bool = false) {
        guard let window, window.attachedSheet == nil, let content = window.contentView else { return }
        let items = [
            MenuEntry(title: L10n.addLocalProject, icon: .project) { [weak self] in self?.chooseProject(thenNewTask: thenNewTask) },
            MenuEntry(title: L10n.addRemoteProject, icon: .sshHost) { [weak self] in self?.presentRemoteProject(thenNewTask: thenNewTask) },
            MenuEntry(title: L10n.connectToHost, icon: .shell) { [weak self] in self?.presentConnectHost() },
        ]
        let mouse = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(NSApp.currentEvent?.type)
        if mouse {
            popUpMenu(items)
        } else {
            popUpMenu(items, at: NSPoint(x: content.bounds.midX, y: content.bounds.midY), in: content)
        }
    }

    /// `thenNewTask`: "+ Новая задача" with no projects — the new-task sheet follows the added project.
    private func chooseProject(thenNewTask: Bool = false) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.addProject
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let id = self.app.addProject(path: url.path)
                // The open panel is still attached until this handler returns.
                if thenNewTask { DispatchQueue.main.async { self.presentNewTask(projectId: id) } }
            }
        }
    }

    func presentNewTask(projectId: UUID?) {
        guard let window, window.attachedSheet == nil else { return }
        let id = projectId ?? app.selectedTask.flatMap { app.project($0.projectId)?.id } ?? app.state.projects.last?.id
        guard let id, let project = app.project(id) else { chooseProjectKind(thenNewTask: true); return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: Theme.sheetPlaceholderHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.sheet
        sheet.appearance = window.appearance
        let model = NewTaskModel(project: project, git: app.git(for: project), taskBranches: app.taskBranches(id))
        let load = Task { await model.load() }
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            load.cancel()
            model.cancelFetch()
            if let wait = sheet.attachedSheet { sheet.endSheet(wait) } // the «Создаётся worktree…» alert
            window.endSheet(sheet)
            self.sheetWindow = nil
            self.newTaskModel = nil
        }
        let view = NewTaskSheet(model: model, projectName: project.name, agentName: app.config.defaultAgent.rawValue,
                                onCreate: { [weak self] name, message, mode in
                                    close()
                                    self?.app.createTask(projectId: id, name: name, firstMessage: message, mode: mode,
                                                         setup: model.setupScript)
                                },
                                onCancel: close)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        sheetWindow = sheet
        newTaskModel = model
        window.beginSheet(sheet)
    }

    /// No closing (→ quitting) while the new-task sheet runs `git worktree add`.
    /// A new-task create is in progress: closing the window or quitting would abandon a half-made worktree.
    public var isCreatingTask: Bool { newTaskModel?.creating == true }
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch currentQuitDecision() {
        case .terminateNow: return true
        case .cancelCreating: notifyCreatingTask(); return false
        case .alreadyAsking: return false
        case .ask:
            // Closing the last window quits: ask once (confirmQuit sets quitConfirmed), then close without a second question.
            confirmQuit { [weak self] ok in
                if ok { self?.window?.close() }
            }
            return false
        }
    }

    /// Set after the user confirmed quitting with working agents, so close -> terminate doesn't ask again.
    private var quitConfirmed = false
    private var quitAlertShown = false

    /// Sheet (not modal) on the main window; `then(true)` = quit confirmed. Never stacks a second alert:
    /// with one already up, `then(false)` right away. `then` is always called exactly once.
    public func confirmQuit(then: @escaping @MainActor (Bool) -> Void) {
        guard let window, let text = quitConfirmation(working: app.quitWorkingCount) else { then(true); return }
        guard !quitAlertShown else { then(false); return }
        quitAlertShown = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: L10n.quit).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.quitAlertShown = false
                let ok = response == .alertFirstButtonReturn
                if ok { self?.quitConfirmed = true }
                then(ok)
            }
        }
    }

    /// For `applicationShouldTerminate`.
    public func currentQuitDecision(forced: Bool = false) -> QuitDecision {
        quitDecision(creating: isCreatingTask || app.controlCreating > 0, working: app.quitWorkingCount, confirmed: quitConfirmed,
                     asking: quitAlertShown, forced: forced)
    }

    /// Non-modal feedback for a refused close/quit: a sheet on the new-task sheet (or on the window).
    public func notifyCreatingTask() {
        guard let host = sheetWindow ?? window, host.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.creatingWorktreeWait
        alert.addButton(withTitle: L10n.ok)
        alert.beginSheetModal(for: host)
    }

    private func makeSheet(over window: NSWindow) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: Theme.sheetPlaceholderHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.sheet
        sheet.appearance = window.appearance
        return sheet
    }

    private func begin<V: View>(_ sheet: NSWindow, _ view: V, on window: NSWindow) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    /// «Удалённый проект»: connect, find the folder, show the server; «Добавить» adds the project.
    func presentRemoteProject(thenNewTask: Bool = false) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = makeSheet(over: window)
        let model = RemoteProjectModel(remote: app.remote, configHosts: app.configHosts(),
                                       release: { [weak self] in self?.app.releaseUnusedHost($0) })
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
            self.remoteProjectModel = nil
            self.remoteProjectAdd = nil
        }
        let add: (String, String) -> Void = { [weak self] host, path in
            close()
            guard let self else { return }
            let id = self.app.addRemoteProject(host: host, path: path)
            if thenNewTask { DispatchQueue.main.async { self.presentNewTask(projectId: id) } }
        }
        remoteProjectModel = model
        remoteProjectAdd = add
        let height = window.contentLayoutRect.height
        begin(sheet, RemoteProjectSheet(model: model, windowHeight: height, onAdd: add, onCancel: { model.cancel(); close() }), on: window)
    }

    /// «Подключиться к хосту…»: a plain ssh shell tab on the host (#NN-ssh-shell).
    func presentConnectHost() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = makeSheet(over: window)
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
        }
        let view = ConnectHostSheet(configHosts: app.configHosts(), onConnect: { [weak self] host in
            close()
            self?.app.openHostShell(host)
        }, onCancel: close)
        begin(sheet, view, on: window)
    }

    /// «Сервер <host>»: the check again, the plan, installs and the server's integrations.
    func presentServer(_ host: String) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = makeSheet(over: window)
        let model = ServerCheckModel(host: host, remote: app.remote, run: ServerCheckModel.sshRun(remote: app.remote, host: host))
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
            self.serverModel = nil
        }
        serverModel = model
        Task { await model.refresh() }
        begin(sheet, ServerCheckSheet(model: model, windowHeight: window.contentLayoutRect.height, onClose: close), on: window)
    }

    private func presentProjectSettings(_ id: UUID) {
        guard let window, window.attachedSheet == nil, let project = app.project(id) else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: Theme.sheetPlaceholderHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.sheet
        sheet.appearance = window.appearance
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
        }
        let view = ProjectSettingsSheet(project: project, git: app.git(for: project), runner: app.runner(for: project), onSave: { [weak self] name, path, baseBranch, worktreeRoot, setup in
            close()
            self?.app.perform {
                $0.updateProject(id: id, name: name, path: path, baseBranch: baseBranch, worktreeRoot: worktreeRoot)
                $0.setWorktreeSetup(id: id, copy: setup.copy, command: setup.command)
            }
            // The visible task's diff base may be this project's default.
            if self?.app.selectedTask?.projectId == id { self?.app.inspector.baseChanged() }
        }, onCancel: close)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    private func confirm(_ message: String, _ info: String, _ button: String, _ then: @escaping () -> Void) {
        confirm(message, info, button, checkbox: nil) { _ in then() }
    }

    /// `checkbox` (unchecked by default) is shown as the alert's suppression button; `then` gets its state.
    private func confirm(_ message: String, _ info: String, _ button: String, checkbox: String?, _ then: @escaping (Bool) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.cancel)
        if let checkbox {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = checkbox
            alert.suppressionButton?.state = .off
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let checked = alert.suppressionButton?.state == .on
            MainActor.assumeIsolated { then(checked) }
        }
    }

    private func showError(_ message: String, _ info: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: L10n.ok)
        alert.beginSheetModal(for: window)
    }

    private func showConfigWarning(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.configNotApplied
        alert.informativeText = "\(text)\n\(L10n.usingDefaults)"
        alert.addButton(withTitle: L10n.ok)
        alert.beginSheetModal(for: window)
    }
}
