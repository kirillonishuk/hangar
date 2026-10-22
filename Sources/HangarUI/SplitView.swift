import AgentStatus
import AppKit
import ControlServer
import Exec
import GhosttyBridge
import Workspace

/// NSSplitView with the theme divider and a hook when the user finishes dragging a divider.
class HangarSplitView: NSSplitView {
    var onDragEnd: (() -> Void)?
    /// Index of the divider under the last mouse-down (nil: none); read in `onDragEnd`.
    private(set) var draggedDivider: Int?

    override var dividerColor: NSColor { Theme.line }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        draggedDivider = (0..<max(0, arrangedSubviews.count - 1)).first { dividerHitRect($0).contains(p) }
        super.mouseDown(with: event)  // runs the divider tracking loop until mouse up
        onDragEnd?()
    }

    /// The divider after subview `i`, widened like AppKit's own hit area for thin dividers.
    private func dividerHitRect(_ i: Int) -> NSRect {
        let f = arrangedSubviews[i].frame
        let slop = Theme.dividerHitSlop
        return isVertical
            ? NSRect(x: f.maxX - slop, y: bounds.minY, width: dividerThickness + 2 * slop, height: bounds.height)
            : NSRect(x: bounds.minX, y: f.maxY - slop, width: bounds.width, height: dividerThickness + 2 * slop)
    }
}

/// Two panes laid out by `ratio` (so window resizes keep proportions); a drag commits the new ratio.
final class RatioSplitView: HangarSplitView {
    var ratio: Double

    init(axis: Workspace.Axis, ratio: Double) {
        self.ratio = ratio
        super.init(frame: .zero)
        isVertical = axis == .horizontal  // horizontal axis = panes side by side = vertical divider
        dividerStyle = .thin
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var total: CGFloat { (isVertical ? bounds.width : bounds.height) - dividerThickness }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { return super.resizeSubviews(withOldSize: oldSize) }
        let a = max(0, (total * ratio).rounded())
        let b = max(0, total - a)
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: a, height: bounds.height)
            subviews[1].frame = NSRect(x: a + dividerThickness, y: 0, width: b, height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: a)
            subviews[1].frame = NSRect(x: 0, y: a + dividerThickness, width: bounds.width, height: b)
        }
    }

    /// Ratio after a divider drag.
    var measuredRatio: Double? {
        guard subviews.count == 2, total > 0 else { return nil }
        let first = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        return Double(first / total)
    }
}

/// One split pane: optional header (when the tab is split), the terminal surface, and an exit/error bar.
@MainActor final class LeafView: NSView {
    let leafId: UUID
    private(set) var surface: TerminalSurfaceView?
    /// Builds the spec of one launch; each relaunch asks again with `.relaunch(previous:exitCode:)`.
    private var make: ((LaunchContext) throws -> (LaunchSpec, LaunchMode))?
    private var mode: LaunchMode?
    private let header = NSTextField(labelWithString: "")
    private let headerLine = NSView()
    private let bar = NSTextField(labelWithString: "")
    private let barLine = NSView()
    /// Non-nil while the process has exited with a failure (↩ relaunches).
    private(set) var exitCode: Int32?
    /// Ghostty could not create the surface (e.g. no display); ↩ or a display wake retries.
    private(set) var failed = false
    var needsRelaunch: Bool { exitCode != nil || failed }
    /// A new surface replaced the old one; `keepsStatus`: the same agent goes on (reattach, a launch that never ran).
    var onRelaunch: ((_ keepsStatus: Bool) -> Void)?
    /// ssh host of a remote project's leaf (nil = local): its 255 means the tmux session did not end (#47).
    var host: String?
    /// The client of a remote session exited with 255 (connection lost, detach); ↩ or the reconnect reattaches.
    private(set) var isDetached = false
    /// The launch that met `.notConnected`, made again by `resumeIfWaiting` once the host is up.
    private var waiting: LaunchContext?
    var isWaitingForHost: Bool { waiting != nil }
    /// Set with `host`: the bar text when the host is not on its way (given up, disconnected, retry paused) — then the
    /// waiting bar offers «Переподключиться»; nil while it is connecting.
    var reconnectText: () -> String? = { nil }
    var onReconnect: (() -> Void)?
    var canReconnect: Bool { waiting != nil && reconnectText() != nil }
    var showsHeader = false { didSet { needsLayout = true; header.isHidden = !showsHeader; headerLine.isHidden = !showsHeader } }
    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFocus: (() -> Void)?
    /// Terminal bell / OSC 9·777 notification: the status fallback for agents without hooks.
    var onBell: (() -> Void)?
    var onNotification: (() -> Void)?

    init(leafId: UUID) {
        self.leafId = leafId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        for label in [header, bar] {
            label.font = .systemFont(ofSize: Theme.fontSize.small)
            label.textColor = Theme.text3
            label.lineBreakMode = .byTruncatingTail
        }
        bar.textColor = Theme.text2
        bar.font = .systemFont(ofSize: Theme.fontSize.counter)
        for line in [headerLine, barLine] {
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.line.cgColor
        }
        [header, headerLine, bar, barLine].forEach(addSubview)
        header.isHidden = true
        headerLine.isHidden = true
        setBar(nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setHeader(_ text: String) { header.stringValue = text }

    /// Starts the surface; a launch error (missing folder) shows in the bar instead.
    func start(_ context: LaunchContext, make: @escaping (LaunchContext) throws -> (LaunchSpec, LaunchMode)) {
        self.make = make
        _ = run(context)
    }

    /// False when the spec could not be built (the bar shows why).
    private func run(_ context: LaunchContext) -> Bool {
        guard let make else { return false }
        do {
            waiting = nil
            let (spec, mode) = try make(context)
            self.mode = mode
            setBar(nil)
            launch(spec)
            return true
        } catch LaunchError.missingCwd(let path) {
            setBar(L10n.folderMissing(path))
        } catch LaunchError.notConnected(let host) {
            waiting = context
            // Re-read on every `refreshText` (host changes): «connecting…» until the host is given up on.
            barText = { [weak self] in self?.reconnectText() ?? L10n.hostNotConnected(host) }
            refreshText()
        } catch {
            setBar(L10n.launchFailed(String(describing: error)))
        }
        return false
    }

    private func launch(_ spec: LaunchSpec) {
        let view = TerminalSurfaceView(spec: spec)
        view.onChildExit = { [weak self] code in self?.childExited(code) }
        view.onTitleChange = { [weak self] title in self?.onTitle?(title) }
        view.onFocus = { [weak self] in self?.onFocus?() }
        view.onBell = { [weak self] in self?.onBell?() }
        view.onDesktopNotification = { [weak self] _, _ in self?.onNotification?() }
        if let old = surface {
            // Replacing an exited (or not yet drawn, `restart`) surface: removing it is a real close.
            old.removeFromSuperview()
        }
        surface = view
        drewOutput = false
        addSubview(view, positioned: .below, relativeTo: header)
        needsLayout = true
        failed = !view.isAlive
        if failed {
            uiLog.error("terminal not created leaf=\(self.leafId.uuidString.prefix(8), privacy: .public)")
            setBar(L10n.terminalCreateFailed)
        }
    }

    func childExited(_ code: Int32) {
        if code == 0 { onExit?(0); return }
        exitCode = code
        if host != nil, code == 255 {
            // Not an exit of the agent: no `.exited`, the leaf and its status stay.
            isDetached = true
            setBar(L10n.sessionDetached)
            return
        }
        setBar("\(code == -1 ? L10n.exited : L10n.exitedWithCode(code)) · \(L10n.relaunchHint)")
        onExit?(code)
    }

    /// ↩ on an exited or failed leaf: launch again with a mode computed for this relaunch (decision #41;
    /// `focus: false` for background retries).
    func relaunch(focus: Bool = true) {
        guard needsRelaunch, let mode else { return }
        let reattach = isDetached
        let code = failed ? nil : exitCode
        exitCode = nil
        failed = false
        isDetached = false
        guard run(reattach ? .reattach(previous: mode) : .relaunch(previous: mode, exitCode: code)) else {
            // No new process (missing folder): drop the dead surface so CLI/MCP never paste into it (`failed`).
            surface?.onChildExit = nil
            surface?.removeFromSuperview()
            surface = nil
            return
        }
        uiLog.info("relaunch leaf=\(self.leafId.uuidString.prefix(8), privacy: .public) ok=\(!self.failed)")
        if focus, !failed { window?.makeFirstResponder(surface) }
        onRelaunch?(reattach)
    }

    /// The host connected: the launch that waited for it runs now (with its own context: a first prompt is still sent).
    func resumeIfWaiting() {
        guard let context = waiting, run(context) else { return }
        uiLog.info("resumed leaf=\(self.leafId.uuidString.prefix(8), privacy: .public) ok=\(!self.failed)")
        onRelaunch?(true)
    }

    /// For CLI/MCP (decision #45); the view starts its surface on creation, so no surface means the launch could not happen.
    var controlState: LeafState {
        if failed || surface == nil { return .failed }
        if exitCode != nil { return .exited }
        return hasOutput ? .running : .starting
    }

    /// Text as a paste, then real key presses in order; only on a `running` leaf.
    func send(text: String?, keys: [SendKey]) {
        guard let surface, controlState == .running else { return }
        if let text { surface.sendText(text) }
        for key in keys {
            switch key {
            case .enter: surface.sendEnter()
            case .escape: surface.sendKey(.escape)
            case .tab: surface.sendKey(.tab)
            case .backspace: surface.sendKey(.backspace)
            case .up: surface.sendKey(.up)
            case .down: surface.sendKey(.down)
            case .left: surface.sendKey(.left)
            case .right: surface.sendKey(.right)
            case .ctrlC: surface.sendKey(.ctrlC)
            case .ctrlD: surface.sendKey(.ctrlD)
            }
        }
    }

    /// Restarts a running surface that has shown nothing yet (a just-launched editor), so the new `openFile` applies.
    func restart() {
        guard let old = surface, !needsRelaunch, !hasOutput, let mode else { return }
        // Freeing the old surface ends its process; that is not an exit of the leaf. Restored if the new run fails.
        let handler = old.onChildExit
        old.onChildExit = nil
        guard run(.relaunch(previous: mode, exitCode: nil)) else {
            old.onChildExit = handler
            return
        }
        uiLog.info("restart leaf=\(self.leafId.uuidString.prefix(8), privacy: .public) ok=\(!self.failed)")
        if !failed { window?.makeFirstResponder(surface) }
        onRelaunch?(false)
    }

    /// The process has drawn something since launch; before that a starting Helix may not read keys yet.
    /// `shortcut: any non-blank screen text counts (a "Last login" line too); Ghostty has no output callback and
    /// ghostty.h exposes no alternate-screen query — use one if GhosttyKit adds it`.
    var hasOutput: Bool {
        if !drewOutput, surface?.screenText()?.contains(where: { !$0.isWhitespace }) == true { drewOutput = true }
        return drewOutput
    }
    private var drewOutput = false

    /// Kept as a closure so a language switch can re-render the visible message (`refreshText`).
    private var barText: () -> String? = { nil }

    private func setBar(_ text: @autoclosure @escaping () -> String?) {
        barText = text
        refreshText()
    }

    func refreshText() {
        let text = barText()
        guard text != (bar.isHidden ? nil : bar.stringValue) else { return }
        bar.stringValue = text ?? ""
        bar.isHidden = text == nil
        barLine.isHidden = text == nil
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    #if DEBUG
    var barString: String? { bar.isHidden ? nil : bar.stringValue }
    #endif

    /// ↩ or a click on the bar: relaunch an exited/failed leaf, or reconnect the host a waiting one gave up on.
    func activateBar() {
        if canReconnect { onReconnect?() } else { relaunch() }
    }

    /// The ↩ bar of an exited/failed leaf (or of one whose host gave up) is clickable.
    override func resetCursorRects() {
        if !bar.isHidden, needsRelaunch || canReconnect { addCursorRect(bar.frame.union(barLine.frame), cursor: .pointingHand) }
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !bar.isHidden, needsRelaunch || canReconnect, bar.frame.contains(convert(event.locationInWindow, from: nil)) {
            activateBar()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let px = Theme.paneHeaderPaddingH, py = Theme.paneHeaderPaddingV
        var top: CGFloat = 0
        if showsHeader {
            let h = ceil(header.intrinsicContentSize.height) + 2 * py
            header.frame = NSRect(x: px, y: py, width: max(0, bounds.width - 2 * px), height: h - 2 * py)
            headerLine.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
            top = h
        }
        var bottom = bounds.height
        if !bar.isHidden {
            let h = Theme.statusBarHeight
            bottom -= h
            barLine.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: 1)
            let th = ceil(bar.intrinsicContentSize.height)
            bar.frame = NSRect(x: px, y: bottom + (h - th) / 2, width: max(0, bounds.width - 2 * px), height: th)
        }
        surface?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        window?.invalidateCursorRects(for: self)
    }
}

/// All terminal content. Tabs get a view on first show and keep it (and its surfaces) until closed;
/// switching only toggles visibility, so surfaces never leave the window (decision for pending clipboard prompts).
@MainActor final class TerminalArea: NSView {
    private let app: AppState
    private var tabViews: [UUID: NSView] = [:]
    private var structure: [UUID: String] = [:]
    private var leafViews: [UUID: LeafView] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    private var shownTab: UUID?
    private var shownFocus: UUID?
    /// The task's diff tab is shown instead of its tabs (created on first use).
    private var diffHost: DiffHostView?
    private var shownDiff = false
    private let placeholder = NSTextField(labelWithString: "")
    /// Tab content above the drawer.
    private let content = NSView()
    let drawer: TerminalDrawer
    private var appliedDrawerHeight: CGFloat = 0
    /// No projects yet: "+ Добавить проект" button and the ⌘⇧N hint.
    private var emptyState = NSView()
    var onAddProject: () -> Void = {}

    init(app: AppState) {
        self.app = app
        drawer = TerminalDrawer(app: app)
        super.init(frame: .zero)
        content.autoresizingMask = []
        addSubview(content)
        addSubview(drawer)
        drawer.onToggle = { [weak self] in if let id = self?.app.selectedTask?.id { self?.toggleDrawer(taskId: id) } }
        drawer.onReturnFocus = { [weak self] in self?.focusActiveLeaf() }
        app.onOpenInEditor = { [weak self] path, line in self?.openInEditor(path: path, line: line) }
        app.onHostConnected = { [weak self] host in
            guard let self else { return }
            hostConnected(host: host, leaves: Array(leafViews.values) + drawer.leaves)
        }
        app.onHostChange = { [weak self] host in
            guard let self else { return }
            for view in Array(leafViews.values) + drawer.leaves where view.host == host { view.refreshText() }
        }
        app.terminals = TerminalAccess(
            start: { [weak self] in self?.startHidden(tabId: $0); self?.drawer.startHidden(leafId: $0) },
            state: { [weak self] in self?.controlLeaf($0)?.controlState ?? .notStarted },
            send: { [weak self] in self?.controlLeaf($0)?.send(text: $1, keys: $2) },
            read: { [weak self] in self?.controlLeaf($0)?.surface?.screenText() })
        drawer.onResize = { [weak self] in self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
        emptyState = EmptyStateView.hosted { [weak self] in self?.onAddProject() }
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        placeholder.font = .systemFont(ofSize: Theme.fontSize.base)
        placeholder.textColor = Theme.text3
        placeholder.alignment = .center
        addSubview(placeholder)
        addSubview(emptyState)
        // One retry per display wake for surfaces that failed (typically created while the display slept).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryFailedLeaves() }
        }
    }

    private func retryFailedLeaves() {
        for leaf in leafViews.values where leaf.failed { leaf.relaunch(focus: false) }
        drawer.retryFailedLeaves()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = placeholder.intrinsicContentSize.height
        placeholder.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        emptyState.frame = bounds
        applyDrawerFrames(animated: false)
    }

    /// Splits the area into tab content and the drawer; an expand/collapse animates once (none with Reduce Motion).
    private func applyDrawerFrames(animated: Bool) {
        let total = drawer.totalHeight(available: bounds.height)
        let drawerFrame = NSRect(x: 0, y: 0, width: bounds.width, height: total)
        let contentFrame = NSRect(x: 0, y: total, width: bounds.width, height: max(0, bounds.height - total))
        if animated, !Motion.reduced, window != nil, total != appliedDrawerHeight {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.drawerAnimation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                drawer.animator().frame = drawerFrame
                content.animator().frame = contentFrame
            }
        } else {
            drawer.frame = drawerFrame
            content.frame = contentFrame
        }
        appliedDrawerHeight = total
    }

    /// ⌃` and the bar: expand (focus goes into the shell) or collapse (focus returns to the tab if it was in the shell).
    func toggleDrawer(taskId: UUID) {
        let focusWasInDrawer = drawer.focusedLeaf != nil
        app.perform { $0.toggleDrawer(taskId: taskId) }
        if app.state.tasks.first(where: { $0.id == taskId })?.drawer.visible == true {
            window?.makeFirstResponder(drawer.currentSurface)
        } else if focusWasInDrawer {
            focusActiveLeaf()
        }
    }

    var activeTab: Tab? {
        guard let task = app.selectedTask else { return nil }
        return task.tabs.first { $0.id == task.activeTabId }
    }

    /// The leaf whose surface has keyboard focus, else the active tab's focused leaf.
    var focusedLeaf: LeafView? {
        if let leaf = drawer.focusedLeaf { return leaf }
        guard let tab = activeTab else { return nil }
        if let responder = window?.firstResponder as? NSView,
           let leaf = tab.root.leaves.lazy.compactMap({ self.leafViews[$0.id] }).first(where: { responder.isDescendant(of: $0) }) {
            return leaf
        }
        return leafViews[tab.focusedLeafId]
    }

    /// Reconciles views with the model after each mutation.
    func sync() {
        let state = app.state
        drawer.sync()
        applyDrawerFrames(animated: true)
        let liveTabs = state.tasks.filter { !$0.archived }.flatMap(\.tabs)
        let liveTabIds = Set(liveTabs.map(\.id))
        let liveLeafIds = Set(liveTabs.flatMap { $0.root.leaves.map(\.id) })

        // Closed tabs/leaves and archived tasks: these are real closes, the surfaces go away.
        for (id, view) in tabViews where !liveTabIds.contains(id) {
            view.removeFromSuperview()
            tabViews[id] = nil
            structure[id] = nil
        }
        for (id, leaf) in leafViews where !liveLeafIds.contains(id) {
            leaf.removeFromSuperview()
            leafViews[id] = nil
            lastVisible[id] = nil
            app.leafTitles[id] = nil
            uiLog.info("surface closed leaf=\(id.uuidString.prefix(8), privacy: .public)")
        }

        let diffShown = app.activeDiff != nil
        if diffShown, diffHost == nil {
            let host = DiffHostView(rootView: DiffView(app: app))
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            diffHost = host
        }
        diffHost?.isHidden = !diffShown
        let active = activeTab
        if let tab = active { show(tab) }
        for tab in liveTabs where tabViews[tab.id] != nil && tab.id != active?.id {
            if structure[tab.id] != signature(tab.root) { layoutTab(tab) }  // e.g. a hidden leaf exited with 0
        }
        for (id, view) in tabViews { view.isHidden = diffShown || id != active?.id }
        for tab in liveTabs {
            for leaf in tab.root.leaves {
                guard let view = leafViews[leaf.id], let surface = view.surface else { continue }
                let visible = !diffShown && tab.id == active?.id
                if lastVisible[leaf.id] != visible {
                    lastVisible[leaf.id] = visible
                    surface.setVisible(visible)
                    uiLog.info("setVisible(\(visible)) leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public)")
                }
                view.setHeader(app.title(of: leaf))
                view.refreshText()
            }
        }

        emptyState.isHidden = !state.projects.isEmpty
        placeholder.isHidden = active != nil || diffShown || state.projects.isEmpty
        placeholder.stringValue = app.selectedTask == nil ? L10n.emptyNoTask : L10n.emptyNoTabs

        // Focus follows tab switches, new splits and closed leaves; plain re-syncs never steal focus.
        if active?.id != shownTab || active?.focusedLeafId != shownFocus || diffShown != shownDiff {
            shownTab = active?.id
            shownFocus = active?.focusedLeafId
            shownDiff = diffShown
            if diffShown {
                window?.makeFirstResponder(diffHost)  // typed keys must not reach the hidden terminal
            } else if let tab = active, let leaf = leafViews[tab.focusedLeafId] {
                window?.makeFirstResponder(leaf.surface)
            }
        }
    }

    /// Keyboard focus into the surface of `leafId` (tab leaf or the TERMINAL panel's shell).
    func focus(leafId: UUID) {
        if let leaf = leafViews[leafId] { window?.makeFirstResponder(leaf.surface) }
        else if app.selectedTask?.drawer.leaf?.id == leafId { window?.makeFirstResponder(drawer.currentSurface) }
    }

    /// Back to the focused terminal (after inline rename left nothing focused).
    func focusActiveLeaf() {
        if app.activeDiff != nil, let diffHost { window?.makeFirstResponder(diffHost); return }
        if let tab = activeTab, let leaf = leafViews[tab.focusedLeafId] { window?.makeFirstResponder(leaf.surface) }
    }

    private func show(_ tab: Tab) {
        if tabViews[tab.id] == nil {
            let view = NSView(frame: content.bounds)
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
            tabViews[tab.id] = view
        }
        // Lazy: surfaces of a tab start the first time it is shown.
        for leaf in tab.root.leaves where leafViews[leaf.id] == nil {
            let view = LeafView(leafId: leaf.id)
            app.wireHost(view)
            leafViews[leaf.id] = view
            tabViews[tab.id]?.addSubview(view)  // in the window before the surface exists
            view.onTitle = { [weak self] title in
                self?.app.setTitle(title, leafId: leaf.id)
                self?.leafViews[leaf.id]?.setHeader(title)
            }
            view.onExit = { [weak self] code in
                self?.app.signal(.exited(code: code), leaf: leaf.id)
                self?.leafExited(leaf.id, code: code)
            }
            view.onFocus = { [weak self] in
                self?.app.focused(leafId: leaf.id)
                self?.app.signal(.focused, leaf: leaf.id)
            }
            view.onBell = { [weak self] in self?.app.signal(.bell, leaf: leaf.id) }
            view.onNotification = { [weak self] in self?.app.signal(.desktopNotification, leaf: leaf.id) }
            view.onRelaunch = { [weak self] keepsStatus in
                if !keepsStatus { self?.app.signal(.relaunched, leaf: leaf.id) }
                self?.lastVisible[leaf.id] = nil  // the new surface needs its visibility applied
                self?.sync()
            }
            view.start(app.launchContext(for: leaf.id)) { [app] in try app.spec(for: leaf, tabId: tab.id, context: $0) }
            uiLog.info("surface created leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public) tab=\(tab.id.uuidString.prefix(8), privacy: .public)")
        }
        if structure[tab.id] != signature(tab.root) { layoutTab(tab) }
    }

    /// CLI/MCP (decision #45): starts the tab's surfaces without showing it; visibility and focus stay as they are.
    func startHidden(tabId: UUID) {
        guard let tab = app.state.tasks.filter({ !$0.archived }).flatMap(\.tabs).first(where: { $0.id == tabId }) else { return }
        show(tab)
        sync()
    }

    /// A tab leaf or a task's drawer shell (CLI/MCP refs, decision #45).
    private func controlLeaf(_ leafId: UUID) -> LeafView? {
        leafViews[leafId] ?? drawer.leaves.first { $0.leafId == leafId }
    }

    private func leafExited(_ leafId: UUID, code: Int32) {
        uiLog.info("leaf exited leaf=\(leafId.uuidString.prefix(8), privacy: .public) code=\(code)")
        if code == 0 { app.closeLeaf(leafId) }
    }

    /// Rebuilds the split tree, reparenting existing leaf views. The new tree is attached to the window
    /// before leaves move into it, so surfaces never leave the window.
    private func layoutTab(_ tab: Tab) {
        guard let container = tabViews[tab.id] else { return }
        let old = container.subviews
        let root = build(tab.root, path: [], tabId: tab.id, into: container)
        // Old split views are empty now (live leaves moved into the new tree, closed ones were removed).
        for view in old where view.superview === container && view !== root { view.removeFromSuperview() }
        let isSplit: Bool
        if case .split = tab.root { isSplit = true } else { isSplit = false }
        for leaf in tab.root.leaves { leafViews[leaf.id]?.showsHeader = isSplit }
        structure[tab.id] = signature(tab.root)
    }

    @discardableResult
    private func build(_ node: SplitNode, path: [Int], tabId: UUID, into parent: NSView) -> NSView? {
        switch node {
        case .leaf(let leaf):
            guard let view = leafViews[leaf.id] else { return nil }
            parent.addSubview(view)  // moves it without leaving the window
            view.frame = parent.bounds
            view.autoresizingMask = parent is RatioSplitView ? [] : [.width, .height]
            return view
        case .split(let axis, let ratio, let first, let second):
            let split = RatioSplitView(axis: axis, ratio: ratio)
            split.frame = parent.bounds
            if parent is RatioSplitView { split.autoresizingMask = [] }
            parent.addSubview(split)
            split.onDragEnd = { [weak self, weak split] in
                guard let self, let split, let r = split.measuredRatio,
                      let loc = self.app.location(ofTab: tabId) else { return }
                split.ratio = r
                self.app.perform { $0.setRatio(taskId: loc, tabId: tabId, path: path, ratio: r) }
            }
            build(first, path: path + [0], tabId: tabId, into: split)
            build(second, path: path + [1], tabId: tabId, into: split)
            split.adjustSubviews()
            return split
        }
    }

    /// Structure without ratios: ratio changes come from drags and must not rebuild.
    private func signature(_ node: SplitNode) -> String {
        switch node {
        case .leaf(let leaf): leaf.id.uuidString
        case .split(let axis, _, let a, let b): "(\(axis.rawValue) \(signature(a)) \(signature(b)))"
        }
    }

    /// Decision #44: a running Helix gets Esc + `:open` (+ `:goto`); a stopped editor leaf is pointed at the file
    /// and (re)started; otherwise a new editor tab opens the file.
    func openInEditor(path: String, line: Int?) {
        guard let task = app.selectedTask else { return }
        let commands = helixCommands(path: path, line: line)
        let route = editorRoute(task: task, isHelix: isHelix(app.config.editor), quotable: commands != nil) { id in
            guard let view = self.leafViews[id], view.surface != nil, !view.needsRelaunch else { return .stopped }
            return view.hasOutput ? .running : .starting
        }
        uiLog.info("openInEditor route=\(String(describing: route), privacy: .public)")
        switch route {
        case .newTab:
            app.perform { $0.addTab(taskId: task.id, kind: .editor, openFile: path, openLine: line) }
        case .launch(let tab, let leaf):
            app.perform { $0.setOpenFile(leafId: leaf, path: path, line: line) }
            app.activate(tabId: tab)  // a never-shown leaf starts with the new file
            // Exited → relaunch; still starting (Helix may not read keys yet) → restart on the new file.
            if let view = leafViews[leaf] { view.needsRelaunch ? view.relaunch() : view.restart() }
        case .sendKeys(let tab, let leaf):
            app.perform {
                $0.setOpenFile(leafId: leaf, path: path, line: line)
                $0.setFocusedLeaf(taskId: task.id, tabId: tab, leafId: leaf)
            }
            app.activate(tabId: tab)
            guard let surface = leafViews[leaf]?.surface, let commands else { return }
            window?.makeFirstResponder(surface)
            surface.sendKey(.escape)
            // In one terminal read `Esc :` is Alt-: without the kitty protocol: the rest goes in a later read.
            // Through tmux on a server, `escape-time` (up to 500 ms) would still merge them (#47).
            let pause = app.remoteLeafHost(leaf) == nil ? 0.05 : 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak surface] in
                guard let surface else { return }
                for command in commands {
                    surface.sendKey(.colon)
                    surface.sendText(command)  // bracketed paste into the `:` prompt
                    surface.sendEnter()
                }
            }
        }
    }

    /// ↩ on an exited leaf relaunches it. Returns true if handled.
    func relaunchFocusedIfExited() -> Bool {
        guard let leaf = focusedLeaf, leaf.needsRelaunch || leaf.canReconnect else { return false }
        leaf.activateBar()
        return true
    }

    #if DEBUG
    /// Focuses the n-th leaf of the active tab like a click would (first responder).
    func debugFocus(_ n: Int) {
        guard let tab = activeTab, tab.root.leaves.indices.contains(n) else { return }
        window?.makeFirstResponder(leafViews[tab.root.leaves[n].id]?.surface)
    }

    /// Debug summary of every surface and whether it renders.
    func debugDump() -> String {
        let drawers = drawer.debugDump()
        return leafViews.map { id, view in
            "leaf=\(id.uuidString.prefix(8)) surface=\(view.surface != nil) hidden=\(view.surface?.isHidden ?? true) inWindow=\(view.window != nil) exit=\(view.exitCode.map(String.init) ?? "-") failed=\(view.failed)"
        }.sorted().joined(separator: "\n") + (drawers.isEmpty ? "" : "\n" + drawers)
    }
    #endif
}

/// A host connected (`remote.onConnected`): its leaves waiting for it launch, detached ones reattach.
@MainActor func hostConnected(host: String, leaves: [LeafView]) {
    for view in leaves where view.host == host {
        if view.isDetached { view.relaunch(focus: false) } else { view.resumeIfWaiting() }
    }
}
