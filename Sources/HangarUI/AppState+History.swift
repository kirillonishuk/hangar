import AgentStatus
import Foundation
import History
import Workspace

/// «Сессии» history data and the per-leaf status summary the UI shows.
extension AppState {
    /// Session ids of agents in live leaves: those conversations are marked open.
    var openConversationIds: Set<String> {
        let live = liveLeafIds
        let leaves = state.tasks.flatMap { t in t.tabs.flatMap(\.root.leaves) + [t.drawer.leaf].compactMap { $0 } }
        return Set(leaves.filter { live.contains($0.id) && ($0.kind == .claude || $0.kind == .codex) }.compactMap { validSessionId($0.agentSessionId) })
    }

    /// Conversations of `folder` (a session's worktree or project folder), newest first; rescanned on every call
    /// (the view calls it when it opens). Remote projects read through their host; throws if it cannot be reached.
    func conversations(folder: String, project: Project) async throws -> [Conversation] {
        let open = openConversationIds
        if let host = project.host {
            return try await history.remote(folder: folder, host: host, runner: runner(for: project), open: open)
        }
        return await history.local(folder: folder, claudeDir: claudeSettingsURL.deletingLastPathComponent(),
                                   codexDir: codexConfigURL.deletingLastPathComponent(), open: open)
    }

    /// State as displayed (limits included) and running subagents: «работает · 2 агента».
    func statusSummary(ofLeaf id: UUID, kind: LeafKind) -> (state: AgentState, subagents: Int) {
        (displayState(ofLeaf: id, kind: kind), statuses.statusSummary(id).subagents)
    }
}
