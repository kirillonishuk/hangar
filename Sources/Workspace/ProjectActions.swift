import CryptoKit
import Foundation

/// A named command of a project («Dev server» → `pnpm dev`), run in its own tab in the chat's folder (#133).
public struct ProjectAction: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    /// A second run stops the running one and starts again in its tab; false — another tab.
    public var restart: Bool
    /// Where it runs, relative to the chat's folder («apps/cms» in a monorepo); nil — the folder itself.
    public var folder: String?

    public init(name: String, command: String, restart: Bool = true, folder: String? = nil) {
        self.name = name
        self.command = command
        self.restart = restart
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey { case name, command, restart, folder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), command: try c.decode(String.self, forKey: .command),
                  restart: try c.decodeIfPresent(Bool.self, forKey: .restart) ?? true,
                  folder: (try? c.decodeIfPresent(String.self, forKey: .folder)).flatMap { $0.flatMap(actionFolder) })
    }

    /// The folder it runs in: the chat's own, or `folder` under it.
    public func cwd(in chatFolder: String) -> String {
        guard let folder else { return chatFolder }
        return (chatFolder.hasSuffix("/") ? chatFolder : chatFolder + "/") + folder
    }
}

/// A usable working folder: relative to the chat's folder, inside it (no `..`, not absolute); «./apps/cms/» → «apps/cms».
/// nil for blank (the chat's folder itself) or unusable input.
public func actionFolder(_ raw: String) -> String? {
    var f = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while f.hasPrefix("./") { f.removeFirst(2) }
    while f.hasSuffix("/") { f.removeLast() }
    let parts = f.split(separator: "/", omittingEmptySubsequences: false)
    guard !f.isEmpty, !raw.trimmingCharacters(in: .whitespaces).hasPrefix("/"), !f.hasPrefix("~"),
          parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }),
          !f.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return f
}

/// A typed folder that `actionFolder` refuses (blank is fine).
public func actionFolderInvalid(_ raw: String) -> Bool {
    !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && actionFolder(raw) == nil
}

/// Where an action is defined: the project's settings (this Mac) or `.hangar/actions.json` in the chat's folder.
public enum ActionSource: String, Equatable, Sendable { case settings, repo }

public struct ResolvedAction: Equatable, Sendable {
    public var action: ProjectAction
    public var source: ActionSource
    public init(_ action: ProjectAction, source: ActionSource) {
        self.action = action
        self.source = source
    }
    public var name: String { action.name }
}

/// The repository file, relative to the chat's folder (a worktree has its own copy).
public let repoActionsFile = ".hangar/actions.json"
/// Bigger than any real list; a larger file is refused unread.
public let repoActionsMaxBytes = 65_536

/// `.hangar/actions.json` as read: its usable actions and what was wrong with it (nil — fine or no file).
public struct RepoActions: Equatable, Sendable {
    public var actions: [ProjectAction]
    public var error: String?
    public init(actions: [ProjectAction] = [], error: String? = nil) {
        self.actions = actions
        self.error = error
    }
}

/// `{"actions": [{"name": "Dev server", "command": "pnpm dev", "restart": true}]}`; nil data — no file. Bad JSON or entries
/// are reported (English, shown as is), never thrown: the good entries still count.
public func parseRepoActions(_ data: Data?) -> RepoActions {
    guard let data else { return RepoActions() }
    guard data.count <= repoActionsMaxBytes else { return RepoActions(error: "\(repoActionsFile) is larger than 64 KB") }
    let root: Any
    do { root = try JSONSerialization.jsonObject(with: data) } catch {
        return RepoActions(error: "\(repoActionsFile) is not valid JSON")
    }
    guard let list = (root as? [String: Any])?["actions"] as? [Any] else {
        return RepoActions(error: #"\#(repoActionsFile): expected {"actions": [{"name": …, "command": …}]}"#)
    }
    var out: [ProjectAction] = [], problems: [String] = []
    for (i, raw) in list.enumerated() {
        let entry = raw as? [String: Any]
        let restart = entry?["restart"]
        let folder = entry?["folder"]
        guard folder == nil || (folder as? String).flatMap(actionFolder) != nil else {
            problems.append("action \(i + 1): \"folder\" must be a folder inside the project, like apps/web")
            continue
        }
        guard let name = (entry?["name"] as? String).flatMap(actionName), let command = (entry?["command"] as? String).flatMap(actionCommand),
              restart == nil || (restart as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {
            problems.append("action \(i + 1): needs a name and a command")
            continue
        }
        guard !out.contains(where: { $0.name == name }) else { problems.append("action \(i + 1): \"\(name)\" is already defined"); continue }
        out.append(ProjectAction(name: name, command: command, restart: (restart as? Bool) ?? true,
                                 folder: (folder as? String).flatMap(actionFolder)))
    }
    return RepoActions(actions: out, error: problems.isEmpty ? nil : "\(repoActionsFile): " + problems.joined(separator: "; "))
}

/// A usable name: trimmed, 1…60 characters, no control characters (it becomes a tab title and a menu item).
public func actionName(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...60).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return name
}

/// A usable command: not blank, no NUL (newlines are fine: a small script).
public func actionCommand(_ raw: String) -> String? {
    let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return command.isEmpty || command.unicodeScalars.contains("\0") ? nil : command
}

/// The project's own actions first, then the repository's; a repository action named like one of the project's (this
/// Mac's setting wins) or hidden by the user is left out.
public func mergedActions(settings: [ProjectAction], repo: [ProjectAction], hidden: [String] = []) -> [ResolvedAction] {
    let own = settings.map { ResolvedAction($0, source: .settings) }
    return own + repo.filter { r in !settings.contains { $0.name == r.name } && !hidden.contains(r.name) }.map { ResolvedAction($0, source: .repo) }
}

/// What an approval remembers: the command's exact text (SHA-256, hex).
public func actionApprovalHash(_ command: String) -> String {
    SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A repository action runs unasked only with a command the user has confirmed before in this project.
public func actionNeedsApproval(_ action: ResolvedAction, approved: [String]?) -> Bool {
    action.source == .repo && !(approved ?? []).contains(actionApprovalHash(action.action.command))
}

/// What a run does in a chat: a new tab, or (restart on) the leaf already holding this action again.
public enum ActionRunPlan: Equatable, Sendable {
    case newTab
    case restart(tab: UUID, leaf: UUID)
}

public func actionRunPlan(_ action: ProjectAction, in task: HangarTask) -> ActionRunPlan {
    guard action.restart else { return .newTab }
    for tab in task.tabs {
        if let leaf = tab.root.leaves.first(where: { $0.action == action.name }) { return .restart(tab: tab.id, leaf: leaf.id) }
    }
    return .newTab
}

extension WorkspaceState {
    /// A shell tab for action `name` in the task's folder, made active; nil for an unknown task or a host's terminal.
    /// `cwd`: the action's folder (default: the task's own).
    @discardableResult
    public mutating func addActionTab(taskId: UUID, name: String, cwd: String? = nil) -> (tab: UUID, leaf: UUID)? {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }), !isHostShellTask(tasks[i]) else { return nil }
        let tab = addTab(taskId: taskId, kind: .shell)
        guard let t = tasks[i].tabs.firstIndex(where: { $0.id == tab }) else { return nil }
        var leaf = tasks[i].tabs[t].root.leaves[0]
        leaf.action = name
        if let cwd { leaf.cwd = cwd }
        tasks[i].tabs[t].root = .leaf(leaf)
        return (tab, leaf.id)
    }

    /// The action's leaf gets a new id in the same place (a fresh terminal: the old one is closed by the view sync);
    /// its user-given name stays. Returns the new id; nil if the leaf is gone.
    /// `cwd`: where the new run goes (the action's folder now); nil — where the old one ran.
    @discardableResult
    public mutating func renewActionLeaf(_ leafId: UUID, cwd: String? = nil) -> UUID? {
        for i in tasks.indices {
            for t in tasks[i].tabs.indices {
                guard let old = tasks[i].tabs[t].root.leaf(id: leafId) else { continue }
                var leaf = Leaf(kind: .shell, cwd: cwd ?? old.cwd)
                leaf.action = old.action
                leaf.customTitle = old.customTitle
                tasks[i].tabs[t].root = tasks[i].tabs[t].root.mapLeaves { $0.id == leafId ? leaf : $0 }
                if tasks[i].tabs[t].focusedLeafId == leafId { tasks[i].tabs[t].focusedLeafId = leaf.id }
                return leaf.id
            }
        }
        return nil
    }

    /// Settings' list as typed: blank rows dropped, names and commands trimmed; nil when empty. `hidden`: repository
    /// actions the user took off the list (by name).
    public mutating func setActions(projectId: UUID, _ actions: [ProjectAction], hidden: [String]? = nil) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let clean = actions.compactMap { a in
            actionName(a.name).flatMap { n in
                actionCommand(a.command).map { ProjectAction(name: n, command: $0, restart: a.restart, folder: a.folder.flatMap(actionFolder)) }
            }
        }
        projects[i].actions = clean.isEmpty ? nil : clean
        if let hidden { projects[i].hiddenActions = hidden.isEmpty ? nil : hidden }
    }

    public mutating func approveAction(projectId: UUID, command: String) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let hash = actionApprovalHash(command)
        if !(projects[i].approvedActions ?? []).contains(hash) { projects[i].approvedActions = (projects[i].approvedActions ?? []) + [hash] }
    }

    public mutating func setLastAction(projectId: UUID, _ name: String) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }), projects[i].lastAction != name else { return }
        projects[i].lastAction = name
    }
}
