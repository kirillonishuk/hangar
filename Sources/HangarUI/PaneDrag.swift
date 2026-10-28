import AppKit
import Workspace

// Dragging a tab onto a pane edge, a pane header onto a pane edge or into the tab bar (splits spec §2). One gesture mechanism at window level,
// as the tab strip's own (#54): no NSItemProvider. Points are window points from the top-left (debug `mouse`/`hit`).

enum PaneDragSource: Equatable { case tab(UUID), leaf(UUID) }

enum PaneDropTarget: Equatable { case edge(tab: UUID, leaf: UUID, SplitEdge), tabBar(index: Int) }

/// The edge zone of `rect` under `p`: `Theme.paneDropZone` of each side; the middle and outside are nil. Where two
/// zones meet, the side `p` is nearer to (by its share of that side) wins.
func dropEdge(in rect: CGRect, at p: CGPoint) -> SplitEdge? {
    guard rect.contains(p), rect.width > 0, rect.height > 0 else { return nil }
    let fx = (p.x - rect.minX) / rect.width, fy = (p.y - rect.minY) / rect.height
    let nearest = [(SplitEdge.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)].min { $0.1 < $1.1 }!
    return nearest.1 < Theme.paneDropZone ? nearest.0 : nil
}

/// The slot a tab dropped at `x` takes: the number of tabs (`frames` in tab order) whose middle is left of `x`.
func insertionIndex(x: CGFloat, frames: [CGRect]) -> Int {
    frames.filter { $0.midX < x }.count
}

/// Where `source` dropped at `p` would go. `paneFrames`: the active tab's panes (empty while the diff tab or «Сессии»
/// covers them, ruling R3). A tab merges into another tab's pane edge, within the editor cap. A pane moves to another
/// pane's edge, or over the tab bar (`tabFrames`: the session's tabs) becomes a tab at the slot under the pointer.
func resolveDrop(_ source: PaneDragSource, at p: CGPoint, state: WorkspaceState, taskId: UUID, activeTab: UUID?,
                 paneFrames: [UUID: CGRect], tabBar: CGRect?, tabFrames: [UUID: CGRect]) -> PaneDropTarget? {
    switch source {
    case .tab(let tab):
        guard let active = activeTab, tab != active, state.canMergeTab(taskId: taskId, source: tab, into: active),
              let (leaf, rect) = paneFrames.first(where: { $0.value.contains(p) }),
              let edge = dropEdge(in: rect, at: p) else { return nil }
        return .edge(tab: active, leaf: leaf, edge)
    case .leaf(let id):
        if let bar = tabBar, bar.contains(p) {
            // Only a pane of a split tab has a header; detaching needs one.
            guard let tabs = state.tasks.first(where: { $0.id == taskId })?.tabs,
                  let own = tabs.first(where: { $0.root.leaf(id: id) != nil }), case .split = own.root else { return nil }
            return .tabBar(index: insertionIndex(x: p.x, frames: tabs.compactMap { tabFrames[$0.id] }))
        }
        guard let active = activeTab, let (leaf, rect) = paneFrames.first(where: { $0.value.contains(p) }),
              state.canMoveLeaf(taskId: taskId, leafId: id, to: active, anchor: leaf),
              let edge = dropEdge(in: rect, at: p) else { return nil }
        return .edge(tab: active, leaf: leaf, edge)
    }
}

@MainActor func paneDropLabel(_ edge: SplitEdge) -> String {
    switch edge {
    case .right: L10n.dropRight
    case .left: L10n.dropLeft
    case .top: L10n.dropUp
    case .bottom: L10n.dropDown
    }
}

/// `view`'s frame in window points from the top-left.
@MainActor func windowRect(_ view: NSView) -> CGRect? {
    guard let height = view.window?.contentView?.frame.height else { return nil }
    let r = view.convert(view.bounds, to: nil)
    return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
}

/// A mouse event's point in window points from the top-left (the gesture's own space depends on the hosting view).
@MainActor func windowPoint(_ event: NSEvent?) -> CGPoint? {
    guard let event, event.type == .leftMouseDragged || event.type == .leftMouseUp,
          let height = event.window?.contentView?.frame.height else { return nil }
    return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
}

/// The chip that follows the pointer: the dragged tab's icon and name.
@MainActor func paneDragChip(_ source: PaneDragSource, app: AppState) -> (icon: Icon, title: String)? {
    switch source {
    case .tab(let id):
        guard let tab = app.state.tasks.lazy.flatMap(\.tabs).first(where: { $0.id == id }) else { return nil }
        return (tab.root.leaves.first.map { Icon.of($0.kind) } ?? .shell, app.tabLabel(tab))
    case .leaf(let id):
        guard let leaf = app.leaf(id: id) else { return nil }
        return (Icon.of(leaf.kind), app.paneTitle(leaf))
    }
}

/// Runs a drag that may end on a pane: tracks the target, shows the zone and the chip, locks the cursor (closed hand),
/// performs or cancels the drop. Driven only by the gesture's events and Esc: no timers.
@MainActor final class PaneDragController {
    private let app: AppState
    private let area: TerminalArea
    private let tabBar: NSView
    private let ghost = PaneDragGhost()
    /// A drag is under way (between the first `update` and `end`).
    private(set) var active = false
    /// Esc pressed: the rest of this drag does nothing.
    private var cancelled = false
    /// The last `update` was in drop mode (below the tab bar).
    private var dropping = false
    /// Swallows cursor updates of the views under the pointer while the cursor is locked.
    private var cursorMonitor: Any?
    /// App deactivation / the window resigning key or closing while locked: SwiftUI then drops the gesture's `onEnded`.
    private var lifecycle: [NSObjectProtocol] = []
    var cursorLocked: Bool { cursorMonitor != nil }

    init(app: AppState, area: TerminalArea, tabBar: NSView) {
        self.app = app
        self.area = area
        self.tabBar = tabBar
        app.paneDragMoved = { [weak self] s, p in self?.update(s, at: p) ?? false }
        app.paneDragEnded = { [weak self] s in self?.end(s) ?? false }
        app.paneDragCancelled = { [weak self] in self?.abort() }
    }

    /// True: drop mode (a tab below the tab bar; a pane header always), the tab strip leaves the tab in place.
    func update(_ source: PaneDragSource, at p: CGPoint) -> Bool {
        if cancelled { return true }
        if !active {
            active = true
            lockCursor()
        }
        NSCursor.closedHand.set()
        let bar = windowRect(tabBar)
        var overBar = false  // a tab over the tab bar is the strip's own reorder
        if case .tab = source { overBar = bar.map { p.y < $0.maxY } ?? true }
        guard !overBar, let task = app.selectedTask else {
            dropping = false
            show(nil)
            ghost.isHidden = true  // over the tab bar the tab itself follows the pointer
            return false
        }
        dropping = true
        let target = resolveDrop(source, at: p, state: app.state, taskId: task.id, activeTab: task.activeTabId,
                                 paneFrames: area.paneFrames(), tabBar: bar, tabFrames: app.tabFrames)
        show(target)
        showGhost(source, at: p, allowed: target != nil)
        return true
    }

    /// True: the controller handled the drop (merged / moved / detached, or cancelled in drop mode / by Esc); false: the tab strip's own.
    func end(_ source: PaneDragSource) -> Bool {
        defer { reset() }
        if cancelled { return true }
        guard dropping else { return false }
        switch (source, app.paneDropTarget) {
        case (.tab(let tab), .edge(let target, let leaf, let edge)?): app.mergeTab(tab, into: target, at: leaf, edge: edge)
        case (.leaf(let id), .edge(let target, let anchor, let edge)?): app.moveLeaf(id, to: target, at: anchor, edge: edge)
        case (.leaf(let id), .tabBar(let index)?): app.detachLeaf(id, toIndex: index)
        default: break
        }
        return true
    }

    /// Esc: no drop; the gesture's later events do nothing. False when no drag is running (Esc goes on as usual).
    @discardableResult func cancel() -> Bool {
        guard active, !cancelled else { return false }
        reset()
        cancelled = true
        return true
    }

    /// The gesture went away without an end (or the app/window lost focus): everything back, nothing dropped.
    func abort() { reset() }

    private func reset() {
        active = false
        cancelled = false
        dropping = false
        show(nil)
        ghost.isHidden = true
        unlockCursor()
    }

    private func show(_ target: PaneDropTarget?) {
        if app.paneDropTarget != target { app.paneDropTarget = target }
        guard case .edge(_, let leaf, let edge) = target, let rect = area.paneFrames()[leaf] else {
            area.dropOverlay.isHidden = true
            return
        }
        area.showDropZone(rect, edge: edge)
    }

    private func showGhost(_ source: PaneDragSource, at p: CGPoint, allowed: Bool) {
        guard let content = area.window?.contentView, let chip = paneDragChip(source, app: app) else { return }
        if ghost.superview !== content || content.subviews.last !== ghost {
            content.addSubview(ghost, positioned: .above, relativeTo: nil)  // above everything, also later additions
        }
        ghost.show(chip.icon, chip.title, at: NSPoint(x: p.x, y: content.frame.height - p.y), allowed: allowed)
    }

    /// Closed hand for the whole drag: cursor rects (split dividers) off, cursor updates (terminal I-beam, links,
    /// pointing hands) swallowed; restored on drop/cancel.
    private func lockCursor() {
        guard cursorMonitor == nil else { return }
        area.window?.disableCursorRects()
        NSCursor.closedHand.set()
        cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: .cursorUpdate) { _ in
            MainActor.assumeIsolated { NSCursor.closedHand.set() }
            return nil
        }
        let center = NotificationCenter.default
        let window = area.window
        let names: [(Notification.Name, AnyObject?)] = [(NSApplication.didResignActiveNotification, NSApp),
                                                        (NSWindow.didResignKeyNotification, window), (NSWindow.willCloseNotification, window)]
        lifecycle = names.compactMap { name, object in
            guard let object else { return nil }
            return center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.abort() }
            }
        }
    }

    private func unlockCursor() {
        guard let monitor = cursorMonitor else { return }
        NSEvent.removeMonitor(monitor)
        cursorMonitor = nil
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        lifecycle = []
        guard let window = area.window else { return }
        window.enableCursorRects()
        NSCursor.arrow.set()
        window.resetCursorRects()  // the view under the pointer sets its own again
    }
}

/// Over the target pane: the half the dropped pane will take in `accent` (tint, outline, «Справа/Слева/Сверху/Снизу»),
/// the rest of the pane dimmed. Never takes the mouse (the drag runs over it).
@MainActor final class PaneDropOverlay: NSView {
    private let zone = NSView()
    private let dim = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        for v in [dim, zone] {
            v.wantsLayer = true
            addSubview(v)
        }
        zone.layer?.borderWidth = Theme.paneDropLineWidth
        label.font = .systemFont(ofSize: Theme.fontSize.sheetTitle, weight: .semibold)
        label.alignment = .center
        zone.addSubview(label)
        observeTheme(#selector(applyTheme))
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func applyTheme() {
        zone.layer?.backgroundColor = Theme.accent.withAlphaComponent(Theme.paneDropFillOpacity).cgColor
        zone.layer?.borderColor = Theme.accent.cgColor
        dim.layer?.backgroundColor = Theme.paneDropScrim.cgColor
        label.textColor = Theme.textStrong
    }

    /// `pane` in the superview's coordinates.
    func show(over pane: NSRect, edge: SplitEdge) {
        frame = pane
        let (half, rest) = bounds.divided(atDistance: edge.axis == .horizontal ? bounds.width / 2 : bounds.height / 2,
                                          from: [.left: .minXEdge, .right: .maxXEdge, .bottom: .minYEdge, .top: .maxYEdge][edge]!)
        zone.frame = half
        dim.frame = rest
        label.stringValue = paneDropLabel(edge)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (half.width - label.frame.width) / 2, y: (half.height - label.frame.height) / 2)
        isHidden = false
    }
}

/// The chip under the pointer while a tab is dragged over the panes (a pane header: everywhere): icon + name; faded where it can't drop.
@MainActor final class PaneDragGhost: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = Theme.tabRadius
        layer?.borderWidth = 1
        layer?.shadowRadius = Theme.paneDragGhostShadowRadius
        layer?.shadowOpacity = Float(Theme.paneDragGhostShadowOpacity)
        layer?.shadowOffset = CGSize(width: 0, height: -Theme.paneDragGhostShadowRadius / 3)
        label.font = .systemFont(ofSize: Theme.fontSize.tab)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        observeTheme(#selector(applyTheme))
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.activeSegment.cgColor
        layer?.borderColor = Theme.sheetBorder.cgColor
        layer?.shadowColor = Theme.bg.cgColor
        label.textColor = Theme.textStrong
        icon.contentTintColor = Theme.text2
    }

    /// Below-right of the pointer; flipped to its other side near the right/bottom edge, then kept inside `bounds`.
    static func placement(_ size: NSSize, pointer p: NSPoint, in bounds: NSRect) -> NSRect {
        let off = Theme.paneDragGhostOffset
        var x = p.x + off, y = p.y - off - size.height
        if x + size.width > bounds.maxX { x = p.x - off - size.width }
        if y < bounds.minY { y = p.y + off }
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// `p`: the pointer in the window's content view (bottom-left origin); the chip sits below-right of it.
    func show(_ kind: Icon, _ title: String, at p: NSPoint, allowed: Bool) {
        icon.image = kind.image
        label.stringValue = title
        label.sizeToFit()
        let pad = Theme.paneDragGhostPaddingH, s = Theme.iconSize, h = Theme.paneDragGhostHeight
        let w = min(Theme.paneDragGhostMaxWidth, pad + s + Theme.iconGap + label.frame.width + pad)
        frame = Self.placement(NSSize(width: w, height: h), pointer: p, in: superview?.bounds ?? .infinite)
        icon.frame = NSRect(x: pad, y: (h - s) / 2, width: s, height: s)
        label.frame = NSRect(x: pad + s + Theme.iconGap, y: (h - label.frame.height) / 2,
                             width: w - pad * 2 - s - Theme.iconGap, height: label.frame.height)
        alphaValue = allowed ? Theme.paneDragGhostOpacity : Theme.paneDragGhostBlockedOpacity
        isHidden = false
    }
}
