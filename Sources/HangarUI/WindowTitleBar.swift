import AppKit
import Observation
import SwiftUI
import Workspace

/// «Проект · Сессия ⎇ ветка»; a host's terminal has no project part («vultr · терминал»).
struct WindowTitle: Equatable {
    var project: String?
    var session: String
    var branch: String?

    var text: String {
        ([project, session].compactMap { $0 }.joined(separator: " · ")) + (branch.map { " ⎇ " + $0 } ?? "")
    }
}

/// Title of the selected session; nil when none is selected.
@MainActor func windowTitle(_ s: WorkspaceState) -> WindowTitle? {
    guard let id = s.selectedTaskId, let task = s.tasks.first(where: { $0.id == id && !$0.archived }) else { return nil }
    if let host = s.hostShell(ofTask: id)?.host { return WindowTitle(session: L10n.hostTerminal(host)) }
    return WindowTitle(project: s.projects.first { $0.id == task.projectId }?.name, session: task.name, branch: task.branch)
}

/// Where the system puts the traffic lights, read from the real buttons so the titlebar row shares their centre line.
@MainActor @Observable final class TitleBarMetrics {
    /// Centre of the traffic lights, down from the top of the window; nil while they are hidden (full screen).
    var lightsCenterY: CGFloat?

    /// Shift from the bar's own middle to the traffic lights' centre line (0 when there are none).
    var offsetY: CGFloat { titlebarOffset(lightsCenterY: lightsCenterY, barHeight: Theme.titleBarHeight) }

    func update(from window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton),
              !close.isHidden, let content = window.contentView else { lightsCenterY = nil; return }
        let y = content.convert(close.convert(close.bounds, to: nil), from: nil)
        let c = content.isFlipped ? y.midY : content.bounds.height - y.midY
        if lightsCenterY != c { lightsCenterY = c }
    }
}

func titlebarOffset(lightsCenterY: CGFloat?, barHeight: CGFloat) -> CGFloat {
    lightsCenterY.map { $0 - barHeight / 2 } ?? 0
}

/// One titlebar across the window (redesign v1 §1, §6): traffic lights, the sidebar toggle at x 84 (it stays put when
/// the sidebar collapses), the title in the middle, the right sidebar toggle. Empty space drags the window;
/// double-click follows the system zoom/minimize setting.
struct WindowTitleBar: View {
    let app: AppState
    let metrics: TitleBarMetrics
    let toggleSidebar: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            title.frame(maxWidth: .infinity)
            button(.sidebarLeft, active: false, action: toggleSidebar)
                .help(L10n.help(app.state.sidebarCollapsed ? L10n.expandSidebarHelp : L10n.collapseSidebarHelp, .toggleSidebar))
                .padding(.leading, metrics.lightsCenterY == nil ? Theme.titlebarFullScreenX : Theme.titlebarToggleX)
                .offset(y: metrics.offsetY)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                button(.sidebarRight, active: app.state.inspectorVisible) { app.perform { $0.inspectorVisible.toggle() } }
                    .help(L10n.help(L10n.inspectorHelp, .toggleInspector))
                    .padding(.trailing, Theme.titlebarTrailing)
                    .offset(y: metrics.offsetY)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.titleBarHeight, maxHeight: Theme.titleBarHeight)
        .background(WindowDragArea())
        .background(Theme.ui.titlebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        .ignoresSafeArea()
    }

    @ViewBuilder private var title: some View {
        if let t = windowTitle(app.state) {
            HStack(spacing: Theme.inlineGap) {
                if let project = t.project {
                    Text(verbatim: project).foregroundStyle(Theme.ui.text2)
                    Text(verbatim: "·").foregroundStyle(Theme.ui.text3)
                }
                Text(verbatim: t.session).fontWeight(.medium).foregroundStyle(Theme.ui.textStrong)
                if let branch = t.branch {
                    HStack(spacing: Theme.railInset) {
                        IconView(icon: .branch, size: Theme.titleBranchIcon)
                        Text(verbatim: branch).font(.system(size: Theme.fontSize.footer, design: .monospaced))
                    }
                    .foregroundStyle(Theme.ui.text3)
                }
            }
            .font(.system(size: Theme.fontSize.tabTaskTitle))
            .lineLimit(1)
            .truncationMode(.middle)
            // Clear of the toggles on both sides, so a long title never runs under them.
            .padding(.horizontal, Theme.titlebarToggleX + Theme.titleButtonSize + Theme.titlebarTrailing)
            .offset(y: metrics.offsetY)
            .allowsHitTesting(false)
        }
    }

    private func button(_ icon: Icon, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconView(icon: icon, active: active)
                .frame(width: Theme.titleButtonSize, height: Theme.titleButtonSize)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
    }
}
