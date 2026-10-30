import AgentStatus
import AppKit
import ControlServer
import Exec
import GhosttyBridge
#if DEBUG
import WebKit  // debugWebViews only
#endif
import Workspace

/// NSSplitView with the theme divider and a hook when the user finishes dragging a divider.
class HangarSplitView: NSSplitView {
    var onDragEnd: (() -> Void)?
    /// Index of the divider under the last mouse-down (nil: none); read in `onDragEnd`.
    private(set) var draggedDivider: Int?
    /// True inside the divider tracking loop (mouse down → up).
    private(set) var isTracking = false

    override var dividerColor: NSColor { Theme.line }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        draggedDivider = (0..<max(0, arrangedSubviews.count - 1)).first { dividerHitRect($0).contains(p) }
        isTracking = true
        super.mouseDown(with: event)  // runs the divider tracking loop until mouse up
        isTracking = false
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

    // NSSplitView's own layout pass resizes panes by its holding priorities (a restored 0.39 split came out 0 / all,
    // a nested split showed one pane): the ratio is re-applied after it, except while a divider drag is tracking.
    override func layout() {
        super.layout()
        if !isTracking { applyRatio() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { return super.resizeSubviews(withOldSize: oldSize) }
        applyRatio()
    }

    private func applyRatio() {
        guard subviews.count == 2 else { return }
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

/// Moves a pane into `parent` (a split, or the tab itself) without it leaving the window. NSSplitView arranges its
/// panes with Auto Layout (`translatesAutoresizingMaskIntoConstraints = false`); a pane that leaves a split (the other
/// pane closed) must get autoresizing back, else the next layout pass sizes it 0×0 and the tab looks closed.
@MainActor func placeLeaf(_ view: NSView, in parent: NSView) {
    parent.addSubview(view)
    let inSplit = parent is RatioSplitView
    if !inSplit { view.translatesAutoresizingMaskIntoConstraints = true }
    view.frame = parent.bounds
    view.autoresizingMask = inSplit ? [] : [.width, .height]
}

/// Keeps every subview at its bounds: autoresizing through interrupted drawer animations (fast task switches)
/// drifted a tab's split off its tab (a pane squeezed to the bottom, or taller than the area).
final class FillView: NSView {
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}

/// One split pane: optional header (when the tab is split), the terminal surface, and an exit/error bar.
@MainActor final class LeafView: NSView {
    let leafId: UUID
    /// Not the editor: ⌘V with an image-only clipboard sends ⌃V (#70).
    var kind: LeafKind = .shell
    private(set) var surface: TerminalSurfaceView?
    /// An editor leaf holds Monaco instead of a terminal (#80).
    private(set) var editor: EditorPane?
    /// What takes the keyboard in this leaf; a chooser takes it itself.
    var keyView: NSView? { surface ?? editor?.webView ?? (chooser != nil ? self : nil) }
    /// Builds the spec of one launch; each relaunch asks again with `.relaunch(previous:exitCode:)`.
    private var make: ((LaunchContext) throws -> (LaunchSpec, LaunchMode))?
    private var mode: LaunchMode?
    /// Holds the `PaneHeader` once the leaf is in a split (`installHeader`); always present, content goes below it.
    private let header = FillView()
    private let headerLine = NSView()
    private let bar = NSTextField(labelWithString: "")
    private let barLine = NSView()
    private let barFill = HoverFill { Theme.hover }
    /// Non-nil while the process has exited with a failure (↩ relaunches).
    private(set) var exitCode: Int32?
    /// Ghostty could not create the surface (e.g. no display); ↩ or a display wake retries.
    private(set) var failed = false
    /// The launch that met a missing folder: ↩ (or opening a file in the editor) tries it again as it was.
    private var missingFolder: LaunchContext?
    var needsRelaunch: Bool { exitCode != nil || failed || missingFolder != nil }
    /// A new surface replaced the old one; `keepsStatus`: the same agent goes on (reattach, a launch that never ran).
    var onRelaunch: ((_ keepsStatus: Bool) -> Void)?
    /// ssh host of a remote project's leaf (nil = local): its 255 means the tmux session did not end (#47).
    var host: String?
    /// The client of a remote session exited with 255 (connection lost, detach); ↩ or the reconnect reattaches.
    private(set) var isDetached = false
    /// The launch that met `.notConnected`, made again by `resumeIfWaiting` once the host is up.
    private var waiting: LaunchContext?
    var isWaitingForHost: Bool { waiting != nil && !waitingForConsent }
    /// The launch waits for the integration sheet's answer (#111), made again by `integrationAnswered`.
    private(set) var waitingForConsent = false
    /// Set with `host`: the bar text when the host is not on its way (given up, disconnected, retry paused) — then the
    /// waiting bar offers «Переподключиться»; nil while it is connecting.
    var reconnectText: () -> String? = { nil }
    var onReconnect: (() -> Void)?
    var canReconnect: Bool { waiting != nil && !waitingForConsent && reconnectText() != nil }
    var showsHeader = false { didSet { needsLayout = true; header.isHidden = !showsHeader; headerLine.isHidden = !showsHeader } }
    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?
    var onFocus: (() -> Void)?
    /// Terminal bell / OSC 9·777 notification: the status fallback for agents without hooks.
    var onBell: (() -> Void)?
    /// The OSC text, «title — body» (nil when both are empty).
    var onNotification: ((String?) -> Void)?
    /// A chooser leaf holds its `ChooserView` (no process) until a kind is picked.
    private(set) var chooser: NSView?
    /// Chooser keys: ↩ picks the terminal, Esc closes the pane.
    var onChoose: ((LeafKind) -> Void)?
    var onDismiss: (() -> Void)?

    init(leafId: UUID) {
        self.leafId = leafId
        super.init(frame: .zero)
        wantsLayer = true
        bar.font = Theme.Typography.caption.nsFont()
        bar.lineBreakMode = .byTruncatingTail
        for line in [headerLine, barLine] { line.wantsLayer = true }
        applyTheme()
        observeTheme(#selector(applyTheme))
        [header, headerLine, barFill, bar, barLine].forEach(addSubview)
        header.isHidden = true
        headerLine.isHidden = true
        setBar(nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    /// Times the view left the window; a live leaf must never (its surface would blank and reset). Closed views are dropped.
    private(set) var windowLosses = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { windowLosses += 1 }
    }

    #endif

    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.panel.cgColor
        bar.textColor = Theme.text2
        for line in [headerLine, barLine] { line.layer?.backgroundColor = Theme.line.cgColor }
    }

    /// The header's content, made once (the first time the leaf is in a split; it reads its leaf by id).
    func installHeader(_ make: () -> NSView) {
        guard header.subviews.isEmpty else { return }
        let view = make()
        view.frame = header.bounds
        header.addSubview(view)
    }

    /// Without a surface the leaf holds the keyboard itself (⌘W / ↩ route to it), also after a click on it.
    override var acceptsFirstResponder: Bool { surface == nil && editor == nil }

    func attachChooser(_ view: NSView) {
        chooser = view
        addSubview(view, positioned: .below, relativeTo: header)
        needsLayout = true
    }

    /// A kind was picked: the chooser goes, the content starts in the same view.
    func removeChooser() {
        chooser?.removeFromSuperview()
        chooser = nil
        onChoose = nil
        onDismiss = nil
    }

    override func keyDown(with event: NSEvent) {
        guard chooser != nil, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 36, 76: onChoose?(.shell)  // ↩, keypad Enter
        case 53: onDismiss?()  // Esc
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        if chooser != nil { onFocus?() }
        return true
    }

    func attachEditor(_ pane: EditorPane) {
        editor = pane
        addSubview(pane, positioned: .below, relativeTo: header)
        needsLayout = true
    }

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
            waitingForConsent = false
            missingFolder = nil
            let (spec, mode) = try make(context)
            self.mode = mode
            setBar(nil)
            launch(spec)
            return true
        } catch LaunchError.missingCwd(let path) {
            missingFolder = context
            setBar("\(L10n.folderMissing(path)) · \(L10n.relaunchHint)")
        } catch LaunchError.awaitingConsent {
            waiting = context
            waitingForConsent = true
            barText = { L10n.awaitingIntegrationAnswer }
            refreshText()
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
        view.onDesktopNotification = { [weak self] title, body in self?.onNotification?(oscNotificationText(title: title, body: body)) }
        view.onPaste = { [weak self, weak view] in
            guard let self, let view, pasteAction(kind: self.kind) == .ctrlV else { return false }
            view.sendKey(.ctrlV)
            return true
        }
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
        guard needsRelaunch else { return }
        let context: LaunchContext
        if let missingFolder {
            context = missingFolder
        } else {
            guard let mode else { return }
            context = isDetached ? .reattach(previous: mode) : .relaunch(previous: mode, exitCode: failed ? nil : exitCode)
        }
        // Only a relaunch after a run resets the status; a reattach or a launch that never ran keeps it.
        let keepsStatus: Bool = if case .relaunch = context { false } else { true }
        exitCode = nil
        failed = false
        isDetached = false
        guard run(context) else {
            // No new process (missing folder): drop the dead surface so CLI/MCP never paste into it (`failed`).
            surface?.onChildExit = nil
            surface?.removeFromSuperview()
            surface = nil
            return
        }
        uiLog.info("relaunch leaf=\(self.leafId.uuidString.prefix(8), privacy: .public) ok=\(!self.failed)")
        if focus, !failed { window?.makeFirstResponder(surface) }
        onRelaunch?(keepsStatus)
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
            case .interrupt: surface.sendKey(.escape)  // resolved per leaf kind by `AppState.respond`
            }
        }
    }

    /// The process has drawn something since launch; before that a starting agent may not read keys yet.
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
        barFill.isHidden = text == nil
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
        } else if surface == nil {
            window?.makeFirstResponder(self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let px = Theme.paneHeaderPaddingH
        var top: CGFloat = 0
        if showsHeader {
            let h = Theme.paneHeaderHeight
            header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h - 1)
            headerLine.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
            top = h
        }
        var bottom = bounds.height
        if !bar.isHidden {
            let h = Theme.statusBarHeight
            bottom -= h
            barLine.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: 1)
            barFill.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: h)
            barFill.enabled = needsRelaunch || canReconnect
            let th = ceil(bar.intrinsicContentSize.height)
            bar.frame = NSRect(x: px, y: bottom + (h - th) / 2, width: max(0, bounds.width - 2 * px), height: th)
        }
        (surface ?? editor ?? chooser)?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        window?.invalidateCursorRects(for: self)
    }
}

/// All terminal content. Tabs get a view on first show and keep it (and its surfaces) until closed;
/// switching only toggles visibility, so surfaces never leave the window (decision for pending clipboard prompts).
@MainActor final class TerminalArea: NSView {
    private let app: AppState
    private(set) var tabViews: [UUID: NSView] = [:]
    private var structure: [UUID: String] = [:]
    private(set) var leafViews: [UUID: LeafView] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    private var shownTab: UUID?
    private var shownFocus: UUID?
    /// Each task's diff tab, with its Monaco page, while that diff tab exists (an edited buffer survives task switches).
    private var diffHosts: [UUID: (host: DiffHostView, editor: DiffEditorController)] = [:]
    /// The Monaco pages of the file tabs (#83, ≤ 2 for a split); made with the first file tab, gone with the last.
    private var editorHost: EditorHost?
    /// The selected task's diff editor (F7 / ⇧F7, debug commands).
    var shownDiffEditor: DiffEditorController? { app.selectedTask.flatMap { diffHosts[$0.id]?.editor } }
    /// The selected task's diff tab view.
    private var diffHost: DiffHostView? { app.selectedTask.flatMap { diffHosts[$0.id]?.host } }
    private var shownDiff = false
    private let placeholder = NSTextField(labelWithString: "")
    /// Tab content above the drawer.
    private let content = FillView()
    let drawer: TerminalDrawer
    private var appliedDrawerHeight: CGFloat = 0
    /// No projects yet: "+ Добавить проект" button and the ⌘⇧N hint.
    private var emptyState = NSView()
    /// The selected session has no tabs: «Нет вкладок» and buttons for new ones (#99).
    private var noTabs = NSView()
    var onAddProject: () -> Void = {}
    /// The drop zone while a tab is dragged over a pane (`PaneDragController`); above the tab content.
    let dropOverlay = PaneDropOverlay()
    /// Pane headers' actions (confirmations are the window's); set by the window controller.
    var actionContext: ActionContext

    init(app: AppState) {
        self.app = app
        drawer = TerminalDrawer(app: app)
        actionContext = ActionContext(app: app)
        super.init(frame: .zero)
        content.autoresizingMask = []
        addSubview(content)
        addSubview(drawer)
        drawer.onToggle = { [weak self] in if let id = self?.app.selectedTask?.id { self?.toggleDrawer(taskId: id) } }
        drawer.onReturnFocus = { [weak self] in self?.focusActiveLeaf() }
        app.onOpenInEditor = { [weak self] leaf, path, line, column in
            guard let pane = self?.leafViews[leaf]?.editor else { return }  // a never-shown tab loads its file from the model
            pane.open(path: path, line: line, column: column)
            pane.focusEditor()
        }
        app.editorUnsaved = { [weak self] id in self?.leafViews[id]?.editor?.unsaved ?? [] }
        app.onEditorAppearance = { [weak self] look in
            self?.editorHost?.setAppearance(look)
            self?.diffHosts.values.forEach { $0.editor.page.send(.appearance(look)) }
        }
        app.diffUnsaved = { [weak self] in self?.diffHosts.values.filter(\.editor.hasUnsaved).count ?? 0 }
        app.confirmLeaveDiff = { [weak self] then in
            if let id = self?.app.selectedTask?.id, let editor = self?.diffHosts[id]?.editor { editor.confirmLeave(then) } else { then() }
        }
        app.onHostConnected = { [weak self] host in
            guard let self else { return }
            hostConnected(host: host, leaves: Array(leafViews.values) + drawer.leaves)
        }
        app.onIntegrationAnswered = { [weak self] in
            guard let self else { return }
            for view in Array(leafViews.values) + drawer.leaves where view.waitingForConsent { view.resumeIfWaiting() }
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
        noTabs = NoTabsView.hosted(app: app)
        wantsLayer = true
        observeTheme(#selector(applyTheme))
        applyTheme()
        placeholder.font = Theme.Typography.body.nsFont()
        placeholder.alignment = .center
        addSubview(placeholder)
        addSubview(emptyState)
        addSubview(noTabs)
        addSubview(dropOverlay)
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

    /// Also redraws the split dividers (`HangarSplitView.dividerColor`) of every tab.
    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.panel.cgColor
        placeholder.textColor = Theme.text3
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        redraw(self)
        tabViews.values.forEach(redraw)
    }

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
                noTabs.animator().frame = contentFrame
            }
        } else {
            drawer.frame = drawerFrame
            content.frame = contentFrame
            noTabs.frame = contentFrame
        }
        appliedDrawerHeight = total
    }

    /// ⌘J (⌃`) and the bar: expand (focus goes into the shell) or collapse (focus returns to the tab if it was in the shell).
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

    /// The active tab's panes in window points from the top-left; none while the diff tab or «Сессии» covers them (R3).
    func paneFrames() -> [UUID: CGRect] {
        guard !isHidden, !app.sessionsViewVisible, app.activeDiff == nil, let tab = activeTab else { return [:] }
        var frames: [UUID: CGRect] = [:]
        for leaf in tab.root.leaves {
            if let view = leafViews[leaf.id], !view.isHiddenOrHasHiddenAncestor, let r = windowRect(view) { frames[leaf.id] = r }
        }
        return frames
    }

    /// `pane`: from `paneFrames()`.
    func showDropZone(_ pane: CGRect, edge: SplitEdge) {
        guard let height = window?.contentView?.frame.height else { return }
        let r = convert(NSRect(x: pane.minX, y: height - pane.maxY, width: pane.width, height: pane.height), from: nil)
        dropOverlay.show(over: r, edge: edge)
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

        // Closed tabs/leaves and archived tasks: these are real closes, the surfaces go away. A live leaf of a gone tab
        // (merged, moved, detached) is parked in `content` first, so it never leaves the window.
        for (id, view) in tabViews where !liveTabIds.contains(id) {
            park(leavesIn: view, live: liveLeafIds)
            view.removeFromSuperview()
            tabViews[id] = nil
            structure[id] = nil
        }
        for (id, leaf) in leafViews where !liveLeafIds.contains(id) {
            leaf.editor?.tearDown()
            leaf.removeFromSuperview()
            leafViews[id] = nil
            if let host = editorHost, host.isEmpty { host.tearDown(); editorHost = nil }  // the last file tab: no web view
            lastVisible[id] = nil
            app.leafTitles[id] = nil
            uiLog.info("surface closed leaf=\(id.uuidString.prefix(8), privacy: .public)")
        }

        let liveTasks = Set(state.tasks.filter { !$0.archived }.map(\.id))
        for (id, d) in diffHosts where app.diffTabs[id] == nil || !liveTasks.contains(id) {
            d.editor.tearDown()
            d.host.removeFromSuperview()
            diffHosts[id] = nil
        }
        let diffShown = app.activeDiff != nil
        if diffShown, let id = app.selectedTask?.id, diffHosts[id] == nil {
            let editor = DiffEditorController(app: app)
            let host = DiffHostView(rootView: DiffView(app: app, taskId: id, editor: editor))
            host.frame = content.bounds
            host.autoresizingMask = [.width, .height]
            content.addSubview(host)
            diffHosts[id] = (host, editor)
        }
        editorHost?.setMinimap(state.editorMinimap)
        for (id, d) in diffHosts { d.host.isHidden = !diffShown || id != app.selectedTask?.id }
        let active = activeTab
        if let tab = active { show(tab) }
        for tab in liveTabs where tabViews[tab.id] != nil && tab.id != active?.id {
            if structure[tab.id] != signature(tab.root) { layoutTab(tab) }  // e.g. a hidden leaf exited with 0
        }
        for (id, view) in tabViews { view.isHidden = diffShown || id != active?.id }
        // The active tab's editor panes on screen each get their own Monaco page; a moved model follows (`rehome`).
        let shownPanes = diffShown ? [] : (active?.root.leaves ?? []).compactMap { leafViews[$0.id]?.editor }
        let pages = assignPages(visible: shownPanes.map { ($0.leafId, $0.page) }, count: Tab.maxEditorPanes)
        for tab in liveTabs {
            for leaf in tab.root.leaves {
                if let view = leafViews[leaf.id], view.chooser != nil { continue }
                if let view = leafViews[leaf.id], let pane = view.editor {
                    let page = pages[leaf.id]
                    if let page, page != pane.page { Task { await pane.rehome(to: page) } }
                    pane.setVisible(page != nil, page: page)
                    continue
                }
                guard let view = leafViews[leaf.id], let surface = view.surface else { continue }
                let visible = !diffShown && tab.id == active?.id
                if lastVisible[leaf.id] != visible {
                    lastVisible[leaf.id] = visible
                    surface.setVisible(visible)
                    uiLog.info("setVisible(\(visible)) leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public)")
                }
                view.refreshText()
            }
        }

        // A host's terminal (#64) needs no project.
        let nothing = state.projects.isEmpty && state.hostShells.isEmpty
        emptyState.isHidden = !nothing
        placeholder.isHidden = app.selectedTask != nil || diffShown || nothing
        placeholder.stringValue = L10n.emptyNoTask
        noTabs.isHidden = !app.showsNoTabs || diffShown || nothing

        // Focus follows tab switches, new splits and closed leaves; plain re-syncs never steal focus.
        if active?.id != shownTab || active?.focusedLeafId != shownFocus || diffShown != shownDiff {
            shownTab = active?.id
            shownFocus = active?.focusedLeafId
            shownDiff = diffShown
            if diffShown {
                window?.makeFirstResponder(diffHost)  // typed keys must not reach the hidden terminal
            } else if let tab = active, let leaf = leafViews[tab.focusedLeafId] {
                window?.makeFirstResponder(leaf.keyView)
            }
        }
    }

    /// Keyboard focus into the surface of `leafId` (tab leaf or the TERMINAL panel's shell).
    func focus(leafId: UUID) {
        if let leaf = leafViews[leafId] { window?.makeFirstResponder(leaf.keyView) }
        else if app.selectedTask?.drawer.leaf?.id == leafId { window?.makeFirstResponder(drawer.currentSurface) }
    }

    /// Back to the focused terminal (after inline rename left nothing focused).
    func focusActiveLeaf() {
        if app.activeDiff != nil, let diffHost { window?.makeFirstResponder(diffHost); return }
        if let tab = activeTab, let leaf = leafViews[tab.focusedLeafId] { window?.makeFirstResponder(leaf.keyView) }
    }

    private func show(_ tab: Tab) {
        if tabViews[tab.id] == nil {
            let view = FillView(frame: content.bounds)
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
            tabViews[tab.id] = view
        }
        // Lazy: surfaces of a tab start the first time it is shown.
        for leaf in tab.root.leaves {
            if let view = leafViews[leaf.id] {
                // A chooser got its kind: the same view starts it and keeps the keyboard if it had it.
                guard view.chooser != nil, leaf.kind != .choose else { continue }
                view.removeChooser()
                startContent(view, leaf: leaf, tabId: tab.id)
                if tab.focusedLeafId == leaf.id, let key = view.keyView { window?.makeFirstResponder(key) }
                continue
            }
            let view = LeafView(leafId: leaf.id)
            leafViews[leaf.id] = view
            tabViews[tab.id]?.addSubview(view)  // in the window before the surface exists
            startContent(view, leaf: leaf, tabId: tab.id)
        }
        if structure[tab.id] != signature(tab.root) { layoutTab(tab) }
    }

    /// What a leaf view holds: a chooser, an editor pane, or a terminal surface started now.
    func startContent(_ view: LeafView, leaf: Leaf, tabId: UUID) {
        view.kind = leaf.kind
        switch leaf.kind {
        case .choose:
            view.attachChooser(ChooserView.hosted(app: app, leafId: leaf.id) { [weak view] in view?.window?.makeFirstResponder(view) })
            view.onChoose = { [weak self] in self?.app.chooseKind(leaf.id, $0) }
            view.onDismiss = { [weak self] in self?.app.closeLeaf(leaf.id) }
            view.onFocus = { [weak self] in self?.app.focused(leafId: leaf.id) }
            return
        case .editor:
            let host = editorHost ?? EditorHost(minimap: app.state.editorMinimap, appearance: EditorAppearance(app.config))
            editorHost = host
            // Beside an editor already in this tab: the free page, so it never loads on the taken one first.
            let tab = app.state.tasks.lazy.flatMap(\.tabs).first { $0.id == tabId }
            let taken = Set((tab?.root.leaves ?? []).compactMap { self.leafViews[$0.id]?.editor?.page })
            let page = (0..<Tab.maxEditorPanes).first { !taken.contains($0) } ?? 0
            let pane = EditorPane(leafId: leaf.id, app: app, host: host, page: page)
            view.attachEditor(pane)
            uiLog.info("editor created leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) tab=\(tabId.uuidString.prefix(8), privacy: .public)")
            return
        case .claude, .codex, .shell: break
        }
        app.wireHost(view)
        view.onTitle = { [weak self] title in
            guard let self else { return }
            self.app.setTitle(title, leafId: leaf.id)
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
        view.onNotification = { [weak self] in self?.app.signal(.desktopNotification(text: $0), leaf: leaf.id) }
        view.onRelaunch = { [weak self] keepsStatus in
            if !keepsStatus { self?.app.relaunched(leafId: leaf.id) }
            self?.lastVisible[leaf.id] = nil  // the new surface needs its visibility applied
            self?.sync()
        }
        // A relaunch after a merge / move / detach gets the leaf's tab of now as `HANGAR_TAB_ID`.
        view.start(app.launchContext(for: leaf.id)) { [app] in
            try app.spec(for: leaf, tabId: app.location(ofLeaf: leaf.id)?.tab ?? tabId, context: $0)
        }
        uiLog.info("surface created leaf=\(leaf.id.uuidString.prefix(8), privacy: .public) kind=\(leaf.kind.rawValue, privacy: .public) tab=\(tabId.uuidString.prefix(8), privacy: .public)")
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
        // Old split views hold no leaf of this tab now; one moved to a tab not laid out yet is parked, closed ones are gone.
        let live = Set(leafViews.keys)
        for view in old where view.superview === container && view !== root {
            park(leavesIn: view, live: live)
            view.removeFromSuperview()
        }
        let isSplit: Bool
        if case .split = tab.root { isSplit = true } else { isSplit = false }
        for leaf in tab.root.leaves {
            guard let view = leafViews[leaf.id] else { continue }
            if isSplit {
                view.installHeader {
                    PaneHeader.hosted(app: app, ctx: { [weak self, app] in self?.actionContext ?? ActionContext(app: app) }, leafId: leaf.id) {
                        [weak self] in self?.focus(leafId: leaf.id)
                    }
                }
            }
            view.showsHeader = isSplit
        }
        structure[tab.id] = signature(tab.root)
    }

    /// Live leaf views inside `view` move into `content`, hidden, until their new tab's `build` takes them.
    private func park(leavesIn view: NSView, live: Set<UUID>) {
        func leaves(_ v: NSView) -> [LeafView] { (v as? LeafView).map { [$0] } ?? v.subviews.flatMap(leaves) }
        for leaf in leaves(view) where live.contains(leaf.leafId) && leafViews[leaf.leafId] === leaf {
            leaf.isHidden = true
            content.addSubview(leaf)
        }
    }

    @discardableResult
    private func build(_ node: SplitNode, path: [Int], tabId: UUID, into parent: NSView) -> NSView? {
        switch node {
        case .leaf(let leaf):
            guard let view = leafViews[leaf.id] else { return nil }
            placeLeaf(view, in: parent)
            view.isHidden = false  // parked by `park` on its way from another tab
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

    /// The file tab on screen for the status bar's tsserver item: the active tab's focused editor, else its first.
    var shownEditor: EditorPane? {
        guard let tab = activeTab else { return nil }
        return leafViews[tab.focusedLeafId]?.editor ?? tab.root.leaves.lazy.compactMap { self.leafViews[$0.id]?.editor }.first
    }


    /// ⌘⌥ + arrow: focus the pane on that side of the focused one; false when there is none (or the drawer / diff has the keys).
    func focusSplit(_ direction: SplitDirection) -> Bool {
        guard drawer.focusedLeaf == nil, app.activeDiff == nil, let tab = activeTab, let current = focusedLeaf else { return false }
        var frames: [UUID: CGRect] = [:]
        for leaf in tab.root.leaves {
            if let view = leafViews[leaf.id], view.window != nil { frames[leaf.id] = view.convert(view.bounds, to: nil) }
        }
        guard let next = splitNeighbour(of: current.leafId, in: frames, toward: direction), let view = leafViews[next] else { return false }
        window?.makeFirstResponder(view.keyView ?? view)
        return true
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
        window?.makeFirstResponder(leafViews[tab.root.leaves[n].id]?.keyView)
    }

    /// Debug summary of every surface and whether it renders.
    /// The Monaco page on screen: the diff's, else the active tab's focused (or first) editor.
    var debugMonaco: MonacoPage? {
        if app.activeDiff != nil, let id = app.selectedTask?.id { return diffHosts[id]?.editor.page }
        return shownEditor.map { $0.host.page($0.page) }
    }

    /// The web views on screen: the diff's, else the active tab's editor pages (two in a split).
    var debugWebViews: [WKWebView] {
        if app.activeDiff != nil { return debugMonaco.map { [$0.webView] } ?? [] }
        guard let tab = activeTab else { return [] }
        return tab.root.leaves.compactMap { leafViews[$0.id]?.editor }.map { $0.host.page($0.page).webView }
    }


    func debugEditors() -> [String] {
        leafViews.values.compactMap { view in
            guard let pane = view.editor, let leaf = app.editorLeaf(view.leafId) else { return nil }
            let files = leaf.editorFileList.map { f in
                let s = pane.session.files[f.path]
                return "\(pane.host.shown[pane.page] == view.leafId ? "*" : "")\((f.path as NSString).lastPathComponent):\(f.line):\(f.column)\(s?.dirty == true ? " dirty" : "")\(s?.conflict == true ? " conflict" : "")\(s?.readOnly == true ? " ro" : "")"
            }
            let web = pane.host.page(pane.page).webView
            return "editor leaf=\(view.leafId.uuidString.prefix(8)) page=\(pane.page) ready=\(pane.host.page(pane.page).isReady) files=\(files) pane=\(pane.frame) web=\(web.superview === pane ? "in" : "out") \(web.frame) hidden=\(web.isHiddenOrHasHiddenAncestor)"
        }
    }

    /// `surfaces <file>`: each leaf's view and surface identity, to prove a merge / move / detach kept them.
    func debugSurfaces() -> String {
        leafViews.map { id, view in
            "leaf=\(id.uuidString.prefix(8)) view=\(ObjectIdentifier(view)) surface=\(view.surface.map { "\(ObjectIdentifier($0))" } ?? "-") windowLosses=\(view.windowLosses)"
        }.sorted().joined(separator: "\n")
    }

    func debugDump() -> String {
        let drawers = drawer.debugDump()
        return leafViews.map { id, view in
            "leaf=\(id.uuidString.prefix(8)) surface=\(view.surface != nil) hidden=\(view.surface?.isHidden ?? true) inWindow=\(view.window != nil) exit=\(view.exitCode.map(String.init) ?? "-") failed=\(view.failed)"
        }.sorted().joined(separator: "\n") + (drawers.isEmpty ? "" : "\n" + drawers)
    }

    /// Debug: every model leaf of a started tab against its view (orphaned or blank leaves show as problems).
    func debugCheck() -> String {
        var lines: [String] = []
        for task in app.state.tasks where !task.archived {
            for tab in task.tabs {
                guard let tabView = tabViews[tab.id] else { lines.append("tab=\(tab.id.uuidString.prefix(8)) notStarted"); continue }
                let tabOK = tabView.frame == content.bounds && tabView.subviews.allSatisfy { $0.frame == tabView.bounds }
                lines.append("\(tabOK ? "ok" : "PROBLEM") tab=\(tab.id.uuidString.prefix(8)) task=\(task.name) content=\(content.frame.size) tab=\(tabView.frame) root=\(tabView.subviews.map(\.frame))")
                for leaf in tab.root.leaves {
                    guard let view = leafViews[leaf.id] else { lines.append("PROBLEM leaf=\(leaf.id.uuidString.prefix(8)) noView"); continue }
                    let content = view.chooser != nil || view.editor != nil || (view.surface?.isAlive == true && view.surface?.superview === view)
                    let ok = content && view.isDescendant(of: tabView) && view.window != nil && view.frame.width > 0 && view.frame.height > 0
                    lines.append("\(ok ? "ok" : "PROBLEM") leaf=\(leaf.id.uuidString.prefix(8)) task=\(task.name) alive=\(view.surface?.isAlive == true) inTab=\(view.isDescendant(of: tabView)) frame=\(Int(view.frame.width))x\(Int(view.frame.height)) exit=\(view.exitCode.map(String.init) ?? "-")")
                }
            }
        }
        let modelLeaves = Set(app.state.tasks.filter { !$0.archived }.flatMap(\.tabs).flatMap { $0.root.leaves.map(\.id) })
        for id in leafViews.keys where !modelLeaves.contains(id) { lines.append("PROBLEM orphanView leaf=\(id.uuidString.prefix(8))") }
        let orphanTabs = content.subviews.filter { v in !diffHosts.values.contains { $0.host === v } && !tabViews.values.contains { $0 === v } }
        if !orphanTabs.isEmpty { lines.append("PROBLEM orphanTabViews=\(orphanTabs.count)") }
        return lines.joined(separator: "\n")
    }
    #endif
}

/// The pane next to `id` toward `direction` (window coordinates, y up): it must lie past that edge and overlap it on the
/// other axis; the nearest wins, then the one sharing the longest edge, then the leftmost / topmost.
func splitNeighbour(of id: UUID, in frames: [UUID: CGRect], toward direction: SplitDirection) -> UUID? {
    guard let a = frames[id] else { return nil }
    let slop: CGFloat = 2  // the 1 pt divider between panes
    func gap(_ b: CGRect) -> CGFloat? {
        let d: CGFloat, overlap: Bool
        switch direction {
        case .left: (d, overlap) = (a.minX - b.maxX, b.minY < a.maxY && b.maxY > a.minY)
        case .right: (d, overlap) = (b.minX - a.maxX, b.minY < a.maxY && b.maxY > a.minY)
        case .up: (d, overlap) = (b.minY - a.maxY, b.minX < a.maxX && b.maxX > a.minX)
        case .down: (d, overlap) = (a.minY - b.maxY, b.minX < a.maxX && b.maxX > a.minX)
        }
        return overlap && d > -slop ? max(d, 0) : nil
    }
    func shared(_ b: CGRect) -> CGFloat {
        switch direction {
        case .left, .right: min(a.maxY, b.maxY) - max(a.minY, b.minY)
        case .up, .down: min(a.maxX, b.maxX) - max(a.minX, b.minX)
        }
    }
    let candidates = frames.compactMap { key, b in key == id ? nil : gap(b).map { (key, b, $0) } }
    return candidates.min { l, r in
        if l.2 != r.2 { return l.2 < r.2 }
        if shared(l.1) != shared(r.1) { return shared(l.1) > shared(r.1) }
        return l.1.minX != r.1.minX ? l.1.minX < r.1.minX : l.1.maxY > r.1.maxY
    }?.0
}

/// A host connected (`remote.onConnected`): its leaves waiting for it launch, detached ones reattach.
@MainActor func hostConnected(host: String, leaves: [LeafView]) {
    for view in leaves where view.host == host {
        if view.isDetached { view.relaunch(focus: false) } else { view.resumeIfWaiting() }
    }
}

/// OSC 9 has only a body, OSC 777 a title and a body: «title — body», empty parts dropped.
func oscNotificationText(title: String, body: String) -> String? {
    let parts = [title, body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " — ")
}
