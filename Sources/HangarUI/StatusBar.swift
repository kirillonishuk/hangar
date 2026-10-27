import AgentStatus
import Foundation
import SwiftUI
import Workspace

/// Agents of a project by displayed state; working agents' running subagents are counted apart (only the tooltip shows them).
/// Agents on a reached limit are `limited`: neither working nor errors.
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
            case .waiting: waiting += 1
            case .failed: failed += 1
            case .limit: limited += 1
            case .done, .idle: break
            }
        }
    }
}

/// Text of the window status bar (redesign v1 §7). Left: machine · project · non-zero counts of the project;
/// right: the active tab's pane count · the focused pane's process.
struct StatusBarLine: Equatable {
    /// nil — this Mac.
    var host: String?
    var project: String?
    var counts = StatusCounts()
    var panes: Int?
    var process: String?
    /// The focused pane is a file tab's editor (#83): its tsserver status and the minimap switch show.
    var editor: UUID?

    var remote: Bool { host != nil }
    @MainActor var left: [String] { [host ?? L10n.thisMac] + [project].compactMap { $0 } }
    @MainActor var workingText: String? { counts.working > 0 ? L10n.workingCount(counts.working) : nil }
    /// «Следующая работающая сессия · 3 субагента» — subagents only when there are any.
    @MainActor var workingHelp: String {
        [L10n.statusNextWorkingHelp, counts.subagents > 0 ? L10n.subagentCount(counts.subagents) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    @MainActor var waitingText: String? { counts.waiting > 0 ? L10n.waitingCount(counts.waiting) : nil }
    @MainActor var failedText: String? { counts.failed > 0 ? L10n.failedCount(counts.failed) : nil }
    @MainActor var limitedText: String? { counts.limited > 0 ? L10n.limitedCount(counts.limited) : nil }
    @MainActor var right: String? {
        guard let panes else { return nil }
        return [L10n.paneCount(panes), process].compactMap { $0 }.joined(separator: " · ")
    }
}

private func leaves(of task: HangarTask) -> [Leaf] {
    task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
}

/// The line for the selected session: `summary` gives a leaf's agent state and subagents, `process` its name.
func statusBarLine(_ s: WorkspaceState, summary: (Leaf) -> (state: AgentState, subagents: Int),
                   process: (Leaf) -> String) -> StatusBarLine {
    guard let id = s.selectedTaskId, let task = s.tasks.first(where: { $0.id == id && !$0.archived }) else { return StatusBarLine() }
    let project = s.projects.first { $0.id == task.projectId }
    let siblings = s.tasks.filter { $0.projectId == task.projectId && !$0.archived }
    let tab = task.tabs.first { $0.id == task.activeTabId }
    let focused = tab.flatMap { $0.root.leaf(id: $0.focusedLeafId) }
    return StatusBarLine(host: project?.host ?? s.hostShell(ofTask: id)?.host, project: project?.name,
                         counts: StatusCounts(siblings.flatMap(leaves).map(summary)),
                         panes: tab?.root.leaves.count, process: focused.map(process),
                         editor: focused?.kind == .editor ? focused?.id : nil)
}

/// The first id after `after` (wrapping) that is in `working`.
func nextWorking(_ ids: [UUID], working: Set<UUID>, after: UUID?) -> UUID? {
    let start = after.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    return (0..<ids.count).lazy.map { ids[(start + $0) % ids.count] }.first { working.contains($0) }
}

extension AppState {
    var statusBar: StatusBarLine {
        // The rows' state (a reached limit included), so the bar and the sidebar agree.
        statusBarLine(state, summary: { (displayState(ofLeaf: $0.id, kind: $0.kind), statusSummary(ofLeaf: $0.id).subagents) },
                      process: { $0.kind == .editor ? editorStatusLabel($0) : defaultTitle($0.kind) })
    }

    /// «N работает»: the project's next session with a working agent.
    func selectNextWorking() {
        guard let task = selectedTask else { return }
        let tasks = state.tasks(in: task.projectId)
        let working = Set(tasks.filter { leaves(of: $0).contains { displayState(ofLeaf: $0.id, kind: $0.kind) == .working } }.map(\.id))
        if let next = nextWorking(tasks.map(\.id), working: working, after: task.id), next != task.id { select(taskId: next) }
    }
}

/// An editor has no terminal process: the active file's language (the ones with a language server), else «Editor».
@MainActor func editorStatusLabel(_ leaf: Leaf) -> String {
    switch leaf.openFile.flatMap(TsMap.scriptKind) {
    case "TS", "TSX": "TypeScript"
    case "JS", "JSX": "JavaScript"
    default: leaf.openFile.flatMap(LspLanguage.of)?.name ?? L10n.editor
    }
}

/// 24 high across the window bottom, always (no session → only «Этот Mac»), so nothing above it moves.
/// Redrawn by observation on status / selection changes only (no timers).
struct WindowStatusBar: View {
    let app: AppState

    var body: some View {
        let line = app.statusBar
        HStack(spacing: Theme.statusBarGap) {
            HStack(spacing: Theme.inlineGap) {
                if line.remote { IconView(icon: .sshHost, size: Theme.titleBranchIcon) }
                Text(verbatim: line.host ?? L10n.thisMac).truncationMode(.middle)
            }
            .modifier(StatusItem())
            .help(L10n.statusMachineHelp)
            if let project = line.project {
                separator
                Text(verbatim: project).truncationMode(.middle).modifier(StatusItem())
            }
            if line.workingText != nil || line.waitingText != nil || line.limitedText != nil || line.failedText != nil { separator }
            if let text = line.workingText {
                StatusButton(help: line.workingHelp, action: app.selectNextWorking) {
                    StatusDot(state: .working)
                    Text(verbatim: text)
                }
            }
            if let text = line.waitingText {
                StatusButton(help: L10n.help(L10n.inbox, .nextAttention), action: app.inboxClicked) {
                    Circle().strokeBorder(Theme.ui.waiting, lineWidth: Theme.statusRingWidth)
                        .frame(width: Theme.statusDot, height: Theme.statusDot)
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
                HStack(spacing: Theme.inlineGap) {
                    StatusDot(state: .failed)
                    Text(verbatim: text)
                }
                .foregroundStyle(Theme.ui.failed)
                .modifier(StatusItem())
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
            if let panes = line.panes {
                Text(verbatim: L10n.paneCount(panes)).modifier(StatusItem()).help(L10n.statusPanesHelp)
                if let process = line.process {
                    separator
                    Text(verbatim: process).font(.system(size: Theme.fontSize.footer, design: .monospaced)).modifier(StatusItem())
                }
                if let editor = line.editor {
                    // VS Code's status bar: the language server's state (a click restarts it) and the minimap.
                    if let lang = app.editorLanguage[editor] {
                        StatusButton(help: lang.tooltip, action: { app.restartLanguage(leafId: editor) }) {
                            Circle().fill(lang.level == .ready ? Theme.ui.done : lang.level == .busy ? Theme.ui.waiting : Theme.ui.text3)
                                .frame(width: Theme.statusDot, height: Theme.statusDot)
                            Text(verbatim: lang.text)
                        }
                    }
                    StatusButton(help: L10n.editorMinimap, action: { app.perform { $0.editorMinimap.toggle() } }) {
                        Text(verbatim: L10n.editorMinimap).foregroundStyle(app.state.editorMinimap ? Theme.ui.accentText : Theme.ui.text2)
                    }
                }
            }
        }
        .font(.system(size: Theme.fontSize.footer))
        .foregroundStyle(Theme.ui.text2)
        .lineLimit(1)
        .padding(.horizontal, Theme.statusBarPaddingH - Theme.statusItemPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.statusBarHeight, maxHeight: Theme.statusBarHeight)
        .background(Theme.ui.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    private var separator: some View { Text(verbatim: "·").foregroundStyle(Theme.ui.text3) }
}

/// Item box: 20 high, padding 4 (clickable ones get the `hover` fill in it, radius 4).
private struct StatusItem: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, Theme.statusItemPaddingH).frame(height: Theme.statusItemHeight)
    }
}

private struct StatusButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.inlineGap) { label }.modifier(StatusItem())
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.statusItemRadius))
        .help(help)
    }
}

/// The status bar's ☕: only while the sleep assertion is actually held for working agents.
func showsKeepAwake(enabled: Bool, held: Bool) -> Bool { enabled && held }
