import AppKit
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

/// Titlebar row, tab bar row, terminal area.
private final class TaskColumnController: NSViewController {
    let terminalArea: TerminalArea
    private let titleBar: NSHostingView<TitleBarView>
    private let tabBar: NSHostingView<TabBarView>

    init(app: AppState) {
        terminalArea = TerminalArea(app: app)
        titleBar = NSHostingView(rootView: TitleBarView(app: app))
        tabBar = NSHostingView(rootView: TabBarView(app: app))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        titleBar.sizingOptions = []
        tabBar.sizingOptions = []
        for sub in [titleBar, tabBar, terminalArea] as [NSView] {
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
            terminalArea.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }
}

public final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let app: AppState
    private let split = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let column: TaskColumnController
    nonisolated(unsafe) private var keyMonitor: Any?
    private var sheetWindow: NSWindow?
    private var sidebarAnimation: Timer?
    private var didApplyInitialLayout = false
    private let configWarning: String?
    private lazy var settings = SettingsWindowController(app: app)

    public init(app: AppState, configWarning: String?) {
        self.app = app
        self.configWarning = configWarning
        column = TaskColumnController(app: app)

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

        var actions = SidebarActions(addProject: {}, newTask: { _ in }, renameTask: { _ in }, renameProject: { _ in },
                                     toggleCollapsed: {}, openSettings: {})
        let sidebarHost = NSHostingController(rootView: AnyView(EmptyView()))
        sidebarHost.sizingOptions = []
        // Plain item: a `sidebar` item on macOS 26 floats over the content (Liquid Glass), not a full-height column.
        sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .init(260)
        split.addSplitViewItem(sidebarItem)
        let content = NSSplitViewItem(viewController: column)
        split.addSplitViewItem(content)

        window.contentViewController = split
        window.setContentSize(Theme.windowSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("HangarMainWindow")

        actions = SidebarActions(
            addProject: { [weak self] in self?.chooseProject() },
            newTask: { [weak self] id in self?.presentNewTask(projectId: id) },
            renameTask: { [weak self] task in
                self?.askName(L10n.renameTask, current: task.name) { self?.app.rename(taskId: task.id, to: $0) }
            },
            renameProject: { [weak self] project in
                self?.askName(L10n.renameProject, current: project.name) { self?.app.rename(projectId: project.id, to: $0) }
            },
            toggleCollapsed: { [weak self] in self?.toggleSidebar() },
            openSettings: { [weak self] in self?.showSettings(nil) })
        sidebarHost.rootView = AnyView(SidebarView(app: app, actions: actions))
        splitView.onDragEnd = { [weak self] in self?.sidebarDragEnded() }

        app.didChange = { [weak self] in self?.column.terminalArea.sync() }
        column.terminalArea.onAddProject = { [weak self] in self?.chooseProject() }
        app.languageDidChange = { [weak self] in
            self?.installMainMenu()
            self?.settings.updateTitle()
        }
        installMainMenu()
        installKeyMonitor()
        #if DEBUG
        installDebugHooks()
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didApplyInitialLayout, let window else { return }
        didApplyInitialLayout = true
        // Position the divider only after the split view has its real size, else setPosition is ignored.
        window.contentView?.layoutSubtreeIfNeeded()
        applySidebarWidth()
        column.terminalArea.sync()
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
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        if let sc = shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            // Held keys must not open/close/split dozens of tabs; the repeat is swallowed, not sent to the terminal.
            let once: [Shortcut] = [.closeTab, .newTab, .splitRight, .splitDown]
            if !(event.isARepeat && once.contains(sc)) { perform(sc) }
            return true
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 36, mods.isEmpty { return column.terminalArea.relaunchFocusedIfExited() }  // ↩
        return false
    }

    private func perform(_ sc: Shortcut) {
        let area = column.terminalArea
        switch sc {
        case .newTask: presentNewTask(projectId: nil)
        case .newTab: app.addTab(.shell)
        case .closeTab: if let tab = area.activeTab { app.closeTab(tab.id) }
        case .splitRight: if let leaf = area.focusedLeaf { app.split(leafId: leaf.leafId, axis: .horizontal) }
        case .splitDown: if let leaf = area.focusedLeaf { app.split(leafId: leaf.leafId, axis: .vertical) }
        case .tab(let n): app.activate(tabNumber: n)
        case .prevTask: app.selectTask(offset: -1)
        case .nextTask: app.selectTask(offset: 1)
        // shortcut: only flips the persisted flag; the inspector itself arrives in stage 2
        case .toggleInspector: app.perform { $0.inspectorVisible.toggle() }
        case .toggleSidebar: toggleSidebar()
        case .addProject: chooseProject()
        case .settings: showSettings(nil)
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

    private func presentNewTask(projectId: UUID?) {
        guard let window, window.attachedSheet == nil else { return }
        let id = projectId ?? app.selectedTask?.projectId ?? app.state.projects.last?.id
        guard let id, let project = app.project(id) else { chooseProject(thenNewTask: true); return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.sheetWidth, height: 200),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.backgroundColor = Theme.sheet
        sheet.appearance = window.appearance
        let close: () -> Void = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            window.endSheet(sheet)
            self.sheetWindow = nil
        }
        let view = NewTaskSheet(projectName: project.name, agentName: app.config.defaultAgent.rawValue,
                                onCreate: { [weak self] name, message in
                                    close()
                                    self?.app.createTask(projectId: id, name: name, firstMessage: message)
                                },
                                onCancel: close)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    private func askName(_ title: String, current: String, apply: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: Theme.renameFieldWidth, height: field.intrinsicContentSize.height)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.rename)
        alert.addButton(withTitle: L10n.cancel)
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { apply(field.stringValue) }
        }
    }

    private func showConfigWarning(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.configNotApplied
        alert.informativeText = "\(text)\n\(L10n.usingDefaults)"
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Debug hooks

    #if DEBUG
    /// HANGAR_DEBUG_PROJECT=<path> adds a project at launch; `dev.hangar.debug` distributed
    /// notifications (object = command) drive the UI for verification without a screen.
    private func installDebugHooks() {
        // The hook drives the UI (incl. typing into terminals): only for explicit verification runs.
        guard let path = ProcessInfo.processInfo.environment["HANGAR_DEBUG_PROJECT"] else { return }
        // Empty path: hooks without a project (empty-state checks).
        if !path.isEmpty, !app.state.projects.contains(where: { $0.path == path }) { app.addProject(path: path) }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.hangar.debug"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(command) }
        }
    }

    private func debugCommand(_ command: String) {
        uiLog.info("debug command: \(command, privacy: .public)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let shortcuts: [String: Shortcut] = [
            "newTab": .newTab, "closeTab": .closeTab, "splitRight": .splitRight, "splitDown": .splitDown,
            "prevTask": .prevTask, "nextTask": .nextTask, "toggleSidebar": .toggleSidebar, "toggleInspector": .toggleInspector,
        ]
        switch parts.first ?? "" {
        case "task":
            let fields = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard let project = app.selectedTask?.projectId ?? app.state.projects.first?.id else { return }
            app.createTask(projectId: project, name: fields[0], firstMessage: fields.count > 1 ? fields[1] : "")
        case "tab": LeafKind(rawValue: arg).map(app.addTab)
        case "key":
            if let sc = shortcuts[arg] { perform(sc) } else if let n = Int(arg) { perform(.tab(n)) }
        case "select": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.select(taskId: app.orderedTasks[n].id) }
        case "type":
            column.terminalArea.focusedLeaf?.surface?.sendText(arg)
            column.terminalArea.focusedLeaf?.surface?.sendEnter()
        case "pin": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.setPinned(app.orderedTasks[n].id, true) }
        case "archive": if let n = Int(arg), app.orderedTasks.indices.contains(n) { app.archive(taskId: app.orderedTasks[n].id) }
        case "fold": if let p = app.state.projects.first { app.setCollapsed(projectId: p.id, !p.collapsed) }
        case "project": app.addProject(path: arg)
        case "snap":
            // Chrome snapshot when the screen can't be captured (Metal terminal layers may come out blank).
            let target = arg.contains("settings") ? settings.window : (window?.attachedSheet ?? window)
            guard let view = target?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
        case "enter": _ = column.terminalArea.relaunchFocusedIfExited()
        case "sheet": presentNewTask(projectId: nil)
        case "settings": showSettings(nil)
        case "lang":
            if let lang = Language(rawValue: arg) {
                do { try app.setLanguage(lang) } catch { uiLog.error("lang: \(error.localizedDescription, privacy: .public)") }
            }
            uiLog.info("l10n bundle=\(L10n.resources.bundlePath, privacy: .public) language=\(L10n.language.rawValue, privacy: .public) pinned=\(L10n.sectionPinned, privacy: .public) exit=\(L10n.exitedWithCode(3), privacy: .public) menu=\(NSApp.mainMenu?.items.last?.submenu?.title ?? "-", privacy: .public)")
        case "dump":
            let tasks = app.state.tasks.map { t in
                "\(t.name) archived=\(t.archived) tabs=\(t.tabs.map { app.tabLabel($0) }) active=\(t.activeTabId == nil ? "-" : "set")"
            }
            uiLog.info("dump selected=\(self.app.selectedTask?.name ?? "-", privacy: .public) sidebar=\(self.app.state.sidebarWidth)/\(self.app.state.sidebarCollapsed) actual=\(self.sidebarItem.viewController.view.frame.width) panes=\(self.split.splitView.subviews.map { Int($0.frame.width) }, privacy: .public) win=\(Int(self.window?.frame.width ?? 0))\n\(tasks.joined(separator: "\n"), privacy: .public)\n\(self.column.terminalArea.debugDump(), privacy: .public)")
        default: break
        }
    }
    #endif
}
