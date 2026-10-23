import AppKit
import SwiftUI
import Workspace

/// Task title on the left, then the task's tabs and `+` (Claude / Codex / Helix / Shell).
/// Titlebar row over the task area: centered "Project · Task", inspector toggle on the right.
/// Empty space drags the window; double-click follows the system zoom/minimize setting.
struct TitleBarView: View {
    let app: AppState

    var body: some View {
        ZStack {
            if let task = app.selectedTask {
                HStack(spacing: Theme.railInset * 1.5) {
                    Text(app.project(task.projectId)?.name ?? "").foregroundStyle(Theme.ui.text2)
                    Text("·").foregroundStyle(Theme.ui.text3)
                    Text(task.name).foregroundStyle(Theme.ui.textStrong)
                    if let branch = task.branch {
                        IconView(icon: .worktree, size: Theme.smallIconSize)
                        Text(branch).font(.system(size: Theme.fontSize.tab, design: .monospaced)).foregroundStyle(Theme.ui.text3)
                    }
                }
                .font(.system(size: Theme.fontSize.tabTaskTitle))
                .lineLimit(1)
                .allowsHitTesting(false)
            }
            HStack {
                Spacer()
                Button { app.perform { $0.inspectorVisible.toggle() } } label: {
                    IconView(icon: .sidebarRight, active: app.state.inspectorVisible)
                        .frame(width: Theme.titleButtonSize, height: Theme.titleButtonSize)
                }
                .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                .help(L10n.inspectorHelp)
                .padding(.trailing, Theme.tabTitleTrailing)
            }
        }
        .frame(height: Theme.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
        .background(Theme.ui.bg)
        .ignoresSafeArea()
    }
}

/// The selected task's tabs and `+` (Claude / Codex / Helix / Shell). Separate row below the titlebar.
/// Tabs drag sideways to reorder (as sidebar rows: `dropIndex`, a 2 pt `accent` insertion line); the order is saved.
struct TabBarView: View {
    let app: AppState
    var ctx: ActionContext
    @State private var plusHover = false
    /// Widths of the task's tabs (measured), for the drop index.
    @State private var widths: [UUID: CGFloat] = [:]
    @State private var drag: (tab: UUID, dx: CGFloat)?

    var body: some View {
        HStack(spacing: 0) {
            if let task = app.selectedTask {
                // Titles keep their full width while they fit; only a crowded bar shortens them.
                ViewThatFits(in: .horizontal) {
                    tabs(task, fixed: true)
                    tabs(task, fixed: false)
                }
                .padding(.leading, Theme.tabTitleLeading)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.tabBarHeight)
        .background(WindowDragArea())
        .background(Theme.ui.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        .ignoresSafeArea()
        .onPreferenceChange(TabWidths.self) { widths = $0 }
    }

    private func tabs(_ task: HangarTask, fixed: Bool) -> some View {
        HStack(alignment: .bottom, spacing: Theme.tabGap) {
            let diff = app.diffTabs[task.id]
            let slot = dropSlot(task)
            ForEach(task.tabs) { tab in
                TabItem(ctx: ctx, taskId: task.id, tab: tab, active: tab.id == task.activeTabId && diff?.active != true, fixed: fixed,
                        onDrag: { dx in drag = (tab.id, dx) }, onDragEnd: { dx in endDrag(task, tab: tab.id, dx: dx) })
                    .background(GeometryReader { g in Color.clear.preference(key: TabWidths.self, value: [tab.id: g.size.width]) })
                    .overlay(alignment: slot?.edge == .leading ? .leading : .trailing) {
                        if slot?.tab == tab.id { Rectangle().fill(Theme.ui.accent).frame(width: Theme.dropLineWidth) }
                    }
                    .offset(x: drag?.tab == tab.id ? drag?.dx ?? 0 : 0)
                    .opacity(drag?.tab == tab.id ? Theme.tabDragOpacity : 1)
                    .zIndex(drag?.tab == tab.id ? 1 : 0)
            }
            if let diff { DiffTabItem(app: app, tab: diff, fixed: fixed) }
            addMenu
        }
    }

    /// Where the dragged tab would land: index among the others, and the tab whose edge shows the insertion line.
    private func dropSlot(_ task: HangarTask) -> (index: Int, tab: UUID, edge: HorizontalEdge)? {
        guard let drag, let from = task.tabs.firstIndex(where: { $0.id == drag.tab }) else { return nil }
        let to = dropIndex(heights: task.tabs.map { widths[$0.id] ?? 0 }, from: from, dy: drag.dx)
        let others = task.tabs.map(\.id).filter { $0 != drag.tab }
        guard to != from, let last = others.last else { return nil }
        return to < others.count ? (to, others[to], .leading) : (to, last, .trailing)
    }

    private func endDrag(_ task: HangarTask, tab: UUID, dx: CGFloat) {
        drag = (tab, dx)
        let slot = dropSlot(task)
        drag = nil
        if let slot { app.perform { $0.moveTab(taskId: task.id, tabId: tab, to: slot.index) } }
    }

    private var addMenu: some View {
        Menu {
            item("Claude", .claude)
            item("Codex", .codex)
            item("Helix", .editor)
            item("Shell", .shell)
        } label: {
            Image(nsImage: Icon.newTask.image).renderingMode(.template)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.vertical, Theme.tabPaddingV)
        .padding(.horizontal, Theme.tabPaddingV)
        .background(RoundedRectangle(cornerRadius: Theme.tabRadius).fill(plusHover ? Theme.ui.hover : .clear))
        .pointingHand()
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { plusHover = h } }
        .padding(.bottom, Theme.railInset)
        .help(L10n.newTabHelp)
    }

    private func item(_ title: String, _ kind: LeafKind) -> some View {
        Button { app.addTab(kind) } label: { Label { Text(title) } icon: { Image(nsImage: Icon.of(kind).image) } }
    }
}

private struct TabWidths: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// The tab's title: at its full (clipped) width while the bar has room, else shortened by the layout.
private struct TabTitle: View {
    let text: String
    let fixed: Bool

    var body: some View {
        Text(verbatim: text).lineLimit(1).fixedSize(horizontal: fixed, vertical: false)
    }
}

/// The `×` of a tab: faint while the tab is hovered, full with its own hover background.
private struct TabCloseButton: View {
    let active: Bool
    let tabHover: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            IconView(icon: .close, active: active || hover, size: Theme.smallIconSize)
                .padding(Theme.tabCloseInset)
                .background(RoundedRectangle(cornerRadius: Theme.tabCloseRadius).fill(hover ? Theme.ui.hoverStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .opacity(hover ? 1 : tabHover ? Theme.closeOpacity : 0)
        // The hover box grows into the tab's padding, so the tab keeps its size.
        .padding(.vertical, -Theme.tabCloseInset)
        .padding(.leading, Theme.statusDot - Theme.tabCloseInset)
        .padding(.trailing, -Theme.tabCloseInset)
        .help(help)
    }
}

struct TabItem: View {
    let ctx: ActionContext
    let taskId: UUID
    let tab: Workspace.Tab
    let active: Bool
    var fixed = true
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: (CGFloat) -> Void = { _ in }
    @State private var hover = false
    @State private var dragging = false

    /// frame(maxWidth:) would make every tab max-wide, so long titles are shortened instead.
    static func clipped(_ title: String) -> String {
        title.count > Theme.tabMaxChars ? String(title.prefix(Theme.tabMaxChars - 1)) + "…" : title
    }

    private var app: AppState { ctx.app }
    private var target: ActionTarget { .tab(task: taskId, tab: tab.id) }

    var body: some View {
        HStack(spacing: 0) {
            let dot = app.displayState(of: tab)
            if app.showsDot(tab, state: dot) {
                StatusDot(state: dot).padding(.trailing, Theme.statusDot)
            }
            if let kind = tab.root.leaves.first?.kind {
                IconView(icon: .of(kind), active: active).padding(.trailing, Theme.iconGap)
            }
            if app.renaming == target {
                RenameField(app: app, target: target).frame(width: Theme.tabRenameWidth)
            } else {
                TabTitle(text: Self.clipped(app.tabLabel(tab)), fixed: fixed)
            }
            TabCloseButton(active: active, tabHover: hover, help: L10n.closeTabHelp) { Action.closeTab.perform(target, ctx) }
        }
        .font(.system(size: Theme.fontSize.tab))
        .foregroundStyle(active ? Theme.ui.textStrong : Theme.ui.text2)
        .padding(.vertical, Theme.tabPaddingV)
        .padding(.horizontal, Theme.tabPaddingH)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Theme.tabRadius, topTrailingRadius: Theme.tabRadius)
                .fill(active ? Theme.ui.activeSegment : hover ? Theme.ui.hover : Color.clear)
        )
        .contentShape(Rectangle())
        // One tap handler: a separate count-2 gesture would delay every single click.
        .onTapGesture {
            app.chromeClicked(target)
            app.activate(tabId: tab.id)
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { Action.rename.perform(target, ctx) }
        }
        // Global space: the dragged tab is offset while dragging, local translations would feed back.
        .simultaneousGesture(DragGesture(minimumDistance: Theme.dragThreshold, coordinateSpace: .global)
            .onChanged { value in
                guard app.renaming != target else { return }
                dragging = true
                onDrag(value.translation.width)
            }
            .onEnded { value in
                guard dragging else { return }
                dragging = false
                onDragEnd(value.translation.width)
            })
        .contextMenu { ActionMenuItems(target: target, ctx: ctx) }
        .pointingHand(app.renaming != target)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .animation(Motion.ease(Theme.selectionFade), value: active)
    }
}

/// The temporary diff tab (DESIGN «Полоса вкладок»): `± <file>` in italics, no status dot, no context menu.
private struct DiffTabItem: View {
    let app: AppState
    let tab: DiffTab
    let fixed: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            TabTitle(text: "± " + TabItem.clipped((tab.path as NSString).lastPathComponent), fixed: fixed).italic()
            TabCloseButton(active: tab.active, tabHover: hover, help: L10n.diffTabHelp) { app.closeDiff() }
        }
        .font(.system(size: Theme.fontSize.tab))
        .foregroundStyle(tab.active ? Theme.ui.textStrong : Theme.ui.text2)
        .padding(.vertical, Theme.tabPaddingV)
        .padding(.horizontal, Theme.tabPaddingH)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Theme.tabRadius, topTrailingRadius: Theme.tabRadius)
                .fill(tab.active ? Theme.ui.activeSegment : hover ? Theme.ui.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.activateDiff() }
        .pointingHand()
        .help(tab.path)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .animation(Motion.ease(Theme.selectionFade), value: tab.active)
    }
}
