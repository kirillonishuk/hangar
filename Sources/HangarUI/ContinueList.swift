import History
import SwiftUI
import Workspace

/// «Продолжить»: the latest conversations of a session's folder, shown by an empty session and a chooser pane.
/// Newest first, without those running in a tab and those of a deeper folder that has its own project or session.
func recentConversations(_ list: [Conversation], inner: [String], open: Set<String>, limit: Int = Theme.continueRows) -> [Conversation] {
    let inside = { (cwd: String) in inner.contains { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    return Array(list.filter { !open.contains($0.id) && !inside($0.cwd) }
        .sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
        .prefix(limit))
}

extension AppState {
    /// The session's folder; a host's terminal (#64) has none.
    func recentFolder(of taskId: UUID) -> String? { isHostShellTask(taskId) ? nil : path(of: .task(taskId)) }

    private func recentKey(_ taskId: UUID) -> (key: String, folder: String, project: Project)? {
        guard let folder = recentFolder(of: taskId), let task = state.tasks.first(where: { $0.id == taskId }),
              let project = project(task.projectId) else { return nil }
        return ((project.host ?? "") + ":" + folder, folder, project)
    }

    /// From the last scan (nothing before the first one).
    func recent(for taskId: UUID) -> [Conversation] {
        guard let (key, folder, project) = recentKey(taskId) else { return [] }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let inner = (state.projects.filter { $0.host == project.host }.map(\.path) + sessionFolders(project.id)).filter { $0.hasPrefix(prefix) }
        return recentConversations(recentByFolder[key] ?? [], inner: inner, open: openConversationIds)
    }

    /// The session's machine can be read now: this Mac, or its ssh host while connected (observed: the list loads on connect).
    func recentHostOnline(_ taskId: UUID) -> Bool {
        guard let project = recentKey(taskId)?.project, let host = project.host else { return true }
        return remote.hosts[host]?.state == .connected
    }

    /// Rescans when the view appears (no watchers); the History module re-reads only changed files. A remote project reads
    /// through its connected host (the same path as «Сессии»); while it is not connected the view shows only the buttons.
    // shortcut: every chooser / empty-session appearance rescans (a directory listing + stat per file, parsed only when changed);
    // add a freshness window if ⌘D on a huge history ever shows up in a profile.
    func loadRecent(taskId: UUID) async {
        guard let (key, folder, project) = recentKey(taskId), recentHostOnline(taskId) else { return }
        guard let list = try? await conversations(folder: folder, project: project) else { return }
        // shortcut: only the newest are kept; a folder whose newest dozens all run in tabs shows fewer — keep more if that happens.
        let kept = Array(list.prefix(Theme.continueKept))
        if recentByFolder[key] != kept { recentByFolder[key] = kept }
    }
}

/// «Продолжить» header and its rows; empty (no space taken) without conversations. A click resumes the conversation.
struct ContinueList: View {
    let app: AppState
    let taskId: UUID
    let resume: (Conversation) -> Void
    @State private var hovered: String?

    /// A host coming online loads the list again.
    private struct Load: Hashable {
        let task: UUID
        let online: Bool
    }

    var body: some View {
        let rows = app.recent(for: taskId)
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                Text(L10n.continueTitle)
                    .font(.system(size: Theme.fontSize.footer, weight: .semibold))
                    .foregroundStyle(Theme.ui.text3)
                    .padding(.horizontal, Theme.historyRowPaddingH)
                    .padding(.bottom, Theme.historyGroupBottom)
                ForEach(rows) { row($0) }
            }
        }
        .frame(width: Theme.continueWidth)
        .task(id: Load(task: taskId, online: app.recentHostOnline(taskId))) { await app.loadRecent(taskId: taskId) }
    }

    private func row(_ c: Conversation) -> some View {
        let key = c.agent.rawValue + ":" + c.id
        let title = c.title ?? L10n.sessionsUntitled
        return HStack(spacing: Theme.historyRowGap) {
            IconView(icon: c.agent == .claude ? .claude : .codex)
            Text(title).foregroundStyle(Theme.ui.text).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(relativeTime(c.lastActivity)).font(.system(size: Theme.fontSize.footer)).foregroundStyle(Theme.ui.text3).lineLimit(1).fixedSize()
        }
        .font(.system(size: Theme.fontSize.base))
        .padding(.horizontal, Theme.historyRowPaddingH)
        .frame(height: Theme.continueRowHeight)
        .background(hovered == key ? Theme.ui.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.historyRowRadius))
        .contentShape(Rectangle())
        .onTapGesture { resume(c) }
        .onHover { inside in
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
        .pointingHand()
        .help(title)
    }

    /// «5 мин назад», «вчера»: as of this render (no ticking clock).
    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10n.resolve(L10n.language).rawValue)
        f.unitsStyle = .short
        return f.localizedString(for: min(d, Date()), relativeTo: Date())
    }
}
