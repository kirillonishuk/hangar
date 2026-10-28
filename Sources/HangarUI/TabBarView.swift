import AgentStatus
import AppKit
import SwiftUI
import Workspace

/// Tab bar geometry (decision #69, as VS Code / Pane): widths, overflow, scroll-into-view, wheel.
enum TabStrip {
    struct Layout: Equatable {
        var widths: [CGFloat]
        /// Width of the scroll area; `content` is the tabs' full width.
        var viewport: CGFloat
        var content: CGFloat
        var overflow: Bool
    }

    /// A tab's least width: the status dot gets its own room, so a dotted tab keeps as much title as a plain one.
    static func minWidth(dot: Bool) -> CGFloat {
        Theme.tabMinWidth + (dot ? Theme.statusDot + Theme.rowEndGap : 0)
    }

    /// `width` holds the tabs and the fixed controls (`+`, and the chevron when they overflow); `dots[i]`: tab i shows
    /// a status dot (missing = no dot). Tabs get their natural width within [min, max]; a crowded bar shrinks the widest
    /// first, then scrolls at min.
    /// `whole[i]`: tab i is a file (or diff) tab, whose name never shrinks below its natural width (up to the max, #83).
    static func layout(natural: [CGFloat], dots: [Bool] = [], whole: [Bool] = [], width: CGFloat) -> Layout {
        let control = Theme.tabGap + Theme.tabBarButton
        let floors = natural.indices.map { i in
            let least = minWidth(dot: dots.indices.contains(i) && dots[i])
            return whole.indices.contains(i) && whole[i] ? Swift.max(least, Swift.min(natural[i], Theme.tabMaxWidth)) : least
        }
        if content(floors) <= width - control {
            let fit = widths(natural, floors: floors, room: width - control)
            let total = content(fit)
            return Layout(widths: fit, viewport: total, content: total, overflow: false)
        }
        return Layout(widths: floors, viewport: Swift.max(width - 2 * control, 0), content: content(floors), overflow: true)
    }

    /// Water-filling: one cap for all tabs so the narrow ones keep their width; never below a tab's own minimum.
    /// The total is piecewise linear in the cap: found exactly on the segment between two tab widths, so the sum
    /// meets `room` (enough room for every minimum is the caller's check).
    private static func widths(_ natural: [CGFloat], floors: [CGFloat], room: CGFloat) -> [CGFloat] {
        let desired = zip(natural, floors).map { Swift.min(Swift.max($0, $1), Swift.max(Theme.tabMaxWidth, $1)) }
        let rest = room - Theme.tabGap * CGFloat(Swift.max(desired.count - 1, 0))
        guard desired.reduce(0, +) > rest else { return desired }
        let at = { (cap: CGFloat) in zip(desired, floors).map { Swift.max($1, Swift.min($0, cap)) } }
        let marks = Array(Set(desired + floors)).sorted()
        var cap = marks.first ?? 0
        for (lo, hi) in zip(marks, marks.dropFirst()) {
            let sum = at(lo).reduce(0, +)
            let slope = CGFloat(zip(desired, floors).filter { $1 <= lo && $0 >= hi }.count)
            cap = lo
            if sum + slope * (hi - lo) >= rest { if slope > 0 { cap = lo + (rest - sum) / slope }; break }
        }
        return at(cap)
    }

    static func content(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + Theme.tabGap * CGFloat(Swift.max(widths.count - 1, 0))
    }

    static func clamp(_ offset: CGFloat, viewport: CGFloat, content: CGFloat) -> CGFloat {
        Swift.min(Swift.max(offset, 0), Swift.max(content - viewport, 0))
    }

    /// The least scroll that shows the tab whole and clear of the edge fades.
    static func reveal(index: Int, widths: [CGFloat], offset: CGFloat, viewport: CGFloat) -> CGFloat {
        let all = content(widths)
        guard widths.indices.contains(index) else { return clamp(offset, viewport: viewport, content: all) }
        let start = widths.prefix(index).reduce(0) { $0 + $1 + Theme.tabGap }, end = start + widths[index], m = Theme.tabFadeWidth
        let target = start - m < offset ? start - m : end + m > offset + viewport ? end + m - viewport : offset
        return clamp(target, viewport: viewport, content: all)
    }

    /// Scroll delta in points: the dominant axis (a plain vertical wheel scrolls sideways, as in VS Code).
    static func wheel(dx: CGFloat, dy: CGFloat, precise: Bool) -> CGFloat {
        let d = abs(dx) >= abs(dy) ? dx : dy
        return precise ? d : d * Theme.tabWheelLine
    }
}

/// The selected task's tabs, the overflow chevron and `+` (Claude / Codex / Editor / Shell). Row below the titlebar.
/// Tabs drag sideways to reorder (as sidebar rows: `dropIndex`, a 2 pt `accent` insertion line); the order is saved.
/// Too many tabs for the bar: it scrolls (decision #69); the chevron and `+` stay put at the right.
struct TabBarView: View {
    let app: AppState
    var ctx: ActionContext
    /// Scroll offset of the tabs (clamped on use); the dragged tab with its translation and the offset at drag start.
    @State private var scroll: CGFloat = 0
    @State private var drag: (tab: UUID, dx: CGFloat, from: CGFloat)?
    /// The dragged tab is below the bar, over the panes (`PaneDragController`): it stays in place, no insertion line.
    @State private var paneMode = false
    /// Room for tabs and controls, kept for scroll-into-view outside of layout.
    @State private var room: CGFloat = 0
    @State private var shownTask: UUID?

    private struct ActiveKey: Equatable {
        let task: UUID, tab: UUID?, diff: Bool, count: Int
    }

    private var activeKey: ActiveKey? {
        app.selectedTask.map { ActiveKey(task: $0.id, tab: $0.activeTabId, diff: app.diffTabs[$0.id]?.active == true, count: $0.tabs.count) }
    }

    var body: some View {
        GeometryReader { geo in
            let width = Swift.max(geo.size.width - Theme.tabTitleLeading - Theme.tabTitleTrailing, 0)
            HStack(alignment: .bottom, spacing: Theme.tabGap) {
                if let task = app.selectedTask { strip(task, width: width, minX: geo.frame(in: .global).minX + Theme.tabTitleLeading) }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.tabTitleLeading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .onChange(of: width, initial: true) { _, w in
                room = w
                reveal(animated: false)
            }
        }
        .frame(height: Theme.tabBarHeight)
        .background(WindowDragArea())
        .background(Theme.ui.tabStrip)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        .ignoresSafeArea()
        .onChange(of: activeKey) { reveal(animated: true) }
    }

    // MARK: Layout

    /// Natural width of a tab: paddings, dot, icon, title, `×` (the `×` keeps its place while hidden).
    private static func natural(text: CGFloat, dot: Bool) -> CGFloat {
        let chrome = 2 * Theme.tabPaddingH + Theme.iconSize + Theme.iconGap + Theme.rowEndGap + Theme.smallIconSize
        return (chrome + text + (dot ? Theme.statusDot + Theme.rowEndGap : 0)).rounded(.up)
    }

    private static func textWidth(_ text: String, italic: Bool = false) -> CGFloat {
        let base = NSFont.systemFont(ofSize: Theme.fontSize.tab)
        let font = italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func layout(_ task: HangarTask, width: CGFloat) -> TabStrip.Layout {
        let dots = task.tabs.map { app.showsDot($0, state: app.displayState(of: $0)) }
        var natural = zip(task.tabs, dots).map { tab, dot in
            let text = app.renaming == .tab(task: task.id, tab: tab.id) ? Theme.tabRenameWidth : Self.textWidth(app.tabLabel(tab), italic: tab.preview)
            return Self.natural(text: text, dot: dot)
        }
        var whole = task.tabs.map { tab in tab.root.leaves.count == 1 && tab.root.leaves[0].kind == .editor && tab.customTitle == nil }
        if let diff = app.diffTabs[task.id] {
            natural.append(Self.natural(text: Self.textWidth((diff.path as NSString).lastPathComponent + " ↔", italic: true), dot: false))
            whole.append(true)
        }
        return TabStrip.layout(natural: natural, dots: dots, whole: whole, width: width)
    }

    /// Index of the active tab in the strip (the diff tab is last).
    private func activeIndex(_ task: HangarTask) -> Int? {
        if app.diffTabs[task.id]?.active == true { return task.tabs.count }
        return task.tabs.firstIndex { $0.id == task.activeTabId }
    }

    /// Scrolls the active tab into view; another task starts from the left.
    private func reveal(animated: Bool) {
        guard let task = app.selectedTask, room > 0 else { return }
        let switched = shownTask != task.id
        shownTask = task.id
        let l = layout(task, width: room)
        guard let i = activeIndex(task) else { return }
        let from = switched ? 0 : TabStrip.clamp(scroll, viewport: l.viewport, content: l.content)
        let target = TabStrip.reveal(index: i, widths: l.widths, offset: from, viewport: l.viewport)
        guard target != scroll else { return }
        if animated && !switched { withAnimation(Motion.ease(Theme.selectionFade)) { scroll = target } } else { scroll = target }
    }

    // MARK: Strip

    @ViewBuilder private func strip(_ task: HangarTask, width: CGFloat, minX: CGFloat) -> some View {
        let l = layout(task, width: width)
        let offset = TabStrip.clamp(scroll, viewport: l.viewport, content: l.content)
        let diff = app.diffTabs[task.id]
        let dragDX = paneMode ? nil : drag.map { $0.dx + offset - $0.from }
        let slot = dropSlot(task, widths: l.widths, dx: dragDX)
        HStack(alignment: .bottom, spacing: Theme.tabGap) {
            ForEach(Array(task.tabs.enumerated()), id: \.element.id) { i, tab in
                TabItem(ctx: ctx, taskId: task.id, tab: tab, number: i < 8 ? i + 1 : i == task.tabs.count - 1 ? 9 : 0, active: tab.id == task.activeTabId && diff?.active != true,
                        width: l.widths[i],
                        onDrag: { dx, p in dragged(tab.id, dx: dx, at: p, l: l, minX: minX) },
                        onDragEnd: { endDrag(task, tab: tab.id, widths: l.widths) })
                    .overlay(alignment: slot?.edge == .leading ? .leading : .trailing) {
                        if slot?.tab == tab.id { Rectangle().fill(Theme.ui.accent).frame(width: Theme.dropLineWidth) }
                    }
                    .offset(x: drag?.tab == tab.id ? dragDX ?? 0 : 0)
                    .opacity(drag?.tab == tab.id ? Theme.tabDragOpacity : 1)
                    .zIndex(drag?.tab == tab.id ? 1 : 0)
            }
            if let diff, let w = l.widths.last { DiffTabItem(app: app, tab: diff, width: w) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: -offset)
        .frame(width: l.viewport, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .leading) { fade(.leading, visible: offset > 0) }
        .overlay(alignment: .trailing) { fade(.trailing, visible: offset < l.content - l.viewport) }
        .background(WheelCatcher(enabled: l.overflow) { delta in
            scroll = TabStrip.clamp(TabStrip.clamp(scroll, viewport: l.viewport, content: l.content) - delta, viewport: l.viewport, content: l.content)
        })
        if l.overflow { overflowMenu(task) }
        addMenu(shellOnly: app.isHostShellTask(task.id))
    }

    private func fade(_ edge: HorizontalEdge, visible: Bool) -> some View {
        LinearGradient(colors: [Theme.ui.tabStrip, Theme.ui.tabStrip.opacity(0)],
                       startPoint: edge == .leading ? .leading : .trailing, endPoint: edge == .leading ? .trailing : .leading)
            .frame(width: Theme.tabFadeWidth)
            .opacity(visible ? 1 : 0)
            .animation(Motion.ease(Theme.hoverFade), value: visible)
            .allowsHitTesting(false)
    }

    // MARK: Drag

    /// Live drag: the translation plus what the bar scrolled since; near an edge each move scrolls the bar a step.
    private func dragged(_ tab: UUID, dx: CGFloat, at p: CGPoint, l: TabStrip.Layout, minX: CGFloat) {
        let offset = TabStrip.clamp(scroll, viewport: l.viewport, content: l.content)
        drag = (tab, dx, drag?.from ?? offset)
        paneMode = app.paneDragMoved?(.tab(tab), p) ?? false
        let x = p.x
        guard l.overflow, !paneMode else { return }
        let step = x < minX + Theme.tabDragScrollEdge ? -Theme.tabDragScrollStep
            : x > minX + l.viewport - Theme.tabDragScrollEdge ? Theme.tabDragScrollStep : 0
        if step != 0 { scroll = TabStrip.clamp(offset + step, viewport: l.viewport, content: l.content) }
    }

    /// Where the dragged tab would land: index among the others, and the tab whose edge shows the insertion line.
    private func dropSlot(_ task: HangarTask, widths: [CGFloat], dx: CGFloat?) -> (index: Int, tab: UUID, edge: HorizontalEdge)? {
        guard let drag, let dx, let from = task.tabs.firstIndex(where: { $0.id == drag.tab }) else { return nil }
        let to = dropIndex(heights: widths.prefix(task.tabs.count).map { $0 + Theme.tabGap }, from: from, dy: dx)
        let others = task.tabs.map(\.id).filter { $0 != drag.tab }
        guard to != from, let last = others.last else { return nil }
        return to < others.count ? (to, others[to], .leading) : (to, last, .trailing)
    }

    private func endDrag(_ task: HangarTask, tab: UUID, widths: [CGFloat]) {
        let handled = app.paneDragEnded?(.tab(tab)) ?? false
        paneMode = false
        if handled { drag = nil }
        guard let d = drag, d.tab == tab else { return }
        let l = layout(task, width: room)
        let slot = dropSlot(task, widths: widths, dx: d.dx + TabStrip.clamp(scroll, viewport: l.viewport, content: l.content) - d.from)
        drag = nil
        if let slot { app.perform { $0.moveTab(taskId: task.id, tabId: tab, to: slot.index) } }
    }

    // MARK: Controls

    /// Every tab of the task (icon with its status dot, title); shown only while the bar overflows.
    private func overflowMenu(_ task: HangarTask) -> some View {
        let diff = app.diffTabs[task.id]
        return MoreButton(icon: .chevronDown, radius: Theme.tabRadius, size: Theme.tabBarButton, help: L10n.allTabsHelp) {
            ForEach(task.tabs) { tab in
                let state = app.displayState(of: tab)
                let icon = tab.root.leaves.first.map { Icon.of($0.kind) } ?? .shell
                Toggle(isOn: Binding(get: { tab.id == task.activeTabId && diff?.active != true }, set: { _ in app.activate(tabId: tab.id) })) {
                    Label { Text(verbatim: app.tabLabel(tab)) } icon: {
                        Image(nsImage: Self.menuIcon(icon, dot: app.showsDot(tab, state: state) ? state : nil))
                    }
                }
            }
            if let diff {
                Toggle(isOn: Binding(get: { diff.active }, set: { _ in app.activateDiff() })) {
                    Label { Text(verbatim: (diff.path as NSString).lastPathComponent) } icon: { Image(nsImage: Icon.diff.image) }
                }
            }
        }
        .padding(.bottom, Theme.railInset)
    }

    /// Menu icon with the tab's status dot at its lower right (menus drop SwiftUI colors, so it's drawn in).
    private static func menuIcon(_ icon: Icon, dot: AgentState?) -> NSImage {
        guard let dot else { return icon.image }
        let s = Theme.iconSize, d = Theme.statusDot
        let color = NSColor(Theme.ui.status(dot))
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            icon.image.draw(in: r)
            if !icon.isBrand {
                Theme.text.set()
                r.fill(using: .sourceAtop)
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: s - d, y: 0, width: d, height: d)).fill()
            return true
        }
    }

    /// A host's terminal (#64) holds only ssh shells: its menu offers just Shell.
    private func addMenu(shellOnly: Bool) -> some View {
        MoreButton(icon: .add, radius: Theme.tabRadius, size: Theme.tabBarButton, help: L10n.help(L10n.newTabHelp, .newTab)) {
            if !shellOnly {
                item("Claude", .claude)
                item("Codex", .codex)
            }
            item("Shell", .shell)
        }
        .padding(.bottom, Theme.railInset)
    }

    private func item(_ title: String, _ kind: LeafKind) -> some View {
        Button { app.addTab(kind) } label: { Label { Text(title) } icon: { Image(nsImage: Icon.of(kind).image) } }
            .modifier(MenuShortcutHint(shortcut: kind == .shell ? .newTab : nil))
    }
}

/// Wheel and trackpad over the tab strip scroll it sideways. A local monitor: scroll events go to the hit view,
/// and SwiftUI content isn't one; installed only while the bar is in a window, no polling.
private struct WheelCatcher: NSViewRepresentable {
    let enabled: Bool
    let onScroll: (CGFloat) -> Void

    final class CatcherView: NSView {
        var enabled = false
        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let e = event
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.enabled, e.window === self.window,
                          self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return false }
                    self.onScroll(TabStrip.wheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas))
                    return true
                }
                return consumed ? nil : event
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.enabled = enabled
        view.onScroll = onScroll
    }
}

/// The `×` of a tab: faint while the tab is hovered, full with its own hover background.
private struct TabCloseButton: View {
    let active: Bool
    let tabHover: Bool
    /// Unsaved file: a dot in the button's place until it is hovered (as in VS Code).
    var dirty = false
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                IconView(icon: .close, active: active || hover, size: Theme.smallIconSize).opacity(dirty && !hover ? 0 : 1)
                Circle().fill(active ? Theme.ui.textStrong : Theme.ui.text2).frame(width: Theme.statusDot, height: Theme.statusDot)
                    .opacity(dirty && !hover ? 1 : 0)
            }
            .padding(Theme.tabCloseInset)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.tabCloseRadius))
        .environment(\.hoverPalette, .strong)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .opacity(hover || dirty ? 1 : tabHover ? Theme.closeOpacity : 0)
        // The hover box grows into the tab's padding, so the tab keeps its size.
        .padding(.vertical, -Theme.tabCloseInset)
        .padding(.leading, Theme.rowEndGap - Theme.tabCloseInset)
        .padding(.trailing, -Theme.tabCloseInset)
        .help(help)
    }
}

/// Active tab: `tabActive` fill and a 2 pt `accent` line on top (DESIGN «Полоса вкладок»); others: `tabInactive`, `hover` under the pointer.
private struct TabBackground: View {
    let active: Bool
    let hover: Bool

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Theme.tabRadius, topTrailingRadius: Theme.tabRadius)
        ZStack(alignment: .top) {
            shape.fill(active ? Theme.ui.activeSegment : hover ? Theme.ui.hover : Theme.ui.tabInactive)
            Rectangle().fill(Theme.ui.accent).frame(height: Theme.tabActiveLine).opacity(active ? 1 : 0)
        }
        .clipShape(shape)
    }
}

struct TabItem: View {
    let ctx: ActionContext
    let taskId: UUID
    let tab: Workspace.Tab
    /// Its ⌘ number for the tooltip: 1…8 by position, 9 for the last tab, 0 for none.
    var number = 0
    let active: Bool
    /// From `TabStrip.layout`; the title truncates inside it.
    var width: CGFloat
    /// Live drag: translation and pointer (window points from the top-left); then the end.
    var onDrag: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onDragEnd: () -> Void = {}
    @State private var hover = false
    @State private var dragging = false

    private var app: AppState { ctx.app }
    private var target: ActionTarget { .tab(task: taskId, tab: tab.id) }
    /// The file of a file tab (an unsplit editor leaf).
    private var fileLeaf: Leaf? {
        guard case .leaf(let leaf) = tab.root, leaf.kind == .editor else { return nil }
        return leaf
    }

    var body: some View {
        HStack(spacing: 0) {
            let dot = app.displayState(of: tab)
            if app.showsDot(tab, state: dot) {
                StatusDot(state: dot).padding(.trailing, Theme.rowEndGap).help(app.statusText(dot, leaves: tab.root.leaves))
            }
            // A file tab (#83): the file type's icon; a one-click preview reads in italics.
            if let file = fileLeaf?.openFile {
                FileIconView(name: (file as NSString).lastPathComponent).padding(.trailing, Theme.iconGap)
            } else if let kind = tab.root.leaves.first?.kind {
                IconView(icon: .of(kind), active: active).padding(.trailing, Theme.iconGap)
            }
            if app.renaming == target {
                RenameField(app: app, target: target).frame(maxWidth: Theme.tabRenameWidth)
            } else {
                Text(verbatim: app.tabLabel(tab)).italic(tab.preview).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            TabCloseButton(active: active, tabHover: hover, dirty: fileLeaf.map { app.editorDirty.contains($0.id) } ?? false,
                           help: L10n.help(L10n.closeTabHelp, Action.closeTab.shortcut(for: target, app: app))) {
                Action.closeTab.perform(target, ctx)
            }
        }
        .font(.system(size: Theme.fontSize.tab))
        .foregroundStyle(active ? Theme.ui.textStrong : Theme.ui.text2)
        .padding(.vertical, Theme.tabPaddingV)
        .padding(.horizontal, Theme.tabPaddingH)
        .frame(width: width)
        .background(TabBackground(active: active, hover: hover))
        .contentShape(Rectangle())
        // One tap handler: a separate count-2 gesture would delay every single click.
        .onTapGesture {
            app.chromeClicked(target)
            app.activate(tabId: tab.id)
            // A double click keeps a preview tab (as in VS Code); on any other tab it renames.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if tab.preview { app.perform { $0.pinTab(taskId: taskId, tabId: tab.id) } } else { Action.rename.perform(target, ctx) }
            }
        }
        // Global space: the dragged tab is offset while dragging, local translations would feed back.
        .simultaneousGesture(DragGesture(minimumDistance: Theme.dragThreshold, coordinateSpace: .global)
            .onChanged { value in
                guard app.renaming != target else { return }
                dragging = true
                onDrag(value.translation.width, windowPoint(NSApp.currentEvent) ?? value.location)
            }
            .onEnded { _ in
                guard dragging else { return }
                dragging = false
                onDragEnd()
            })
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
        .help(L10n.help(app.tabHelpTitle(tab, taskId: taskId), (1...9).contains(number) ? .tab(number) : nil)
              + (app.isHostShellTask(taskId) ? "\n" + L10n.plainSSHHint : ""))
        .pointingHand(app.renaming != target && !dragging)  // a drag keeps its closed hand (PaneDragController)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .animation(Motion.ease(Theme.selectionFade), value: active)
    }
}

/// The temporary diff tab (DESIGN «Полоса вкладок»): diff icon + `<file>` in italics, no status dot, no context menu.
private struct DiffTabItem: View {
    let app: AppState
    let tab: DiffTab
    let width: CGFloat
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            IconView(icon: .diff, active: tab.active).padding(.trailing, Theme.iconGap)
            Text(verbatim: (tab.path as NSString).lastPathComponent + " ↔").italic().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            TabCloseButton(active: tab.active, tabHover: hover, help: L10n.help(L10n.diffTabHelp, .closeTab)) { app.closeDiff() }
        }
        .font(.system(size: Theme.fontSize.tab))
        .foregroundStyle(tab.active ? Theme.ui.textStrong : Theme.ui.text2)
        .padding(.vertical, Theme.tabPaddingV)
        .padding(.horizontal, Theme.tabPaddingH)
        .frame(width: width)
        .background(TabBackground(active: tab.active, hover: hover))
        .contentShape(Rectangle())
        .onTapGesture { app.activateDiff() }
        .pointingHand()
        .help(tab.path)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .animation(Motion.ease(Theme.selectionFade), value: tab.active)
    }
}
