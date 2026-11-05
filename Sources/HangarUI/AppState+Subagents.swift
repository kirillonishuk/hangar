import AgentStatus
import ControlServer
import Foundation
import History
import Workspace

/// Claude subagents of a chat's agent tabs (spec agent-subagents): rows from hooks, the transcript only while its panel is on screen.
extension AppState {
    /// An accepted hook of a claude leaf; any other hook leaves the lists (and the sidebar) alone.
    func subagentHook(leaf: UUID, _ e: EventMessage) {
        let event: SubagentEvent
        switch e.kind {
        case .subagentStart:
            guard let id = e.toolUseId else { return }
            event = .launch(toolUseId: id, type: e.agentType, title: e.title, prompt: e.message)
        case .subagentRun:
            guard let id = e.agentId else { return }
            event = .started(agentId: id, type: e.agentType)
        case .subagentStop:
            guard let id = e.agentId else { return }
            event = .stopped(agentId: id, result: e.message)
        case .tool:
            guard let id = e.toolUseId else { return }
            event = .returned(toolUseId: id, agentId: e.agentId, background: e.backgrounded == true)
        case .prompt: event = .turnStart
        case .stop: event = .turnEnd(going: e.backgroundIds.map(Set.init))
        case .stopFailure: event = .turnEnd(going: nil)
        case .sessionStart:
            // compact keeps the conversation and its subagents.
            guard e.source != "compact" else { return }
            event = .reset
        default: return
        }
        updateSubagents(leaf, event)
    }

    func updateSubagents(_ leaf: UUID, _ event: SubagentEvent) {
        guard subagents[leaf] != nil || { if case .launch = event { true } else { false } }() else { return }
        var list = subagents[leaf] ?? SubagentList()
        // Writing the dictionary redraws its readers: only on a real change.
        guard list.apply(event, now: clock()) else { return }
        subagents[leaf] = list.items.isEmpty ? nil : list
        // The shown subagent got its agent id or finished: look for its transcript again. Gone from the list — the view stays.
        guard let panel = subagentPanel, panel.leaf == leaf else { return }
        panel.remember()
        panel.itemChanged()
    }

    /// The chat whose tabs or bottom terminal hold this leaf.
    func task(ofAgentLeaf leaf: UUID) -> HangarTask? {
        state.tasks.first { t in !t.archived && (t.tabs.contains { $0.root.leaf(id: leaf) != nil } || t.drawer.leaf?.id == leaf) }
    }

    /// A click on a subagent row: the inspector shows it (its chat gets selected, the inspector shown); another row switches it.
    func openSubagentPanel(leaf: UUID, id: String) {
        guard subagent(leaf: leaf, id: id) != nil, let task = task(ofAgentLeaf: leaf) else { return }
        if subagentPanel?.leaf != leaf || subagentPanel?.id != id {
            closeSubagentPanel()
            subagentPanel = SubagentViewerModel(app: self, leaf: leaf, id: id)
        }
        subagentPanelJustOpened = true
        if selectedTask?.id != task.id || sessionsViewVisible { select(taskId: task.id) }
        if !state.inspectorVisible { perform { $0.inspectorVisible = true } } else { didChange?() }
    }

    func closeSubagentPanel() {
        guard let panel = subagentPanel else { return }
        panel.stop()
        subagentPanel = nil
        subagentPanelJustOpened = false
    }

    /// After any change of the selection, the inspector flag or the window (`InspectorWatch.update`): the transcript is watched
    /// only while the panel is on screen; another chat selected (or its tab gone) closes it.
    func syncSubagentPanel(windowVisible: Bool) {
        guard let panel = subagentPanel else { return }
        guard panel.item != nil, let selected = selectedTask, task(ofAgentLeaf: panel.leaf)?.id == selected.id else {
            closeSubagentPanel()
            return
        }
        panel.setVisible(windowVisible && state.inspectorVisible && !sessionsViewVisible)
    }

    /// The chat's running subagents (all its agent tabs, the bottom terminal too), oldest first: a finished one leaves the
    /// sidebar at once (HD-145); the list keeps it for its open view.
    func subagentRows(of task: HangarTask) -> [(leaf: UUID, item: Subagent)] {
        let leaves = task.tabs.flatMap(\.root.leaves) + [task.drawer.leaf].compactMap { $0 }
        return leaves.flatMap { leaf in (subagents[leaf.id]?.items ?? []).filter { $0.state == .running }.map { (leaf.id, $0) } }
            .sorted { $0.item.started < $1.item.started }
    }

    func subagent(leaf: UUID, id: String) -> Subagent? { subagents[leaf]?.items.first { $0.id == id } }

    func toggleSubagents(_ taskId: UUID) {
        if subagentsExpanded.contains(taskId) { subagentsExpanded.remove(taskId) } else { subagentsExpanded.insert(taskId) }
    }

    /// The subagent's transcript on this Mac; nil — a remote chat, no session id or agent id yet, or no file (yet).
    func subagentTranscriptURL(leaf leafId: UUID, agentId: String) -> URL? {
        let leaves = state.tasks.lazy.flatMap { t in t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap { $0 } }
        guard remoteLeafHost(leafId) == nil, let leaf = leaves.first(where: { $0.id == leafId }),
              let session = validSessionId(statuses.status(leafId).sessionId ?? leaf.agentSessionId) else { return nil }
        return subagentTranscript(configDir: claudeConfigDir, cwd: leaf.cwd, session: session, agentId: agentId)
    }
}
