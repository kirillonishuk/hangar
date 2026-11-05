import AgentStatus
import SwiftUI
import Workspace

/// A chat's Claude subagents under its row (spec agent-subagents §4): one folded line «3 субагента · 1 работает» with a
/// disclosure triangle in the dot column, unfolded — one row per subagent (dot, task, time). Nothing in the rail, nothing
/// without subagents. Times are recomputed on redraw (minutes), no timer.
struct SidebarSubagents: View {
    let app: AppState
    let task: HangarTask
    /// The chat row's own: its marker offset and where its name starts.
    let indent: CGFloat
    let textX: CGFloat
    let collapsed: Bool
    let open: (UUID, String) -> Void

    var body: some View {
        let rows = collapsed ? [] : app.subagentRows(of: task)
        if !rows.isEmpty {
            let expanded = app.subagentsExpanded.contains(task.id)
            let running = rows.filter { $0.item.state == .running }.count
            let help = expanded ? L10n.subagentsHide : L10n.subagentsShow
            HoverRow(action: { app.toggleSubagents(task.id) }) { _ in
                GutterRow(collapsed: false, textX: textX, indent: indent + Theme.subChatIndent, trailing: Theme.sessionRowTrailing) {
                    IconView(icon: expanded ? .chevronDown : .chevronRight, size: Theme.Icon.inline, tint: Theme.ui.text3)
                } expanded: {
                    Text(verbatim: L10n.subagentsCounter(rows.count, running: running))
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(Theme.ui.text2)
                        .lineLimit(1)
                } rail: { EmptyView() }
            }
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(help)
            if expanded {
                let now = Date()
                ForEach(rows, id: \.item.id) { row in item(row.item, leaf: row.leaf, now: now) }
            }
        }
    }

    private func item(_ s: Subagent, leaf: UUID, now: Date) -> some View {
        let elapsed = L10n.subagentElapsed(s.elapsed(now: now))
        let label = L10n.subagentRow(s.title, s.type, L10n.subagentState(s.state), elapsed)
        return HoverRow(action: { open(leaf, s.id) }) { _ in
            GutterRow(collapsed: false, textX: textX, indent: indent + Theme.subChatIndent, trailing: Theme.sessionRowTrailing) {
                StatusDot(state: s.dotState, seen: s.dotSeen)
            } expanded: {
                HStack(spacing: Theme.rowEndGap) {
                    Text(verbatim: s.title).lineLimit(1).truncationMode(.tail).foregroundStyle(Theme.ui.text1)
                    Spacer(minLength: 0)
                    Text(verbatim: elapsed)
                        .font(Theme.Typography.caption.font())
                        .foregroundStyle(Theme.ui.text3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            } rail: { EmptyView() }
        }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}
