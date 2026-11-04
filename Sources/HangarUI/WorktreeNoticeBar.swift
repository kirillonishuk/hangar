import Git
import SwiftUI
import Workspace

/// Over the selected chat's terminals when its copy is not where the chat thinks (#122): «Копия перенесена в … ·
/// Обновить путь» or «Копия не найдена: …». A `barPane` row (§2.4) like the pane header; hidden otherwise (height 0).
struct WorktreeNoticeBar: View {
    let app: AppState

    var body: some View {
        if let problem = app.selectedWorktreeProblem {
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: .alert, size: Theme.Icon.row, tint: Theme.ui.waiting)
                Text(verbatim: text(problem.place, stored: problem.task.mode))
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s2)
                if case .moved = problem.place {
                    Button(L10n.relinkWorktree) { app.relinkWorktree(problem.task.id) }
                        .buttonStyle(.hangar(.secondary, .small))
                        .fixedSize()
                        .help(L10n.relinkWorktreeHelp)
                }
            }
            .modifier(NoticeRow())
        } else if let elsewhere = app.selectedAgentElsewhere {
            agentBar(elsewhere.task, elsewhere.entry)
        }
    }

    /// The agent entered another worktree of the project itself (#134): informational, so no warning colour; the
    /// action only re-points the chat, «Скрыть» hides it for this chat and copy.
    private func agentBar(_ task: HangarTask, _ entry: WorktreeEntry) -> some View {
        let shown = shortCopyPath(entry.path, project: app.project(task.projectId)?.path)
        let text = L10n.agentInCopy(shown, branch: entry.branch)
        return HStack(spacing: Theme.Space.iconGap) {
            IconView(icon: .branch, size: Theme.Icon.row, tint: Theme.ui.text2)
            Text(monoSpan(text, span: entry.branch, font: Theme.Typography.secondary.font(), mono: Theme.Typography.monoSmall.font()))
                .foregroundStyle(Theme.ui.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)
            Spacer(minLength: Theme.Space.s2)
            Button(L10n.adoptCopy) { app.adoptAgentWorktree(task.id) }
                .buttonStyle(.hangar(.secondary, .small))
                .fixedSize()
                .disabled(entry.branch == nil)
                .help(entry.branch == nil ? L10n.adoptCopyDetached : L10n.adoptCopyHelp)
            Button(L10n.hideAgentBar) { app.hideAgentPlace(task.id) }
                .buttonStyle(.hangar(.plain, .small))
                .fixedSize()
        }
        .modifier(NoticeRow())
    }

    private func text(_ place: WorktreePlace, stored: TaskMode) -> String {
        switch place {
        case .moved(let path): L10n.worktreeMovedTo(abbreviatedHomePath(path))
        default:
            if case .worktree(let path, _, _) = stored { L10n.worktreeNotFound(abbreviatedHomePath(path)) } else { "" }
        }
    }
}

/// The row's frame: a `barPane` strip over the terminals, `bg1`, a line under it.
private struct NoticeRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Space.s3)
            .frame(maxWidth: .infinity, minHeight: Theme.Height.barPane, maxHeight: Theme.Height.barPane)
            .background(Theme.ui.bg1)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }
}

/// A copy inside the project as `.claude/worktrees/x`; elsewhere with `~`.
func shortCopyPath(_ path: String, project: String?) -> String {
    // git lists real paths (`/private/tmp/…`); the project may be stored through a symlink.
    for root in [project, project.map(realPath)].compactMap({ $0 }) where path.hasPrefix(root + "/") {
        return String(path.dropFirst(root.count + 1))
    }
    return abbreviatedHomePath(path)
}
