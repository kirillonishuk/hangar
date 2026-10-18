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
                    if case .worktree = task.mode { IconView(icon: .worktree, size: Theme.smallIconSize) }
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
struct TabBarView: View {
    let app: AppState
    @State private var plusHover = false

    var body: some View {
        HStack(spacing: 0) {
            if let task = app.selectedTask {
                HStack(alignment: .bottom, spacing: Theme.tabGap) {
                    ForEach(task.tabs) { tab in
                        TabItem(app: app, tab: tab, active: tab.id == task.activeTabId)
                    }
                    addMenu
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
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { plusHover = h } }
        .padding(.bottom, Theme.railInset)
        .help(L10n.newTabHelp)
    }

    private func item(_ title: String, _ kind: LeafKind) -> some View {
        Button { app.addTab(kind) } label: { Label { Text(title) } icon: { Image(nsImage: Icon.of(kind).image) } }
    }
}

private struct TabItem: View {
    let app: AppState
    let tab: Workspace.Tab
    let active: Bool
    @State private var hover = false

    /// frame(maxWidth:) would make every tab max-wide, so long titles are shortened instead.
    static func clipped(_ title: String) -> String {
        title.count > Theme.tabMaxChars ? String(title.prefix(Theme.tabMaxChars - 1)) + "…" : title
    }

    private var hasAgent: Bool { tab.root.leaves.contains { $0.kind == .claude || $0.kind == .codex } }

    var body: some View {
        HStack(spacing: 0) {
            if hasAgent {
                // shortcut: always idle until agent statuses arrive (stage 3)
                StatusDot().padding(.trailing, Theme.statusDot)
            }
            if let kind = tab.root.leaves.first?.kind {
                IconView(icon: .of(kind), active: active).padding(.trailing, Theme.iconGap)
            }
            Text(Self.clipped(app.tabLabel(tab)))
                .lineLimit(1)
            Button { app.closeTab(tab.id) } label: { IconView(icon: .close, active: active, size: Theme.smallIconSize) }
                .buttonStyle(.plain)
                .opacity(hover ? Theme.closeOpacity : 0)
                .padding(.leading, Theme.statusDot)
                .help(L10n.closeTabHelp)
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
        .onTapGesture { app.activate(tabId: tab.id) }
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .animation(Motion.ease(Theme.selectionFade), value: active)
    }
}
