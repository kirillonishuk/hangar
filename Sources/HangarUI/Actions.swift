import AppKit
import Exec
import Git
import SwiftUI
import Workspace

/// What an action applies to.
enum ActionTarget: Equatable {
    case task(UUID), project(UUID), tab(task: UUID, tab: UUID)
}

/// Window-level services actions need (sheets, alerts, panels live in MainWindowController); tests inject fakes.
@MainActor struct ActionContext {
    let app: AppState
    var pasteboard: NSPasteboard = .general
    /// «+ проект»: the menu «Локальная папка…» / «Удалённый (SSH)…».
    var addProject: () -> Void = {}
    var addLocalProject: () -> Void = {}
    var addRemoteProject: () -> Void = {}
    /// «Сервер <host>» sheet.
    var checkServer: (String) -> Void = { _ in }
    var newTask: (UUID?) -> Void = { _ in }  // project id; nil = selected/last project
    var projectSettings: (UUID) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Shows/hides the task's bottom terminal (window-level: moves focus); nil = just flip the model.
    var toggleDrawer: ((UUID) -> Void)?
    /// message, informative text, destructive button title, called on confirm.
    var confirm: (String, String, String, @escaping () -> Void) -> Void = { _, _, _, _ in }
    /// message, informative text, destructive button title, checkbox title (unchecked); `then(checked)` only on confirm.
    var confirmWithCheckbox: (String, String, String, String, @escaping (Bool) -> Void) -> Void = { _, _, _, _, _ in }
    /// message, details.
    var showError: (String, String) -> Void = { _, _ in }
}

/// Every action on projects, tasks and tabs, defined once: context menus, the `…` menu, shortcuts (and later ⌘K) read it here.
enum Action: CaseIterable {
    case newTask, rename, togglePin, projectSettings, revealInFinder, copyPath, openInEditor
    case archive, restore, deletePermanently, removeProject, splitRight, splitDown, closeTab, toggleDrawer, reconnect

    /// Menu order per target; "Open in …" only when `external_editor` is set.
    @MainActor static func list(for target: ActionTarget, app: AppState) -> [Action] {
        let editor: [Action] = app.config.externalEditor == nil ? [] : [.openInEditor]
        // A remote project's rows can bring their host back.
        let reconnect: [Action] = app.project(of: target)?.host == nil ? [] : [.reconnect]
        switch target {
        case .task(let id):
            if app.state.tasks.first(where: { $0.id == id })?.archived == true { return [.restore, .deletePermanently] }
            return reconnect + [.rename, .togglePin, .revealInFinder, .copyPath] + editor + [.archive]
        case .project:
            return reconnect + [.newTask, .rename, .projectSettings, .revealInFinder, .copyPath] + editor + [.removeProject]
        case .tab:
            return [.rename, .splitRight, .splitDown, .closeTab]
        }
    }

    /// A divider goes before these (unless first in the menu).
    var startsGroup: Bool { [.revealInFinder, .archive, .deletePermanently, .removeProject, .splitRight, .closeTab].contains(self) }

    var shortcut: Shortcut? {
        switch self {
        case .rename: .rename
        case .archive: .archiveTask
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .closeTab: .closeTab
        case .toggleDrawer: .toggleDrawer
        default: nil
        }
    }

    var icon: Icon {
        switch self {
        case .newTask: .newTask
        case .rename: .rename
        case .togglePin: .pin
        case .projectSettings: .settings
        case .revealInFinder: .finder
        case .copyPath: .copy
        case .openInEditor: .openExternal
        case .archive: .archive
        case .restore: .restore
        case .deletePermanently: .trash
        case .removeProject: .remove
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .closeTab: .close
        case .toggleDrawer: .shell
        case .reconnect: .refresh
        }
    }

    @MainActor func title(for target: ActionTarget, app: AppState) -> String {
        switch self {
        case .newTask: L10n.newTask
        case .rename: L10n.rename
        case .togglePin:
            if case .task(let id) = target, app.state.tasks.first(where: { $0.id == id })?.pinned == true { L10n.unpin } else { L10n.pin }
        case .projectSettings: L10n.projectSettingsEllipsis
        case .revealInFinder: L10n.revealInFinder
        case .copyPath: L10n.copyPath
        case .openInEditor: L10n.openIn(editorName(app.config.externalEditor ?? ""))
        case .archive: L10n.archive
        case .restore: L10n.restore
        case .deletePermanently: L10n.deletePermanently
        case .removeProject: L10n.removeFromHangar
        case .splitRight: L10n.splitRight
        case .splitDown: L10n.splitDown
        case .closeTab: L10n.closeTab
        case .toggleDrawer: L10n.drawerToggle
        case .reconnect: L10n.reconnect
        }
    }

    @MainActor func isEnabled(for target: ActionTarget, app: AppState) -> Bool {
        switch self {
        // Sidebar rows can't host a text field in rail mode.
        case .rename: if case .tab = target { true } else { !app.state.sidebarCollapsed }
        case .newTask: app.isAvailable(target)
        // Finder and the external editor see only this Mac's disk.
        case .revealInFinder, .openInEditor: app.project(of: target)?.host == nil && app.isAvailable(target)
        case .copyPath: app.path(of: target) != nil
        case .reconnect: app.project(of: target)?.host.map { app.remote.hosts[$0]?.state != .connected } ?? false
        // As the keyboard (`drawerRoute`): the shown diff tab hides the task's tabs, a split would land in a hidden one.
        case .splitRight, .splitDown: if case .tab(let task, _) = target { app.activeDiff == nil || app.selectedTask?.id != task } else { true }
        default: true
        }
    }

    @MainActor func perform(_ target: ActionTarget, _ ctx: ActionContext) {
        let app = ctx.app
        guard isEnabled(for: target, app: app) else { return }
        switch (self, target) {
        case (.newTask, .project(let id)): ctx.newTask(id)
        case (.rename, _): app.renaming = target
        case (.togglePin, .task(let id)):
            if let task = app.state.tasks.first(where: { $0.id == id }) { app.setPinned(id, !task.pinned) }
        case (.projectSettings, .project(let id)): ctx.projectSettings(id)
        case (.revealInFinder, _):
            if let path = app.path(of: target) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case (.copyPath, _):
            guard let path = app.path(of: target) else { return }
            ctx.pasteboard.clearContents()
            ctx.pasteboard.setString((app.project(of: target)?.host).map { "\($0):\(path)" } ?? path, forType: .string)
        case (.openInEditor, _):
            guard let editor = app.config.externalEditor, let path = app.path(of: target) else { return }
            openInExternalEditor(editor, path: path, shell: posixShell(app.userShell)) { details in
                ctx.showError(L10n.openFailed(editorName(editor)), details)
            }
        case (.archive, .task(let id)): app.archive(taskId: id)
        case (.restore, .task(let id)): app.restore(taskId: id)
        case (.deletePermanently, .task(let id)):
            guard let task = app.state.tasks.first(where: { $0.id == id }) else { return }
            guard case .worktree = task.mode, let project = app.project(task.projectId) else {
                ctx.confirm(L10n.deleteTaskConfirm(task.name), L10n.deleteTaskInfo, L10n.delete) {
                    app.perform { $0.deleteTask(id: id) }
                }
                return
            }
            ctx.confirmWithCheckbox(L10n.deleteTaskConfirm(task.name), L10n.deleteTaskInfo, L10n.delete, L10n.alsoDeleteWorktree) { alsoWorktree in
                Task {
                    await deleteTaskPermanently(id, alsoWorktree: alsoWorktree, ctx: ctx, git: app.git(for: project), runner: app.runner(for: project))
                }
            }
        case (.removeProject, .project(let id)):
            guard let project = app.project(id) else { return }
            ctx.confirm(L10n.removeProjectConfirm(project.name), L10n.removeProjectInfo, L10n.remove) {
                app.perform { $0.removeProject(id: id) }
            }
        case (.splitRight, .tab(let task, let tab)), (.splitDown, .tab(let task, let tab)):
            guard let leaf = app.state.tasks.first(where: { $0.id == task })?.tabs.first(where: { $0.id == tab })?.focusedLeafId
            else { return }
            app.split(leafId: leaf, axis: self == .splitRight ? .horizontal : .vertical)
        case (.closeTab, .tab(let task, let tab)): app.perform { $0.closeTab(taskId: task, tabId: tab) }
        case (.reconnect, _): if let host = app.project(of: target)?.host { app.reconnect(host: host) }
        case (.toggleDrawer, .task(let id)):
            if let toggle = ctx.toggleDrawer { toggle(id) } else { app.perform { $0.toggleDrawer(taskId: id) } }
        default: assertionFailure("\(self) does not apply to \(target)")
        }
    }
}

func folderExists(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// `code` → "VS Code"; unknown commands are shown by their first word.
func editorName(_ command: String) -> String {
    let known = ["code": "VS Code", "cursor": "Cursor", "zed": "Zed"]
    let first = command.split(separator: " ").first.map(String.init) ?? command
    return known[first] ?? first
}

/// Runs `<editor> <path>` through the user's login shell: a Finder-launched app's PATH lacks /usr/local/bin and
/// ~/.local/bin, where `code`/`cursor`/`zed` live (decision #27). Non-zero exit → `onError` with stderr's last line.
@MainActor func openInExternalEditor(_ editor: String, path: String, shell: String, onError: @escaping @MainActor (String) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-i", "-c", "exec \(editor) \(shellQuote(path))"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let stderr = Pipe()
    process.standardError = stderr
    process.terminationHandler = { p in
        let status = p.terminationStatus
        guard status != 0 else { return }
        let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The last line is the error; earlier ones are often noise from the user's rc files (e.g. zle in a non-tty zsh).
        let details = String((text.split(separator: "\n").last.map(String.init) ?? "").suffix(400))
        DispatchQueue.main.async { MainActor.assumeIsolated { onError(details.isEmpty ? L10n.exitStatus(status) : details) } }
    }
    do {
        try process.run()
        uiLog.info("open in \(editor, privacy: .public): \(path, privacy: .public)")
    } catch {
        onError(error.localizedDescription)
    }
}

/// Context-menu and `…`-menu items for one target, from `Action`.
struct ActionMenuItems: View {
    let target: ActionTarget
    let ctx: ActionContext

    var body: some View {
        let app = ctx.app
        let actions = Action.list(for: target, app: app)
        ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
            if i > 0 && (action.startsGroup || actions[i - 1] == .reconnect) { Divider() }
            Button { action.perform(target, ctx) } label: {
                Label { Text(action.title(for: target, app: app)) } icon: { Image(nsImage: action.icon.image) }
            }
            .disabled(!action.isEnabled(for: target, app: app))
            .modifier(MenuShortcutHint(shortcut: action.shortcut))
        }
    }
}

/// Shows the key in the menu (the key itself is handled by the window's key monitor, by keyCode).
private struct MenuShortcutHint: ViewModifier {
    let shortcut: Shortcut?

    func body(content: Content) -> some View {
        if let key = shortcut?.menuKey { content.keyboardShortcut(key.0, modifiers: key.1) } else { content }
    }
}

extension Shortcut {
    var menuKey: (KeyEquivalent, EventModifiers)? {
        switch self {
        case .rename: (KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), [])
        case .archiveTask: ("w", [.command, .shift])
        case .splitRight: ("d", .command)
        case .splitDown: ("d", [.command, .shift])
        case .closeTab: ("w", .command)
        case .toggleDrawer: ("`", .control)
        default: nil
        }
    }
}

enum DrawerRoute: Equatable { case perform, collapseDrawer, ignore }

/// Shortcut routing while the bottom terminal has focus: it is not a tab, so ⌘W collapses it (the tab stays),
/// splits are ignored, everything else (⌘T, ⌃`, ⌘1…9, …) works as usual.
/// While the diff tab is shown (`diffActive`, focus not in the drawer) splits are ignored too: they would split the hidden tab.
func drawerRoute(_ sc: Shortcut, drawerFocused: Bool, diffActive: Bool) -> DrawerRoute {
    if diffActive, !drawerFocused, sc == .splitRight || sc == .splitDown { return .ignore }
    guard drawerFocused else { return .perform }
    switch sc {
    case .closeTab: return .collapseDrawer
    case .splitRight, .splitDown: return .ignore
    default: return .perform
    }
}

/// What holds the keyboard when F2 is pressed.
enum FirstResponderKind { case terminal, text, other }

/// The diff view sits in the terminal area but is not a terminal: F2 renames, its keys are not typing.
func responderKind(isText: Bool, inTerminalArea: Bool, isDiff: Bool) -> FirstResponderKind {
    if isText { return .text }
    return inTerminalArea && !isDiff ? .terminal : .other
}
enum F2Route: Equatable { case passthrough, rename(ActionTarget), ignore }
/// What the user did last: clicked a sidebar row / tab, or typed into a terminal or field.
enum Interaction: Equatable { case typing, chromeClick(ActionTarget) }

/// A sidebar row / tab clicked with no typing since → F2 renames it (the terminal keeps focus through the click).
/// Otherwise F2 belongs to the focused terminal or field; with neither focused, the selected task is renamed.
func f2Route(_ kind: FirstResponderKind, lastInteraction: Interaction, selectedTask: UUID?) -> F2Route {
    if case .chromeClick(let target) = lastInteraction { return .rename(target) }
    guard kind == .other else { return .passthrough }
    return selectedTask.map { .rename(.task($0)) } ?? .ignore
}
