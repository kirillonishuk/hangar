import AgentStatus
import AppKit
import Exec
import GhosttyBridge
import Workspace

/// Background of a clickable AppKit bar (TERMINAL, ↩ relaunch): `lit` while the pointer is over it, 120 ms fade.
@MainActor final class HoverFill: NSView {
    /// Read on each hover, so it follows the theme.
    private let lit: () -> NSColor
    private var inside = false
    /// Off: stays clear (the bar is not clickable right now).
    var enabled = true { didSet { if enabled != oldValue { apply(animated: false) } } }

    init(lit: @escaping () -> NSColor) {
        self.lit = lit
        super.init(frame: .zero)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks belong to the bar
    override func mouseEntered(with event: NSEvent) { inside = true; apply(animated: true) }
    override func mouseExited(with event: NSEvent) { inside = false; apply(animated: true) }

    private func apply(animated: Bool) {
        guard let layer else { return }
        let color = (inside && enabled ? lit() : .clear).cgColor
        if animated, !Motion.reduced {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color
            fade.duration = Theme.hoverFade
            layer.add(fade, forKey: "hover")
        }
        layer.backgroundColor = color
    }
}

/// The drawer's top bar: terminal icon, "TERMINAL", chevron. The whole bar is clickable.
@MainActor final class DrawerBarView: NSView {
    private let fill = HoverFill { Theme.hover2 }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = Icon.shell.image
        label.font = .systemFont(ofSize: Theme.fontSize.counter, weight: .semibold)
        [fill, icon, label, chevron].forEach(addSubview)
        setAccessibilityRole(.button)
        applyTheme()
        observeTheme(#selector(applyTheme))
    }

    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.bg1.cgColor
        icon.contentTintColor = Theme.text2
        label.textColor = Theme.text2
        chevron.contentTintColor = Theme.text3
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(expanded: Bool) {
        label.stringValue = L10n.drawerTitle
        chevron.image = (expanded ? Icon.chevronDown : Icon.chevronUp).image(size: Theme.smallIconSize)
        toolTip = L10n.help(L10n.drawerHelp, .toggleDrawer)
        setAccessibilityLabel(L10n.drawerTitle)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let px = Theme.paneHeaderPaddingH
        let icon = Theme.iconSize
        self.icon.frame = NSRect(x: px, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let th = ceil(label.intrinsicContentSize.height)
        let lx = px + icon + Theme.iconGap
        label.frame = NSRect(x: lx, y: (bounds.height - th) / 2, width: max(0, bounds.width - lx - 2 * px - Theme.smallIconSize), height: th)
        let c = Theme.smallIconSize
        chevron.frame = NSRect(x: bounds.width - px - c, y: (bounds.height - c) / 2, width: c, height: c)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Grab strip on the drawer's top edge: drag to resize (the divider keeps the resize cursor).
@MainActor final class DrawerResizeHandle: NSView {
    var currentHeight: () -> CGFloat = { 0 }
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: (y: CGFloat, height: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDown(with event: NSEvent) { start = (event.locationInWindow.y, currentHeight()) }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(start.height + (event.locationInWindow.y - start.y))  // window y grows upward: dragging up grows the panel
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onEnd?()
    }
}

/// Bottom terminal of the selected task. Each task's shell is a `LeafView` (kind .shell) created on first show
/// and kept while hidden; hidden → rendering paused (`setVisible(false)`).
@MainActor final class TerminalDrawer: NSView {
    private let app: AppState
    private let bar = DrawerBarView()
    private let topLine = NSView()
    private let handle = DrawerResizeHandle()
    private var leafViews: [UUID: LeafView] = [:]  // task id → shell
    private var lastVisible: [UUID: Bool] = [:]    // leaf id → applied setVisible
    /// Height while dragging (committed to the model on mouse up).
    private var dragHeight: CGFloat?
    /// Called when the layout of the area around the drawer must change (drag).
    var onResize: (() -> Void)?

    override var isFlipped: Bool { true }

    init(app: AppState) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        topLine.wantsLayer = true
        applyTheme()
        observeTheme(#selector(applyTheme))
        [bar, topLine, handle].forEach(addSubview)
        bar.onClick = { [weak self] in self?.onToggle?() }
        handle.currentHeight = { [weak self] in self?.panelHeight ?? 0 }
        handle.onDrag = { [weak self] h in self?.dragHeight = h; self?.onResize?() }
        handle.onEnd = { [weak self] in self?.commitDrag() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.bg0.cgColor
        topLine.layer?.backgroundColor = Theme.line.cgColor
    }

    /// Set by the area: toggles the selected task's drawer (focus handling lives there).
    var onToggle: (() -> Void)?
    /// Called after the focused shell exited (code 0) and the drawer collapsed.
    var onReturnFocus: (() -> Void)?

    private var task: HangarTask? { app.selectedTask }
    private var available: CGFloat = 0

    /// Visible terminal height: model height clamped to 120…70% of the area.
    private var panelHeight: CGFloat {
        let wanted = dragHeight ?? CGFloat(task?.drawer.height ?? Drawer.minHeight)
        return Self.clamp(wanted, available: available)
    }

    static func clamp(_ height: CGFloat, available: CGFloat) -> CGFloat {
        min(max(height, CGFloat(Drawer.minHeight)), max(CGFloat(Drawer.minHeight), available * Theme.drawerMaxFraction))
    }

    /// Bar plus (when expanded) the terminal; 0 without a selected task.
    func totalHeight(available: CGFloat) -> CGFloat {
        self.available = available
        guard let task else { return 0 }
        return min(available, Theme.drawerBarHeight + (task.drawer.visible ? panelHeight : 0))
    }

    private func commitDrag() {
        guard let id = task?.id, let h = dragHeight else { return }
        let clamped = Self.clamp(h, available: available)
        dragHeight = nil
        app.perform { $0.setDrawerHeight(taskId: id, Double(clamped)) }
    }

    /// Focus target of the selected task's shell: its surface, or the leaf itself while it has none
    /// (folder missing, host down), so ⌘W still sees the drawer focused and never closes the tab.
    var currentSurface: NSView? { task.flatMap { leafViews[$0.id] }.map { $0.surface ?? $0 } }

    /// Leaf view holding keyboard focus (for ↩ relaunch and the focus return).
    var focusedLeaf: LeafView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return leafViews.values.first { responder.isDescendant(of: $0) }
    }

    /// Reconciles views with the model after each mutation.
    func sync() {
        let tasks = app.state.tasks.filter { !$0.archived }
        let live = Dictionary(uniqueKeysWithValues: tasks.compactMap { t in t.drawer.leaf.map { (t.id, $0) } })
        for (taskId, view) in leafViews where live[taskId]?.id != view.leafId {
            view.removeFromSuperview()
            leafViews[taskId] = nil
            lastVisible[view.leafId] = nil
            uiLog.info("surface closed leaf=\(view.leafId.uuidString.prefix(8), privacy: .public) kind=shell drawer")
        }
        let selected = task
        // The surface is created the first time the drawer is expanded (not at launch for a persisted one).
        if let selected, selected.drawer.visible, let leaf = selected.drawer.leaf, leafViews[selected.id] == nil {
            makeLeafView(taskId: selected.id, leaf: leaf)
        }
        for (taskId, view) in leafViews {
            let shown = taskId == selected?.id && selected?.drawer.visible == true
            view.isHidden = !shown
            if lastVisible[view.leafId] != shown, let surface = view.surface {
                lastVisible[view.leafId] = shown
                surface.setVisible(shown)
                uiLog.info("setVisible(\(shown)) leaf=\(view.leafId.uuidString.prefix(8), privacy: .public) kind=shell drawer")
            }
            view.refreshText()
        }
        bar.isHidden = selected == nil
        topLine.isHidden = selected == nil
        handle.isHidden = selected?.drawer.visible != true
        bar.update(expanded: selected?.drawer.visible == true)
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    /// CLI/MCP on a drawer shell not shown since launch: start it hidden (rendering paused), like a tab's leaves.
    func startHidden(leafId: UUID) {
        guard let task = app.state.tasks.first(where: { !$0.archived && $0.drawer.leaf?.id == leafId }),
              let leaf = task.drawer.leaf, leafViews[task.id] == nil else { return }
        makeLeafView(taskId: task.id, leaf: leaf)
        sync()
    }

    private func makeLeafView(taskId: UUID, leaf: Leaf) {
        let view = LeafView(leafId: leaf.id)
        app.wireHost(view)
        leafViews[taskId] = view
        addSubview(view, positioned: .below, relativeTo: bar)  // in the window before the surface exists
        view.onExit = { [weak self] code in
            self?.app.signal(.exited(code: code), leaf: leaf.id)
            guard code == 0 else { return }  // a failure keeps the panel with the ↩ bar
            guard let self else { return }
            uiLog.info("leaf exited leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) code=0 drawer")
            let hadFocus = self.focusedLeaf?.leafId == leaf.id
            self.app.perform { $0.closeDrawerLeaf(taskId: taskId) }
            if hadFocus { self.onReturnFocus?() }  // the shell is gone: focus goes back to the tab
        }
        view.onFocus = { [weak self] in
            self?.app.focused(leafId: leaf.id)  // withdraws the leaf's banner; the drawer has no tab focus to move
            self?.app.signal(.focused, leaf: leaf.id)
        }
        view.onBell = { [weak self] in self?.app.signal(.bell, leaf: leaf.id) }
        view.onNotification = { [weak self] in self?.app.signal(.desktopNotification(text: $0), leaf: leaf.id) }
        view.onRelaunch = { [weak self] keepsStatus in
            if !keepsStatus { self?.app.signal(.relaunched, leaf: leaf.id) }
            self?.lastVisible[leaf.id] = nil  // the new surface needs its visibility applied
            self?.sync()
        }
        // HANGAR_TAB_ID = the drawer leaf's own stable id
        view.start(app.launchContext(for: leaf.id)) { [app] in try app.spec(for: leaf, tabId: leaf.id, context: $0) }
        uiLog.info("surface created leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=shell drawer task=\(taskId.uuidString.prefix(8), privacy: .public)")
    }

    override func layout() {
        super.layout()
        let barH = Theme.drawerBarHeight
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        topLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        handle.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Theme.drawerGrabHeight)
        // Collapsed: a shell started hidden by CLI/MCP keeps the panel's size, not 0 rows.
        let body = NSRect(x: 0, y: barH, width: bounds.width, height: bounds.height > barH ? bounds.height - barH : panelHeight)
        for view in leafViews.values { view.frame = body }
        window?.invalidateCursorRects(for: self)
    }

    /// For `hostConnected`.
    var leaves: [LeafView] { Array(leafViews.values) }

    /// Display wake: one retry for shells whose surface failed (same as tab leaves).
    func retryFailedLeaves() {
        for leaf in leafViews.values where leaf.failed { leaf.relaunch(focus: false) }
    }

    #if DEBUG
    func debugDump() -> String {
        leafViews.map { id, v in
            "drawer task=\(id.uuidString.prefix(8)) leaf=\(v.leafId.uuidString.prefix(8)) surface=\(v.surface != nil) hidden=\(v.isHidden) exit=\(v.exitCode.map(String.init) ?? "-")"
        }.sorted().joined(separator: "\n")
    }
    #endif
}
