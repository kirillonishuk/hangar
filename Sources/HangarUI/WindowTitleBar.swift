import AgentStatus
import AppKit
import Observation
import SwiftUI
import Workspace

/// The toolbar's title (design system §3.1): the chat's name over its project; a remote one is «devbox · acme-web»,
/// a host's terminal has only its own name («devbox · терминал»).
struct WindowTitle: Equatable {
    var title: String
    var subtitle: String?
}

/// Title of the selected chat; nil when none is selected.
@MainActor func windowTitle(_ s: WorkspaceState) -> WindowTitle? {
    guard let id = s.selectedTaskId, let task = s.tasks.first(where: { $0.id == id && !$0.archived }) else { return nil }
    if let host = s.hostShell(ofTask: id)?.host { return WindowTitle(title: L10n.hostTerminal(host)) }
    let project = s.projects.first { $0.id == task.projectId }
    return WindowTitle(title: task.name, subtitle: project.map { p in p.host.map { "\($0) · \(p.name)" } ?? p.name })
}

/// Where the toolbar's parts go: the traffic lights (read from the real buttons) and the content column's left edge.
@MainActor @Observable final class TitleBarMetrics {
    /// Centre of the traffic lights, down from the top of the window, and their right edge; nil while they are hidden
    /// (full screen).
    var lightsCenterY: CGFloat?
    var lightsMaxX: CGFloat = 0
    /// Left edge of the chat column (the sidebar and its divider are left of it), live while the sidebar moves.
    var contentX: CGFloat = 0

    /// Shift from the bar's own middle to the traffic lights' centre line (0 when there are none).
    var offsetY: CGFloat { titlebarOffset(lightsCenterY: lightsCenterY, barHeight: Theme.Height.barToolbar) }

    func update(from window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton), !close.isHidden, let content = window.contentView else {
            lightsCenterY = nil
            return
        }
        let r = content.convert(close.convert(close.bounds, to: nil), from: nil)
        let c = content.isFlipped ? r.midY : content.bounds.height - r.midY
        let maxX = content.convert(zoom.convert(zoom.bounds, to: nil), from: nil).maxX
        if lightsCenterY != c { lightsCenterY = c }
        if lightsMaxX != maxX { lightsMaxX = maxX }
    }
}

func titlebarOffset(lightsCenterY: CGFloat?, barHeight: CGFloat) -> CGFloat {
    lightsCenterY.map { $0 - barHeight / 2 } ?? 0
}

/// x of the sidebar toggle and of the toolbar's content: the toggle sits at the sidebar's right edge (16 in), and
/// never under the traffic lights (a collapsed rail is narrower than they are); the content starts 16 right of the
/// column's edge, or of the toggle when that sticks out of the rail.
func toolbarLayout(contentX: CGFloat, lightsMaxX: CGFloat?) -> (toggleX: CGFloat, titleX: CGFloat) {
    let button = Theme.Height.controlRegular
    let minX = lightsMaxX.map { $0 + Theme.Space.s3 } ?? Theme.Space.s2
    let toggleX = max(contentX - Theme.Space.s4 - button, minX)
    return (toggleX, max(contentX, toggleX + button) + Theme.Space.s4)
}

/// Toolbar 52 (design system §3.1) across the window, over the top of the split: left of the chat column it is
/// the sidebar's head (traffic lights, the sidebar toggle) and draws nothing, so the sidebar shows through; from the
/// column on: the chat's name and project, its branch, then on the right «Обновить до X» and «не спать» while they
/// apply, the bell and the inspector toggle. Empty space drags the window; double-click follows the system setting.
struct WindowTitleBar: View {
    let app: AppState
    let metrics: TitleBarMetrics
    let inboxAction: InboxAction
    let toggleSidebar: () -> Void

    var body: some View {
        let collapsed = app.state.sidebarCollapsed
        let layout = toolbarLayout(contentX: metrics.contentX, lightsMaxX: metrics.lightsCenterY == nil ? nil : metrics.lightsMaxX)
        // Collapsed, the lights stick out of the rail: the bar runs under them, across the rail.
        let barX = collapsed ? 0 : metrics.contentX
        ZStack(alignment: .leading) {
            Theme.ui.bg1
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
                .padding(.leading, barX)
            IconButton(icon: .sidebarLeft, size: .regular,
                       help: L10n.help(collapsed ? L10n.expandSidebarHelp : L10n.collapseSidebarHelp, .toggleSidebar),
                       action: toggleSidebar)
                .padding(.leading, layout.toggleX)
                .offset(y: metrics.offsetY)
            HStack(spacing: Theme.Space.s2) {
                title
                Spacer(minLength: 0)
                trailing
            }
            .padding(.leading, layout.titleX)
            .padding(.trailing, Theme.Space.s3)
            .offset(y: metrics.offsetY)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Height.barToolbar, maxHeight: Theme.Height.barToolbar)
        .background(WindowDragArea())
        .ignoresSafeArea()
    }

    @ViewBuilder private var title: some View {
        if let t = windowTitle(app.state) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: t.title)
                    .font(Theme.Typography.body.font(.semibold))
                    .foregroundStyle(Theme.ui.text0)
                if let subtitle = t.subtitle {
                    Text(verbatim: subtitle)
                        .font(Theme.Typography.caption.font())
                        .foregroundStyle(Theme.ui.text2)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.trailing, Theme.Space.s1)
            .allowsHitTesting(false)
            if let task = app.selectedTask, !app.isHostShellTask(task.id), let branch = app.head(of: task)?.title ?? task.branch {
                BranchButton(app: app, task: task, branch: branch)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        // «Обновить до 0.9.0» (#86): only while there is an offer; opens the update sheet.
        if let offer = app.updates.pill {
            Button { app.updates.onShow?() } label: {
                Text(verbatim: L10n.updateTo(offer.version))
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.accentText)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.s2)
                    .frame(height: Theme.Height.controlSmall)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.ui.accent.opacity(Theme.Opacity.fill)))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help(L10n.updateAvailableHelp)
        }
        // «Не спать» only while sleep is held (the setting is in Settings → Уведомления).
        let keep = app.keepAwake
        if showsKeepAwake(enabled: app.config.keepAwake, held: keep.held) {
            IconView(icon: .keepAwake, size: Theme.Icon.toolbar)
                .frame(width: Theme.Height.controlRegular, height: Theme.Height.controlRegular)
                .help(L10n.keepAwakeHelp(enabled: true, held: true, working: keep.working))
                .accessibilityLabel(L10n.keepAwakeTitle)
        }
        InboxBell(app: app, act: inboxAction)
        IconButton(icon: .sidebarRight, size: .regular, help: L10n.help(L10n.inspectorHelp, .toggleInspector)) {
            app.perform { $0.inspectorVisible.toggle() }
        }
    }
}

/// The toolbar's «не спать»: only while the sleep assertion is actually held for working agents.
func showsKeepAwake(enabled: Bool, held: Bool) -> Bool { enabled && held }

/// The chat's live HEAD (branch, or short hash when detached), `mono` 12 in a 28 box with a `line2` border; opens the
/// branch switcher (spec §3.2) under itself, with the `accent` border and ring while it is open.
private struct BranchButton: View {
    let app: AppState
    let task: HangarTask
    let branch: String
    @State private var hover = false
    @State private var open = false
    @State private var anchor = MenuAnchor()

    private func show() {
        open = true
        showBranchSwitcher(app: app, task: task, below: anchor.view) { open = false }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        Button(action: show) {
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: .branch, size: Theme.Icon.row)
                Text(verbatim: branch)
                    .font(Theme.Typography.mono.font())
                    .foregroundStyle(Theme.ui.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                IconView(icon: .chevronDown, size: Theme.Icon.inline)
            }
            .padding(.leading, Theme.Space.s2)
            .padding(.trailing, Theme.Space.iconGap)
            .frame(height: Theme.Height.controlRegular)
            .background(shape.fill(hover ? Theme.ui.hover : .clear))
            .overlay(shape.strokeBorder(open ? Theme.ui.accent : Theme.ui.line2, lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control + Theme.Control.ringWidth)
                .fill(Theme.ui.accent.opacity(open ? Theme.Opacity.ring : 0))
                .padding(-Theme.Control.ringWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hover = $0 }
        .pointingHand()
        .help(L10n.gitBranch)
        .accessibilityLabel("\(L10n.gitBranch) \(branch)")
        .accessibilityHint(L10n.branchSwitchHint)
        #if DEBUG
        .onAppear { debugBranchOpen = show }
        .onChange(of: task.id) { debugBranchOpen = show }
        #endif
    }
}

#if DEBUG
/// Debug channel `branchMenu`: as a click on the toolbar's branch button.
@MainActor var debugBranchOpen: (() -> Void)?
#endif

/// The bell (§3.1, §3.16): 16 in a 28 box; the count of what waits (permission, question, error — the Dock's number)
/// is a red 14 badge on its corner. Opens the inbox.
struct InboxBell: View {
    let app: AppState
    let act: InboxAction

    var body: some View {
        let count = attentionCount(app.attentionItems)
        Button { app.inboxClicked() } label: {
            IconView(icon: .bell, size: Theme.Icon.toolbar)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(verbatim: count > 99 ? "99+" : "\(count)")
                            .font(Theme.Typography.caption.font(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.ui.onAccent)
                            .padding(.horizontal, Theme.Space.s1)
                            .frame(minWidth: Theme.Inbox.badge, minHeight: Theme.Inbox.badge, maxHeight: Theme.Inbox.badge)
                            .background(Capsule().fill(Theme.ui.failed))
                            .fixedSize()
                            .offset(x: Theme.Space.iconGap, y: -Theme.Space.s1)
                    }
                }
        }
        .buttonStyle(IconButtonStyle(size: .regular))
        .help(L10n.inbox)
        .accessibilityLabel(count > 0 ? "\(L10n.inbox), \(count)" : L10n.inbox)
        .popover(isPresented: Binding(get: { app.inboxShown }, set: { app.setInboxShown($0) }), arrowEdge: .bottom) {
            InboxPopover(app: app, act: act)
        }
    }
}
