import AgentStatus
import Foundation
import SwiftUI
import Workspace

/// Agents of a project by displayed state; working agents' running subagents are counted apart (only the tooltip shows them).
/// Agents on a reached limit are `limited`: neither working nor errors. `waiting` is only agents asking something
/// (permission, question): a failure is an error, never «ждёт».
struct StatusCounts: Equatable {
    var working = 0
    var waiting = 0
    var failed = 0
    var subagents = 0
    var limited = 0

    init(working: Int = 0, waiting: Int = 0, failed: Int = 0, subagents: Int = 0, limited: Int = 0) {
        self.working = working
        self.waiting = waiting
        self.failed = failed
        self.subagents = subagents
        self.limited = limited
    }

    init(_ summaries: [(state: AgentState, subagents: Int)]) {
        for s in summaries {
            switch s.state {
            case .working:
                working += 1
                subagents += s.subagents
            case .failed: failed += 1
            case .limit: limited += 1
            case .waiting: waiting += 1
            case .done, .idle: break
            }
        }
    }
}

/// Text of the window status bar (redesign v1 §7). Left: machine · non-zero counts of the selected project (the
/// project itself is in the title). Right: the pane count of a split tab, an editor's language — never what the tab
/// or a pane header already says (no duplicated information, decision #106).
struct StatusBarLine: Equatable {
    /// nil — this Mac.
    var host: String?
    var counts = StatusCounts()
    /// Only for a tab of 2+ panes.
    var panes: Int?
    /// The focused pane is a file tab's editor (#83): its language server status and the minimap switch show.
    var editor: UUID?
    /// The editor's language when no language server reports on it.
    var language: String?
    /// Agent leaves counted as errors, in sidebar order: the counter's click shows the first (`revealFailed`).
    var failedLeaves: [UUID] = []

    var remote: Bool { host != nil }
    @MainActor var left: [String] { [host ?? L10n.thisMac] }
    @MainActor var workingText: String? { counts.working > 0 ? L10n.workingCount(counts.working) : nil }
    /// «Следующая работающая сессия · 3 субагента» — subagents only when there are any.
    @MainActor var workingHelp: String {
        [L10n.statusNextWorkingHelp, counts.subagents > 0 ? L10n.subagentCount(counts.subagents) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    @MainActor var waitingText: String? { counts.waiting > 0 ? L10n.inboxCount(counts.waiting) : nil }
    @MainActor var failedText: String? { counts.failed > 0 ? L10n.failedCount(counts.failed) : nil }
    @MainActor var limitedText: String? { counts.limited > 0 ? L10n.limitedCount(counts.limited) : nil }
    @MainActor var right: String? { panes.map(L10n.paneCount) }
}

private func leaves(of task: HangarTask) -> [Leaf] {
    task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
}

/// The line for the selected session: `summary` gives a leaf's agent state and subagents, `language` an editor
/// leaf's language name.
func statusBarLine(_ s: WorkspaceState, summary: (Leaf) -> (state: AgentState, subagents: Int),
                   language: (Leaf) -> String?) -> StatusBarLine {
    guard let id = s.selectedTaskId, let task = s.tasks.first(where: { $0.id == id && !$0.archived }) else { return StatusBarLine() }
    let project = s.projects.first { $0.id == task.projectId }
    let siblings = s.tasks.filter { $0.projectId == task.projectId && !$0.archived }
    let tab = task.tabs.first { $0.id == task.activeTabId }
    let focused = tab.flatMap { $0.root.leaf(id: $0.focusedLeafId) }
    let panes = tab?.root.leaves.count ?? 0
    let editor = focused?.kind == .editor ? focused : nil
    // A shell's non-zero exit (`npm test`, Ctrl-C, ssh 255 when a host terminal drops) keeps just its tab's dot.
    let summaries = siblings.flatMap(leaves).map { leaf in
        var s = summary(leaf)
        if s.state == .failed, leaf.kind != .claude, leaf.kind != .codex { s.state = .idle }
        return (leaf: leaf.id, summary: s)
    }
    return StatusBarLine(host: project?.host ?? s.hostShell(ofTask: id)?.host,
                         counts: StatusCounts(summaries.map(\.summary)),
                         panes: panes > 1 ? panes : nil, editor: editor?.id, language: editor.flatMap(language),
                         failedLeaves: summaries.filter { $0.summary.state == .failed }.map(\.leaf))
}

/// The first id after `after` (wrapping) that is in `working`.
func nextWorking(_ ids: [UUID], working: Set<UUID>, after: UUID?) -> UUID? {
    let start = after.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    return (0..<ids.count).lazy.map { ids[(start + $0) % ids.count] }.first { working.contains($0) }
}

extension AppState {
    var statusBar: StatusBarLine {
        // The rows' state (a reached limit included), so the bar and the sidebar agree.
        var line = statusBarLine(state, summary: { (displayState(ofLeaf: $0.id, kind: $0.kind), statusSummary(ofLeaf: $0.id).subagents) },
                                 language: editorStatusLabel)
        // Sessions (⌘Y) and the diff tab cover the tabs: their pane count and editor mean nothing there.
        if sessionsViewVisible || activeDiff != nil { line.panes = nil; line.editor = nil; line.language = nil }
        return line
    }

    /// «● N ошибка»: shows the first failed agent's session and tab, and the inbox, which says what failed.
    func revealFailed() {
        guard let leaf = statusBar.failedLeaves.first else { return }
        reveal(leafId: leaf)
        if !inboxShown { toggleInbox() }
    }

    /// «N ждёт внимания»: the project's next agent asking something (after the focused one, wrapping), as
    /// «N работает» goes to the next working session — the counter is this project's, so is the jump.
    func revealNextWaiting() {
        guard let task = selectedTask else { return }
        let all = state.tasks(in: task.projectId).flatMap(leaves)
        let waiting = Set(all.filter { displayState(ofLeaf: $0.id, kind: $0.kind) == .waiting }.map(\.id))
        let focused = task.tabs.first { $0.id == task.activeTabId }?.focusedLeafId
        if let next = nextWorking(all.map(\.id), working: waiting, after: focused) { reveal(leafId: next) }
    }

    /// «N работает»: the project's next session with a working agent.
    func selectNextWorking() {
        guard let task = selectedTask else { return }
        let tasks = state.tasks(in: task.projectId)
        let working = Set(tasks.filter { leaves(of: $0).contains { displayState(ofLeaf: $0.id, kind: $0.kind) == .working } }.map(\.id))
        if let next = nextWorking(tasks.map(\.id), working: working, after: task.id), next != task.id { select(taskId: next) }
    }
}

/// The active file's language (the ones with a language server), else nothing: «Редактор» would repeat the tab.
@MainActor func editorStatusLabel(_ leaf: Leaf) -> String? {
    switch leaf.openFile.flatMap(TsMap.scriptKind) {
    case "TS", "TSX": "TypeScript"
    case "JS", "JSX": "JavaScript"
    default: leaf.openFile.flatMap(LspLanguage.of)?.name
    }
}

/// 24 high across the window bottom, always (no session → only «Этот Mac»), so nothing above it moves.
/// Redrawn by observation on status / selection changes only (no timers).
struct WindowStatusBar: View {
    let app: AppState

    var body: some View {
        let line = app.statusBar
        // One rule: items are apart by the gap, no «·»; hints are `text3`, clickable counters `text2` with a hover fill.
        HStack(spacing: Theme.statusBarGap) {
            HStack(spacing: Theme.inlineGap) {
                if line.remote { IconView(icon: .sshHost, size: Theme.titleBranchIcon) }
                Text(verbatim: line.host ?? L10n.thisMac).truncationMode(.middle)
            }
            .foregroundStyle(Theme.ui.text3)
            .modifier(StatusItem())
            .help(L10n.statusMachineHelp)
            if let text = line.workingText {
                StatusButton(help: line.workingHelp, action: app.selectNextWorking) {
                    StatusDot(state: .working)
                    Text(verbatim: text)
                }
            }
            if let text = line.waitingText {
                StatusButton(help: L10n.statusNextWaitingHelp, action: app.revealNextWaiting) {
                    StatusDot(state: .waiting)
                    Text(verbatim: text)
                }
            }
            if let text = line.limitedText {
                HStack(spacing: Theme.inlineGap) {
                    StatusDot(state: .limit)
                    Text(verbatim: text)
                }
                .modifier(StatusItem())
            }
            if let text = line.failedText {
                StatusButton(help: L10n.statusFailedHelp, tint: Theme.ui.failed, action: app.revealFailed) {
                    StatusDot(state: .failed)
                    Text(verbatim: text)
                }
            }
            Spacer(minLength: 0)
            // «Доступна 0.3.0» (#86): right edge, only while there is an offer; opens the update sheet.
            if let offer = app.updates.pill {
                Button { app.updates.onShow?() } label: {
                    Pill(text: L10n.updateAvailable(offer.version), color: Theme.ui.accentText)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help(L10n.updateAvailableHelp)
                .modifier(StatusItem())
            }
            // ☕ only while sleep is held (the setting is in Settings → Уведомления); right edge, so nothing shifts.
            let keep = app.keepAwake
            if showsKeepAwake(enabled: app.config.keepAwake, held: keep.held) {
                IconView(icon: .keepAwake, size: Theme.rowStatusIcon, tint: Theme.ui.accentText)
                    .modifier(StatusItem())
                    .help(L10n.keepAwakeHelp(enabled: true, held: true, working: keep.working))
                    .accessibilityLabel(L10n.keepAwakeTitle)
            }
            if let panes = line.right {
                Text(verbatim: panes).foregroundStyle(Theme.ui.text3).modifier(StatusItem()).help(L10n.statusPanesHelp)
            }
            if let editor = line.editor {
                // VS Code's status bar: the language server's state (a click restarts it; the reason is in the
                // tooltip), else just the language; then the minimap switch, lit while on.
                if let lang = app.editorLanguage[editor] {
                    StatusButton(help: lang.tooltip, action: { app.restartLanguage(leafId: editor) }) {
                        Circle().fill(lang.level == .ready ? Theme.ui.done : lang.level == .busy ? Theme.ui.waiting : Theme.ui.text3)
                            .frame(width: Theme.statusDot, height: Theme.statusDot)
                        Text(verbatim: lang.text)
                    }
                } else if let language = line.language {
                    Text(verbatim: language).foregroundStyle(Theme.ui.text3).modifier(StatusItem())
                }
                let minimap = app.state.editorMinimap
                StatusButton(help: L10n.editorMinimap, on: minimap, action: { app.perform { $0.editorMinimap.toggle() } }) {
                    Text(verbatim: L10n.editorMinimap)
                }
            }
        }
        .font(.system(size: Theme.fontSize.footer))
        .foregroundStyle(Theme.ui.text2)
        .lineLimit(1)
        .padding(.horizontal, Theme.statusBarPaddingH - Theme.statusItemPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.statusBarHeight, maxHeight: Theme.statusBarHeight)
        .background(Theme.ui.bg1)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

}

/// Item box: 20 high, padding 4 (clickable ones get the `hover` fill in it, radius 4).
private struct StatusItem: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, Theme.statusItemPaddingH).frame(height: Theme.statusItemHeight)
    }
}

/// A clickable status item; `on` (a switch that is on) is drawn as a lit mode chip: `accent` 14 % and `accentText`.
private struct StatusButton<Label: View>: View {
    let help: String
    var on = false
    /// Text colour at rest (the error counter is `failed`); default `text2`.
    var tint: Color?
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.inlineGap) { label }
                .foregroundStyle(on ? Theme.ui.accentText : tint ?? Theme.ui.text2)
                .modifier(StatusItem())
                .background(on ? Theme.ui.accent.opacity(Theme.Opacity.fill) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.statusItemRadius))
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.statusItemRadius))
        .help(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The status bar's ☕: only while the sleep assertion is actually held for working agents.
func showsKeepAwake(enabled: Bool, held: Bool) -> Bool { enabled && held }
