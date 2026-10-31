import AppKit
import Git
import GhosttyBridge
import SwiftUI
import WebKit
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

/// Tab bar row and terminal area of the selected session.
final class TaskColumnController: NSViewController {
    let terminalArea: TerminalArea
    let tabBar: NSHostingView<TabBarView>
    /// «Сессия в архиве · Отменить» over the bottom of the terminals.
    let archiveUndo: ArchiveUndo
    private let toast: NSHostingView<UndoToastView>
    /// «Сессии» (⌘Y) over the tab bar and terminals.
    let sessionsModel: SessionsModel
    let sessions: NSHostingView<SessionsHost>

    init(app: AppState) {
        sessionsModel = SessionsModel(app: app)
        sessions = NSHostingView(rootView: SessionsHost(app: app, model: sessionsModel, ctx: ActionContext(app: app)))
        terminalArea = TerminalArea(app: app)
        let undo = ArchiveUndo()
        archiveUndo = undo
        toast = NSHostingView(rootView: UndoToastView(undo: undo) { [weak undo] id in undo?.onUndo(id) })
        tabBar = NSHostingView(rootView: TabBarView(app: app, ctx: ActionContext(app: app)))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        tabBar.sizingOptions = []
        tabBar.safeAreaRegions = []  // laid out by hand under the toolbar, like the toolbar itself
        toast.sizingOptions = [.intrinsicContentSize]
        sessions.sizingOptions = []
        sessions.safeAreaRegions = []  // starts right under the toolbar, inside the titlebar's safe area on macOS 26
        toast.safeAreaRegions = []
        sessions.isHidden = true
        for sub in [tabBar, terminalArea, sessions, toast] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: v.topAnchor, constant: Theme.Height.barToolbar),
            tabBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Theme.Height.barTabs),
            terminalArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalArea.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            sessions.topAnchor.constraint(equalTo: v.topAnchor, constant: Theme.Height.barToolbar),
            sessions.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            sessions.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            sessions.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: terminalArea.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor, constant: -(Theme.Height.barPane + Theme.toastBottom)),  // above the TERMINAL bar
        ])
        view = v
    }
}

/// Window content (design system §3.1): the three columns full height, the toolbar over their top 52 (the sidebar's
/// head with the traffic lights left of the chat column).
final class WindowRootController: NSViewController {
    private let split: NSSplitViewController
    let titleBar: NSHostingView<WindowTitleBar>
    let metrics: TitleBarMetrics
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var observesWindow = false

    init(app: AppState, split: NSSplitViewController) {
        self.split = split
        let metrics = TitleBarMetrics()
        self.metrics = metrics
        titleBar = NSHostingView(rootView: WindowTitleBar(app: app, metrics: metrics, inboxAction: { _, _, _ in }, toggleSidebar: {}))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func loadView() {
        let v = NSView()
        addChild(split)
        titleBar.sizingOptions = []
        // The bar is placed by hand (52 from the top, centred on the lights): a titlebar safe area the window reports
        // differently on another Mac (screen, toolbar, macOS version) must not move it.
        titleBar.safeAreaRegions = []
        for sub in [split.view, titleBar] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: v.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            titleBar.topAnchor.constraint(equalTo: v.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: Theme.Height.barToolbar),
        ])
        view = v
        // The toolbar's content follows the chat column's edge, also while the sidebar is dragged or animates.
        if split.splitViewItems.count > 1 {
            let column = split.splitViewItems[1].viewController.view
            column.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: column,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateContentX() }
            })
        }
    }

    private func updateContentX() {
        guard split.splitViewItems.count > 1 else { return }
        let column = split.splitViewItems[1].viewController.view
        let x = column.convert(column.bounds, to: view).minX
        if metrics.contentX != x { metrics.contentX = x }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        TrafficLights.place(in: view.window)
        metrics.update(from: view.window)
        updateContentX()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let nc = NotificationCenter.default
        // Once: the window's notifications (a reappearing view must not add them again).
        if !observesWindow, let window = view.window {
            observesWindow = true
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didResizeNotification] {
                observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        TrafficLights.place(in: self?.view.window)
                        self?.metrics.update(from: self?.view.window)
                    }
                })
            }
        }
        TrafficLights.place(in: view.window)
        metrics.update(from: view.window)
        updateContentX()
    }
}

/// Traffic lights at x 20, centre y 26 in the 52 head (§3.1) without a toolbar, which on macOS 26 would give the window
/// the larger corner radius (#123): the titlebar container grows to 52, the buttons keep their size and system spacing.
/// shortcut: re-placed only on content layout, resize and full screen; setting the window's title, subtitle,
/// representedURL or a native tab bar resets the lights, so re-place if any of these is added.
@MainActor enum TrafficLights {
    static func place(in window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton), let bar = close.superview,
              let container = bar.superview else { return }
        let height = Theme.Height.barToolbar
        let top = window.frame.height - height
        if container.frame.height != height || container.frame.minY != top {
            container.frame = NSRect(x: container.frame.minX, y: top, width: container.frame.width, height: height)
        }
        let gap = mini.frame.minX - close.frame.maxX
        var x = Theme.Space.s5 - 1  // the 14-pt button draws its 12-pt circle 1 in: the circle's edge at x 20
        for button in [close, mini, zoom] {
            let size = button.frame.size
            let y = bar.isFlipped ? (height - size.height) / 2 : bar.bounds.height - height / 2 - size.height / 2
            let origin = NSPoint(x: x, y: y.rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            x += size.width + gap
        }
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
    /// The shown integration sheet's buttons and «Что изменится» (the debug channel presses them).
    var integrationSheetAnswer: ((Bool) -> Void)?
    var integrationSheetDiff: (() -> Void)?
    /// The integration sheet up now (one at a time; the next ask shows after it ends).
    var integrationSheet: NSWindow?
    #if DEBUG
    var newTaskModelForDebug: NewTaskModel? { newTaskModel }
    #endif
    private var sidebarAnimation: Timer?
    /// A tab dragged onto a pane edge (splits).
    private(set) var paneDrag: PaneDragController?
    /// The open ⌘P / ⇧⌘P palette; nil when closed.
    var palette: PaletteController?
    private var paletteLoad: Task<Void, Never>?
    /// The inspector root its files were taken from.
    private var paletteRoot: String?
    /// The chooser pane whose «Редактор» opened the palette: a picked file opens in that pane.
    private var palettePickFor: UUID?
    #if DEBUG
    var debugPalettePickFor: UUID? { palettePickFor }
    #endif
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
        // No NSToolbar: on macOS 26 it gives the window the larger corner radius; `TrafficLights` places the lights (#123).
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed  // a native tab bar would reset the hand-placed traffic lights
        window.backgroundColor = Theme.bg0
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = Theme.windowMinSize

        let splitView = HangarSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        split.splitView = splitView

        let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
        sidebarHost.sizingOptions = []
        sidebarHost.safeAreaRegions = []  // full height under the toolbar, whatever titlebar inset the window reports
        // Plain item: a `sidebar` item on macOS 26 floats over the content (Liquid Glass), not a full-height column.
        sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .init(260)
        split.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: column)
        split.addSplitViewItem(content)
        let inspectorHost = NSHostingController(rootView: InspectorView(app: app))
        inspectorHost.sizingOptions = []
        inspectorHost.safeAreaRegions = []
        inspectorItem = NSSplitViewItem(viewController: inspectorHost)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = Theme.inspectorMin
        inspectorItem.maximumThickness = Theme.inspectorMax
        inspectorItem.holdingPriority = .init(260)  // window resizes go to the terminal area
        inspectorItem.isCollapsed = !app.state.inspectorVisible
        split.addSplitViewItem(inspectorItem)

        let root = WindowRootController(app: app, split: split)
        window.contentViewController = root
        window.setContentSize(Theme.windowSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HangarMainWindow")
        inspectorWatch = InspectorWatch(app: app, window: window)

        sidebarHost.rootView = AnyView(SidebarView(app: app, ctx: ctx))
        column.tabBar.rootView = TabBarView(app: app, ctx: ctx)
        column.terminalArea.actionContext = ctx
        paneDrag = PaneDragController(app: app, area: column.terminalArea, tabBar: column.tabBar)
        root.titleBar.rootView = WindowTitleBar(app: app, metrics: root.metrics,
                                                inboxAction: { [weak self] in self?.inboxAction(leaf: $0, requestKey: $1, $2) },
                                                toggleSidebar: { [weak self] in self?.toggleSidebar() })
        column.sessions.rootView = SessionsHost(app: app, model: column.sessionsModel, ctx: ctx)
        // Undo selects the task again only if the archive left nothing selected (it was the selected one).
        app.branchModel.toast = { [weak self] in self?.column.archiveUndo.show(message: $0) }
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

        app.onChooseEditor = { [weak self] leaf in self?.togglePalette(commands: false, pickFor: leaf) }
        app.didChange = { [weak self] in
            guard let self else { return }
            // «Сессии» overlays the selected session: hiding its terminals hands their focus on; it comes back on Esc.
            let sessionsShown = self.app.sessionsViewVisible
            if self.column.sessions.isHidden == sessionsShown {
                self.column.sessions.isHidden = !sessionsShown
                self.column.tabBar.isHidden = sessionsShown
                self.column.terminalArea.isHidden = sessionsShown
                if !sessionsShown { DispatchQueue.main.async { self.column.terminalArea.focusActiveLeaf() } }
            }
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
        column.terminalArea.onNewTask = { [weak self] in self?.presentNewTask(projectId: nil) }
        app.onIntegrationAsk = { [weak self] in self?.presentIntegrationAsk() }
        app.onIntegrationError = { [weak self] text in
            self?.window?.beginHangarSheet { end in ConfirmSheet(message: text, onConfirm: { _ in end(.OK) }) }
        }
        // A restored tab may have asked while the window was being built: shown once it is up.
        DispatchQueue.main.async { [weak self] in self?.presentIntegrationAsk() }
        app.languageDidChange = { [weak self] in
            self?.installMainMenu()
            self?.settings.updateTitle()
            self?.notifier?.registerCategories()
        }
        installMainMenu()
        installKeyMonitor()
        observeTheme(#selector(applyTheme))
        // Passed reset times and «обновлено …» are recomputed when the user comes back, not by a timer.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.app.refreshUsageClock()
                // The SSH HOSTS list follows ~/.ssh/config edits made while Hangar was in the background (no watcher).
                self?.app.reloadConfigHosts()
                self?.app.updates.checkIfDue()  // at most hourly (#86)
            }
        }
        app.reloadConfigHosts()
        app.updates.onShow = { [weak self] in self?.presentUpdate() }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Theme switch: the window colours set once, and a redraw of AppKit-drawn parts (split dividers); SwiftUI redraws itself.
    @objc private func applyTheme() {
        guard let window else { return }
        window.backgroundColor = Theme.bg0
        window.attachedSheet?.backgroundColor = Theme.bg2
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        window.contentView.map(redraw)
    }

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

    /// Follows `inspectorVisible` (⌥⌘I, titlebar button); expanding restores the saved width.
    private func syncInspector() {
        let collapsed = !app.state.inspectorVisible || app.sessionsViewVisible  // «Сессии» takes the right sidebar's place too
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

    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Esc mid-drag cancels the drop, before anything else could take it (sheet, palette, «Сессии», terminal).
        if event.keyCode == 53, paneDrag?.cancel() == true { return true }
        // ⌘⇧L also closes the limits popover while it has the keyboard.
        if app.limitsPopoverShown, !event.isARepeat, shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) == .limits {
            app.toggleLimitsPopover()
            return true
        }
        // The palette panel keeps its keys (typing, ↑↓, ↩, Esc); only ⌘P / ⇧⌘P reach it from here, to toggle.
        if let palette, event.window === palette.panel {
            let sc = shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
            guard sc == .quickOpen || sc == .commandPalette else { return false }
            if !event.isARepeat, let sc { perform(sc) }
            return true
        }
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        // The usual quit (confirmation when agents work, state saved); the app menu alone misses ⌘Q in a terminal.
        if isQuitKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            NSApp.terminate(nil)
            return true
        }
        let consumed = route(event, in: window)
        // A key that goes on to a terminal or field ends the "just clicked a row/tab" state (F2 then passes through).
        if !consumed, firstResponderKind != .other { app.keyReachedTerminal() }
        return consumed
    }

    private func route(_ event: NSEvent, in window: NSWindow) -> Bool {
        // The inline rename field: ↩ must reach it, not relaunch the terminal.
        let editingText = window.firstResponder is NSText
        // Esc leaves «Сессии» (also from its search field).
        if app.sessionsViewVisible, event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            app.hideSessionsView()
            return true
        }
        // Monaco has the keyboard: the keys both want (⌘D, ⌘F, ⌘W, ⌥⌘←/→ …) by the editor policy (DESIGN.md, #80).
        let focus = webFocus
        if let key = editorKeyRoute(keyCode: event.keyCode, modifiers: event.modifierFlags, focus: focus) {
            if key == .monaco { return false }
            app.hangarShortcutConsumed()
            switch key {
            case .monaco: break
            case .prevDiffFile: app.diffNeighbour(-1)
            case .nextDiffFile: app.diffNeighbour(1)
            }
            return true
        }
        // ⌘F with the Git tab on screen: its search field (otherwise ⌘F goes on to the terminal).
        if event.keyCode == 3, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           app.state.inspectorVisible, app.inspector.segment == .git, !app.sessionsViewVisible, app.selectedTask != nil {
            app.gitPanel.searchFocusRequest += 1
            return true
        }
        // Before the shortcuts: ⌘W closes the diff tab, not the hidden tab; with focus in the TERMINAL panel keys go there.
        let diffActive = app.activeDiff != nil && column.terminalArea.drawer.focusedLeaf == nil
        if let key = diffKeyRoute(keyCode: event.keyCode, modifiers: event.modifierFlags, diffActive: diffActive, editingText: editingText,
                                     webFocused: focus == .diff) {
            app.hangarShortcutConsumed()
            switch key {
            case .up: app.diffNeighbour(-1)
            case .down: app.diffNeighbour(1)
            case .enter: if !event.isARepeat { app.openActiveDiffInEditor() }
            case .toggleMode: if !event.isARepeat { app.inspector.toggleMode() }
            case .close: if !event.isARepeat { app.closeDiff() }
            case .nextChange: column.terminalArea.shownDiffEditor?.goChange(next: true)
            case .prevChange: column.terminalArea.shownDiffEditor?.goChange(next: false)
            }
            return true
        }
        if let sc = shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            if sc == .rename {
                switch f2Route(firstResponderKind, lastInteraction: app.lastInteraction, selectedTask: app.selectedTask?.id) {
                case .passthrough: return false
                // A file tab / editor pane has no name of its own: F2 goes on (Monaco renames a symbol with it).
                case .rename(let target) where !app.renameable(target): return false
                case .rename(let target): Action.rename.perform(target, ctx)
                case .ignore: break
                }
                return true
            }
            // Held keys must not open/close/split dozens of tabs; the repeat is swallowed, not sent to the terminal.
            let once: [Shortcut] = [.closeTab, .newTab, .splitRight, .splitDown, .toggleDrawer, .limits, .revealInFinder, .copyPath, .quickOpen, .commandPalette, .nextAttention]
            app.hangarShortcutConsumed()
            if event.isARepeat && once.contains(sc) { return true }
            switch drawerRoute(sc, drawerFocused: column.terminalArea.drawer.focusedLeaf != nil, diffActive: app.activeDiff != nil,
                               sessionsShown: app.sessionsViewVisible) {
            case .ignore: break
            case .closeSessions: app.hideSessionsView()
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

    /// Monaco's editor or diff has the keyboard (a view inside its WKWebView is the first responder).
    private var webFocus: WebFocus {
        guard let view = window?.firstResponder as? NSView else { return .none }
        let chain = Array(sequence(first: view, next: { $0.superview }))
        guard chain.contains(where: { $0 is WKWebView }) else { return .none }
        return chain.contains { $0 is DiffHostView } ? .diff : .editor
    }

    private var firstResponderKind: FirstResponderKind {
        guard let responder = window?.firstResponder else { return .other }
        let view = responder as? NSView
        return responderKind(isText: responder is NSText, isWeb: webFocus != .none, inTerminalArea: view?.isDescendant(of: column.terminalArea) == true,
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
        // ⌘W in a split tab closes the focused pane, the last one closes the tab.
        if sc == .closeTab, let task = app.selectedTask, let tab = column.terminalArea.activeTab,
           case .pane(let leaf) = closeKeyRoute(tab, focused: column.terminalArea.focusedLeaf?.leafId) {
            Action.closePane.perform(.leaf(task: task.id, tab: tab.id, leaf: leaf), ctx)
            return
        }
        if let action = Action.allCases.first(where: { $0.shortcut == sc }) {
            if let target = keyTarget(for: action) { action.perform(target, ctx) }
            return
        }
        switch sc {
        case .newTask: presentNewTask(projectId: nil)
        case .newFreeChat: app.newFreeChat()
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
        case .inspectorGit: app.showInspector(.git)
        case .attentionFilter: app.perform { $0.attentionOnly.toggle() }
        case .limits: app.toggleLimitsPopover()
        case .prevTab: cycleTab(-1)
        case .nextTab: cycleTab(1)
        case .focusSplit(let direction):
            if !column.terminalArea.focusSplit(direction), let step = direction.taskFallback { app.selectTask(offset: step) }
        case .quickOpen: togglePalette(commands: false)
        case .commandPalette: togglePalette(commands: true)
        case .sessions: app.toggleSessionsView()
        case .findInFiles: app.showSearch()
        case .nextWorking: app.selectNextWorking()
        case .nextAttention:
            // Nothing waiting: nothing happens (R13).
            if let leaf = app.nextAttentionLeaf(drawerFocused: column.terminalArea.drawer.focusedLeaf?.leafId) { reveal(leafId: leaf) }
        }
    }

    // MARK: Palette

    /// ⌘P quick open (tasks, files; a typed `>` → commands), ⇧⌘P commands (the query starts as `>`), as in VS Code.
    /// The same key again closes it, the other one switches. `pickFor`: a chooser pane's «Редактор» (its file goes there).
    func togglePalette(commands: Bool, pickFor leafId: UUID? = nil) {
        if leafId != nil, palette != nil { closePalette() }
        if let palette {
            if palette.model.isCommands == commands { closePalette() } else { palette.model.setQuery(commands ? ">" : "") }
            return
        }
        guard let window, window.attachedSheet == nil else { return }
        let tasks = (app.state.freeChatTasks + app.pinnedTasks + app.state.projects.flatMap { app.groupTasks($0.id) }).map { t in
            PaletteItem(task: t.id, name: t.name, project: app.placeName(of: t))
        }
        let task = app.selectedTask
        let project = task.flatMap { app.project($0.projectId) }
        let root = task.flatMap { inspectorWatch?.root(of: $0) }
        // The inspector's list when it has this task's; else one `ls-files` (capped) on first need, no watcher.
        var files: [String]?
        var load: (() -> Void)?
        if let task, let project, let root {
            if app.inspector.shownTaskId == task.id, app.inspector.root == root, app.inspector.tree.count > 0 {
                files = paletteFiles(app.inspector.tree)
            } else {
                let git = app.git(for: project, repo: root)
                load = { [weak self] in self?.loadPaletteFiles(git) }
            }
        } else {
            files = []
        }
        let model = PaletteModel(tasks: tasks, files: files, commands: paletteCommands.map { PaletteItem(command: $0, title: L10n.command($0)) },
                                 query: commands ? ">" : "", loadFiles: load)
        paletteRoot = root
        palettePickFor = leafId
        palette = PaletteController(app: app, model: model, parent: window, choose: { [weak self] item in
            let pickFor = self?.palettePickFor
            self?.closePalette()
            self?.choosePalette(item, pickFor: pickFor)
        }, close: { [weak self] in self?.closePalette() })
    }

    /// The inspector's own listing (`git ls-files`), capped; a folder that is not a repository has no list here.
    private func loadPaletteFiles(_ git: Git) {
        paletteLoad = Task { [weak self] in
            let listing = try? await git.listFiles(limit: paletteFileCap)
            guard !Task.isCancelled, let self else { return }
            self.palette?.model.setFiles(listing.map { l in l.paths.filter { !l.dirLinks.contains($0) } } ?? [])
        }
    }

    func closePalette() {
        guard let palette else { return }
        self.palette = nil
        palettePickFor = nil
        paletteLoad?.cancel()
        paletteLoad = nil
        palette.dismiss()
        if NSApp.isActive { window?.makeKey() }  // back to the responder the window had (terminal, field)
    }

    func choosePalette(_ item: PaletteItem, pickFor leafId: UUID? = nil) {
        switch item.target {
        case .task(let id):
            if app.isFreeChatTask(id) { app.wakeFreeChat(id) } else { app.select(taskId: id) }
            column.terminalArea.focusActiveLeaf()
        case .file(let path):
            guard let paletteRoot else { return }
            if let leafId { app.chooseEditor(leafId, path: paletteRoot + "/" + path) } else { app.openInEditor(path: paletteRoot + "/" + path, line: nil) }
        case .command(let sc): perform(sc)
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
    #if DEBUG
    /// What would be on screen without a bundle (a recording center): `notices` / `noticeAction` debug commands.
    var debugNotices: [AgentNotice] = []
    #endif

    /// The app is active and the main window is on screen (a key Settings window or sheet doesn't hide it) (a notification for a hidden leaf is due otherwise).
    private var windowVisible: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Banners for attention out of sight (`Notifier.attach`); buttons go through `notificationAction`.
    /// Without a bundle: nothing in release, a recording center in DEBUG (`debugNotices`).
    public func enableNotifications() {
        // Dock badge and bounce: no bundle needed, so before the notifier's guard.
        app.onDockBadge = { NSApp.dockTile.badgeLabel = $0 }
        app.requestAttention = { if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) } }
        app.updateDockBadge()
        #if DEBUG
        notifier = Notifier.makeIfAvailable() ?? Notifier(center: .recorder { [weak self] edit in
            guard let self else { return }
            self.debugNotices = edit(self.debugNotices)
        })
        #else
        notifier = Notifier.makeIfAvailable()
        #endif
        guard let notifier else { return }
        if Notifier.hasBundle { app.notificationAuthorization = { await notifier.authorizationStatus() } }
        notifier.onAction = { [weak self] leaf, key, action in self?.noticeAction(leaf: leaf, requestKey: key, action) }
        notifier.attach(to: app, leafVisible: { [weak self] leaf in
            guard let self else { return false }
            return leafVisible(leaf, app: self.app, windowVisible: self.windowVisible)
        }, appActive: { NSApp.isActive })
        app.onUsageAlerts = { [weak self] alerts in
            guard let self else { return }
            for n in limitNotices(alerts, app: self.app) { self.notifier?.post(n) }
        }
    }

    /// A notification button or click; typing goes into the leaf without bringing the window up.
    func noticeAction(leaf: UUID?, requestKey: UUID?, _ action: NoticeAction) {
        apply(app.notificationAction(leaf: leaf, requestKey: requestKey, action), leaf: leaf, requestKey: requestKey)
    }

    /// An inbox row: the same guarded actions as a banner; the popover stays open only while typing into a terminal.
    func inboxAction(leaf: UUID, requestKey: UUID?, _ action: NoticeAction) {
        let result = app.notificationAction(leaf: leaf, requestKey: requestKey, action)
        if case .send = result {} else { app.setInboxShown(false) }
        apply(result, leaf: leaf, requestKey: requestKey)
    }

    /// One routing for banners and the inbox: reveal, type without activating, or show the limits.
    private func apply(_ result: NoticeResult, leaf: UUID?, requestKey: UUID?) {
        switch result {
        case .reveal:
            if let leaf { reveal(leafId: leaf) }
        case .send(let text, let keys):
            if let leaf { app.sendAnswer(leafId: leaf, requestKey: requestKey, text: text, keys: keys) }
        case .showLimits:
            bringUp()
            if !app.limitsPopoverShown { app.toggleLimitsPopover() }
        }
    }

    public func reveal(leafId: UUID) {
        app.reveal(leafId: leafId)
        bringUp()
        column.terminalArea.focus(leafId: leafId)
    }

    private func bringUp() {
        #if DEBUG
        // Verification runs (HANGAR_DEBUG_BEHIND=1) never take the owner's screen or keyboard.
        if ProcessInfo.processInfo.environment["HANGAR_DEBUG_BEHIND"] == "1" { return }
        #endif
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A clicked `hangar://` link (#66, #88): select and bring the window up; a tab link focuses its terminal.
    /// A malformed or dead link: the window comes up with a toast, nothing else changes.
    public func openLink(_ url: URL) {
        let target = app.openLink(url)
        if target == nil { column.archiveUndo.show(message: L10n.linkNotFound) }
        if case .tab(let task, let tab)? = target,
           let leaf = app.state.tasks.first(where: { $0.id == task })?.tabs.first(where: { $0.id == tab })?.focusedLeafId {
            reveal(leafId: leaf)
            return
        }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
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

    /// `thenNewTask`: "+ Новая сессия" with no projects — the new-task sheet follows the added project.
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
        sheet.backgroundColor = Theme.bg2
        sheet.appearance = window.appearance
        sheet.autorecalculatesKeyViewLoop = true  // Tab reaches the copy's fields, which appear after the sheet opens
        let model = NewTaskModel(project: project, git: app.git(for: project), taskBranches: app.taskBranches(id),
                                 chatNames: { [weak app] in app?.state.tasks.filter { $0.projectId == id }.map(\.name) ?? [] })
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
        let view = NewTaskSheet(model: model, projectName: project.name,
                                agentName: app.config.defaultAgent == .codex ? "Codex" : "Claude",
                                onCreate: { [weak self] name, message, mode in
                                    close()
                                    guard let app = self?.app else { return }
                                    // Turning the suggested command on is the opt-in: it becomes the project's own.
                                    if let command = model.commandToSave, let p = app.project(id) {
                                        app.perform { $0.setWorktreeSetup(id: id, copy: p.worktreeCopy, command: command) }
                                    }
                                    app.createTask(projectId: id, name: name, firstMessage: message, mode: mode, setup: model.setupScript,
                                                   autoNamed: model.chatNameIsAuto)
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
        let unsaved = (app.unsavedEditorFiles().count + (app.diffUnsaved?() ?? 0))
        let text = unsaved > 0 ? (L10n.editorUnsavedQuit(unsaved), L10n.editorUnsavedInfo) : quitConfirmation(working: app.quitWorkingCount)
        guard let window, let text else { then(true); return }
        guard !quitAlertShown else { then(false); return }
        quitAlertShown = true
        // Quit from Settings («Обновить до …» there): the question would hide behind that window.
        if NSApp.isActive, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.beginHangarSheet({ end in
            ConfirmSheet(message: text.message, info: text.info, button: L10n.quit,
                         onConfirm: { _ in end(.OK) }, onCancel: { end(.cancel) })
        }, done: { [weak self] response in
            self?.quitAlertShown = false
            let ok = response == .OK
            if ok { self?.quitConfirmed = true }
            then(ok)
        })
    }

    /// For `applicationShouldTerminate`.
    public func currentQuitDecision(forced: Bool = false) -> QuitDecision {
        quitDecision(creating: isCreatingTask || app.controlCreating > 0, working: app.quitWorkingCount + (app.unsavedEditorFiles().count + (app.diffUnsaved?() ?? 0)),
                     confirmed: quitConfirmed,
                     asking: quitAlertShown, forced: forced)
    }

    /// Non-modal feedback for a refused close/quit: a sheet on the new-task sheet (or on the window).
    public func notifyCreatingTask() {
        guard let host = sheetWindow ?? window, host.attachedSheet == nil else { return }
        host.beginHangarSheet { end in ConfirmSheet(message: L10n.creatingWorktreeWait, onConfirm: { _ in end(.OK) }) }
    }

    private func makeSheet(over window: NSWindow) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: Theme.sheetPlaceholderHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.bg2
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

    /// «Доступна версия X» (#86): from the status-bar pill or Settings.
    func presentUpdate() {
        guard let window, window.attachedSheet == nil, app.updates.offer != nil else { return }
        let sheet = makeSheet(over: window)
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
            self.app.updates.closeSheet = nil
        }
        app.updates.closeSheet = close
        begin(sheet, UpdateSheet(model: app.updates, onClose: close), on: window)
    }

    /// «Подключиться к хосту…»: a plain ssh shell tab on the host (#64).
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
        sheet.backgroundColor = Theme.bg2
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
        }, onNotifications: { [weak self] in self?.app.setProjectNotifications(id, $0) }, onKeepWorktreesBeside: { [weak self] in
            self?.app.perform { s in s.projects.firstIndex { $0.id == id }.map { s.projects[$0].worktreeRoot = nil } }
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

    /// Archive / delete / remove confirmation as a Hangar sheet (`ConfirmSheet`); `checkbox` (off by default) is its
    /// switch row, and `then` gets its state.
    private func confirm(_ message: String, _ info: String, _ button: String, checkbox: String?, _ then: @escaping (Bool) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        sheetWindow = window.beginHangarSheet({ end in
            ConfirmSheet(message: message, info: info, button: button, checkbox: checkbox,
                         onConfirm: { checked in end(.OK); then(checked) }, onCancel: { end(.cancel) })
        }, done: { [weak self] _ in self?.sheetWindow = nil })
    }

    private func showError(_ message: String, _ info: String) {
        guard let window, window.attachedSheet == nil else { return }
        window.beginHangarSheet { end in ConfirmSheet(message: message, info: info, onConfirm: { _ in end(.OK) }) }
    }

    private func showConfigWarning(_ text: String) {
        guard let window else { return }
        window.beginHangarSheet { end in
            ConfirmSheet(message: L10n.configNotApplied, info: "\(text)\n\(L10n.usingDefaults)", onConfirm: { _ in end(.OK) })
        }
    }
}
