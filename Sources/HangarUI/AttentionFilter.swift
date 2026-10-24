import AgentStatus
import Workspace

/// Sidebar «Требуют внимания» (#67): per project in sidebar order, its active tasks (pinned ones too, the
/// PINNED section is hidden meanwhile) whose agent waits or failed; projects left empty are dropped.
func attentionGroups(_ state: WorkspaceState, status: (HangarTask) -> AgentState) -> [(project: Project, tasks: [HangarTask])] {
    state.projects.compactMap { project in
        let tasks = state.tasks(in: project.id).filter { [.waiting, .failed].contains(status($0)) }
        return tasks.isEmpty ? nil : (project, tasks)
    }
}

extension AppState {
    func attentionGroups() -> [(project: Project, tasks: [HangarTask])] {
        HangarUI.attentionGroups(state) { displayState(of: $0) }
    }
}
