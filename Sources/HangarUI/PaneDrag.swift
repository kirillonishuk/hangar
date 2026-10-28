import AppKit
import Workspace

// Dragging a tab (Task 7: a pane header) onto a pane edge (splits spec §2). One gesture mechanism at window level,
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

/// Where `source` dropped at `p` would go. `paneFrames`: the active tab's panes (empty while the diff tab or «Сессии»
/// covers them, ruling R3). A tab merges into another tab's pane edge, within the editor cap.
func resolveDrop(_ source: PaneDragSource, at p: CGPoint, state: WorkspaceState, taskId: UUID, activeTab: UUID?,
                 paneFrames: [UUID: CGRect], tabBar: CGRect?, tabFrames: [UUID: CGRect]) -> PaneDropTarget? {
    switch source {
    case .tab(let tab):
        guard let active = activeTab, tab != active, state.canMergeTab(taskId: taskId, source: tab, into: active),
              let (leaf, rect) = paneFrames.first(where: { $0.value.contains(p) }),
              let edge = dropEdge(in: rect, at: p) else { return nil }
        return .edge(tab: active, leaf: leaf, edge)
    case .leaf:
        return nil  // pane headers: Task 7
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

/// Runs a drag that may end on a pane: tracks the target, shows the zone, performs or cancels the drop.
/// Driven only by the gesture's events and Esc: no timers.
@MainActor final class PaneDragController {
    private let app: AppState
    private let area: TerminalArea
    private let tabBar: NSView
    /// A drag is under way (between the first `update` and `end`).
    private(set) var active = false
    /// Esc pressed: the rest of this drag does nothing.
    private var cancelled = false
    /// The last `update` was in drop mode (below the tab bar).
    private var dropping = false

    init(app: AppState, area: TerminalArea, tabBar: NSView) {
        self.app = app
        self.area = area
        self.tabBar = tabBar
        app.paneDragMoved = { [weak self] s, p in self?.update(s, at: p) ?? false }
        app.paneDragEnded = { [weak self] s in self?.end(s) ?? false }
    }

    /// True: drop mode (pointer below the tab bar), the tab strip leaves the tab in place.
    func update(_ source: PaneDragSource, at p: CGPoint) -> Bool {
        active = true
        if cancelled { return true }
        guard case .tab = source, let bar = windowRect(tabBar), p.y >= bar.maxY, let task = app.selectedTask else {
            dropping = false
            show(nil)
            return false
        }
        dropping = true
        show(resolveDrop(source, at: p, state: app.state, taskId: task.id, activeTab: task.activeTabId,
                         paneFrames: area.paneFrames(), tabBar: bar, tabFrames: [:]))
        return true
    }

    /// True: the controller handled the drop (merged, or cancelled in drop mode / by Esc); false: the tab strip's own.
    func end(_ source: PaneDragSource) -> Bool {
        defer { reset() }
        if cancelled { return true }
        guard dropping else { return false }
        if case .tab(let tab) = source, case .edge(let target, let leaf, let edge) = app.paneDropTarget {
            app.mergeTab(tab, into: target, at: leaf, edge: edge)
        }
        return true
    }

    /// Esc: no drop; the gesture's later events do nothing. False when no drag is running (Esc goes on as usual).
    @discardableResult func cancel() -> Bool {
        guard active, !cancelled else { return false }
        cancelled = true
        show(nil)
        return true
    }

    private func reset() {
        active = false
        cancelled = false
        dropping = false
        show(nil)
    }

    private func show(_ target: PaneDropTarget?) {
        if app.paneDropTarget != target { app.paneDropTarget = target }
        guard case .edge(_, let leaf, let edge) = target, let rect = area.paneFrames()[leaf] else {
            area.dropOverlay.isHidden = true
            return
        }
        area.showDropZone(rect, edge: edge)
    }
}

/// The half of a pane a dropped pane will take: `accent` tint and outline with «Вправо/Влево/Вверх/Вниз».
/// Never takes the mouse (the drag runs over it).
@MainActor final class PaneDropOverlay: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.borderWidth = Theme.paneDropLineWidth
        label.font = .systemFont(ofSize: Theme.fontSize.base, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        observeTheme(#selector(applyTheme))
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func applyTheme() {
        layer?.backgroundColor = Theme.accent.withAlphaComponent(Theme.paneDropFillOpacity).cgColor
        layer?.borderColor = Theme.accent.cgColor
        label.textColor = Theme.textStrong
    }

    /// `pane` in the superview's coordinates.
    func show(over pane: NSRect, edge: SplitEdge) {
        var r = pane
        switch edge {  // superview coordinates: y grows upwards
        case .left: r.size.width /= 2
        case .right: r.size.width /= 2; r.origin.x += r.width
        case .bottom: r.size.height /= 2
        case .top: r.size.height /= 2; r.origin.y += r.height
        }
        frame = r
        label.stringValue = paneDropLabel(edge)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (r.width - label.frame.width) / 2, y: (r.height - label.frame.height) / 2)
        isHidden = false
    }
}
