import AgentStatus
import Git
import SwiftUI
import Workspace

/// Text of the task's status line (spec §4): `⎇ branch` · `+N −M · K files` · host · agent status; nil parts are not shown.
@MainActor struct TaskStatusLine: Equatable {
    var branch: String?
    var changes: String?
    var host: String?
    var agent: String?

    /// `files`: the inspector's loaded changes (nil until loaded); `offline`: the remote host is not connected (counts are stale).
    init(branch: String?, files: [ChangedFile]?, host: String?, offline: Bool, agent: (kind: LeafKind, state: AgentState)?) {
        self.branch = branch.map { "⎇ " + $0 }
        if let files, !files.isEmpty, !(host != nil && offline) {
            let added = files.reduce(0) { $0 + ($1.added ?? 0) }
            let deleted = files.reduce(0) { $0 + ($1.deleted ?? 0) }
            changes = "+\(added) −\(deleted) · \(L10n.fileCount(files.count))"
        }
        self.host = host.map { offline ? L10n.hostOffline($0) : $0 }
        self.agent = agent.map { "\($0.kind.rawValue) · \(L10n.statusLabel($0.state))" }
    }
}

/// The agent whose status the line shows: the active tab's focused pane, if it is an agent. A focused shell or
/// editor shows no agent part (not «claude · неактивен» of some other pane).
nonisolated func statusAgentLeaf(of task: HangarTask) -> Leaf? {
    guard let tab = task.tabs.first(where: { $0.id == task.activeTabId }),
          let focused = tab.root.leaf(id: tab.focusedLeafId), focused.kind == .claude || focused.kind == .codex else { return nil }
    return focused
}

/// Thin footer under the task's terminals (DESIGN.md «Строка состояния»). Always 22 high, so missing parts never move the terminal.
/// Updates only from the inspector's loads and status changes (no polling of its own).
struct TaskStatusBar: View {
    let app: AppState

    var body: some View {
        HStack(spacing: Theme.statusBarGap) {
            if let line {
                if let branch = line.branch { Text(verbatim: branch).truncationMode(.middle) }
                if let changes = line.changes { ChangesCounter(text: changes, action: showChanges) }
                if let host = line.host { Text(verbatim: host).truncationMode(.middle) }
                Spacer(minLength: 0)
                if let agent = line.agent { Text(verbatim: agent).layoutPriority(1) }
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: Theme.fontSize.counter, design: .monospaced))
        .foregroundStyle(Theme.ui.text3)
        .lineLimit(1)
        .padding(.horizontal, Theme.paneHeaderPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.statusBarHeight, maxHeight: Theme.statusBarHeight)
        .background(Theme.ui.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    private var line: TaskStatusLine? {
        guard let task = app.selectedTask else { return nil }
        let model = app.inspector
        let loaded = model.shownTaskId == task.id && model.isGit
        let agent = statusAgentLeaf(of: task).map { (kind: $0.kind, state: app.displayState(ofLeaf: $0.id, kind: $0.kind)) }
        // shortcut: counts are the inspector's, so with it hidden they show only for the task it last loaded; load them there if asked.
        // shortcut: the branch is known only for worktree tasks (a main-folder checkout is not probed); probe in the status load if asked.
        return TaskStatusLine(branch: task.branch, files: loaded ? model.changes?.files : nil,
                              host: app.project(task.projectId)?.host, offline: model.shownTaskId == task.id && model.offline, agent: agent)
    }

    private func showChanges() { app.showInspector(.changes) }
}

/// `+N −M · K файлов`: a link — `text3`, `text2` under the pointer.
private struct ChangesCounter: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(verbatim: text)
            .foregroundStyle(hover ? Theme.ui.text2 : Theme.ui.text3)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .pointingHand()
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            .help(L10n.help(L10n.statusShowChanges, .inspectorChanges))
            .accessibilityAddTraits(.isButton)
    }
}
