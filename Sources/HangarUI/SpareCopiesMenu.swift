import Foundation
import Git
import Workspace

/// «Копии без чата · N» (#133): per copy its place and branch, «Открыть чатом» and «Удалить копию…»; at the end, when
/// copies inside the project are not ignored by git, «Скрыть от git локально…». Nothing runs until an item is clicked.
@MainActor func spareCopiesMenu(_ projectId: UUID, app: AppState, ctx: ActionContext) -> [PopoverMenuEntry] {
    let projectPath = app.project(projectId)?.path
    var entries: [PopoverMenuEntry] = []
    for entry in app.spareWorktrees(of: projectId) {
        if !entries.isEmpty { entries.append(.separator) }
        let place = shortCopyPath(entry.path, project: projectPath)
        entries.append(.header(entry.branch.map { "\(place) · \($0)" } ?? place, mono: entry.branch))
        entries.append(.item(PopoverMenuItem(title: L10n.openCopyAsChat, icon: .add, enabled: entry.branch != nil,
                                             help: entry.branch == nil ? L10n.adoptCopyDetached : entry.path) {
            app.openSpareWorktree(entry, projectId: projectId)
        }))
        entries.append(.item(PopoverMenuItem(title: L10n.removeCopyMenu, icon: .trash, destructive: true, enabled: !entry.locked,
                                             help: entry.locked ? L10n.copyLocked : nil) {
            Task { await removeSpareWorktree(entry, projectId: projectId, ctx: ctx) }
        }))
    }
    if let copies = app.unignoredCopies[projectId] {
        entries.append(.separator)
        entries.append(.item(PopoverMenuItem(title: L10n.hideFromGitMenu,
                                             help: L10n.worktreesNotIgnoredNotice(copies.joined(separator: ", "))) {
            hideWorktreesFromGit(projectId, ctx: ctx)
        }))
    }
    return entries
}
