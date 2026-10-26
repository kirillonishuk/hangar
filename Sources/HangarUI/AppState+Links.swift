import ControlServer
import Foundation
import Workspace

/// What a `hangar://` link resolves to (#66, #88).
enum LinkTarget: Equatable {
    case task(UUID), tab(task: UUID, tab: UUID), project(UUID), host(String), sessions(project: UUID)

    init?(_ target: ActionTarget) {
        switch target {
        case .task(let id): self = .task(id)
        case .tab(let task, let tab): self = .tab(task: task, tab: tab)
        case .project(let id): self = .project(id)
        }
    }

    /// The canonical link: the full lowercased id.
    var link: HangarLink {
        switch self {
        case .task(let id): HangarLink(kind: .task, ref: id.uuidString)
        case .tab(_, let id): HangarLink(kind: .tab, ref: id.uuidString)
        case .project(let id): HangarLink(kind: .project, ref: id.uuidString)
        case .host(let host): HangarLink(kind: .host, ref: host)
        case .sessions(let id): HangarLink(kind: .sessions, ref: id.uuidString)
        }
    }
}

extension AppState {
    /// Refs as in CLI/MCP (#45); archived tasks and their tabs are never found. A tab: its id or one of its leaves' ids.
    func linkTarget(_ kind: LinkKind, _ ref: String) -> Result<LinkTarget, ControlError> {
        switch kind {
        case .task: return resolveTask(ref).map { .task($0) }
        case .project: return resolveProject(ref).map { .project($0) }
        case .sessions: return resolveProject(ref).map { .sessions(project: $0) }
        case .host:
            // Only a host the sidebar shows, and only one a link can carry as is.
            guard sidebarHosts.contains(ref) else { return .failure(ControlError(code: .notFound, message: "no host \"\(ref)\"")) }
            guard HangarLink.isLinkableHost(ref) else { return .failure(ControlError(code: .badParams, message: "host \"\(ref)\" can't be put in a link")) }
            return .success(.host(ref))
        case .tab:
            var tabs: [UUID: (task: UUID, tab: UUID)] = [:]
            for task in state.tasks where !task.archived {
                for tab in task.tabs {
                    tabs[tab.id] = (task.id, tab.id)
                    for leaf in tab.root.leaves { tabs[leaf.id] = (task.id, tab.id) }
                }
            }
            return resolveRef(ref, in: tabs.keys.sorted { $0.uuidString < $1.uuidString }.map { RefCandidate(id: $0, names: []) })
                .map { let t = tabs[$0]!; return .tab(task: t.task, tab: t.tab) }
                .mapError { refError($0, ref, "tab") }
        }
    }

    /// A clicked `hangar://` URL: selects/shows only, nothing runs or connects. Anything unknown is logged and ignored
    /// (nil: the window shows a toast).
    func openLink(_ url: URL) -> LinkTarget? {
        guard let link = HangarLink(url: url) else {
            uiLog.error("link ignored: not a hangar link \(url.absoluteString.prefix(200), privacy: .public)")
            return nil
        }
        switch linkTarget(link.kind, link.ref) {
        case .failure(let e):
            uiLog.error("link ignored: \(e.message, privacy: .public)")
            return nil
        case .success(let target):
            switch target {
            case .task(let id): select(taskId: id)
            case .tab(let task, let tab):
                select(taskId: task)
                activate(tabId: tab)
            case .project(let id):
                // A project has no selection of its own: expand it, and show its first task if another project's is shown.
                setCollapsed(projectId: id, false)
                if selectedTask?.projectId != id, let first = state.tasks(in: id).first { select(taskId: first.id) }
            case .sessions(let id): showSessionsView(projectId: id)
            case .host(let host): showHost(host)
            }
            return target
        }
    }

    /// A host link: its terminal, else its projects unfolded with one of their sessions shown. Never a new ssh shell
    /// or a connect; a host from the ssh config with neither is just its sidebar row.
    private func showHost(_ host: String) {
        if let task = state.hostShellTask(host: host) { select(taskId: task.id); return }
        let projects = state.projects.filter { $0.host == host }
        for p in projects where p.collapsed { setCollapsed(projectId: p.id, false) }
        let shown = selectedTask.flatMap { t in projects.contains { $0.id == t.projectId } ? t.id : nil }
        if let id = shown ?? projects.lazy.compactMap({ self.state.tasks(in: $0.id).first?.id }).first { select(taskId: id) }
    }
}
