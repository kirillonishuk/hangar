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
                }
            }
            .padding(.horizontal, Theme.Space.s3)
            .frame(maxWidth: .infinity, minHeight: Theme.Height.barPane, maxHeight: Theme.Height.barPane)
            .background(Theme.ui.bg1)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        }
    }

    private func text(_ place: WorktreePlace, stored: TaskMode) -> String {
        switch place {
        case .moved(let path): L10n.worktreeMovedTo(abbreviatedHomePath(path))
        default:
            if case .worktree(let path, _, _) = stored { L10n.worktreeNotFound(abbreviatedHomePath(path)) } else { "" }
        }
    }
}
