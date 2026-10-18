import AppKit
import Exec
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
    var addProject: () -> Void = {}
    var newTask: (UUID?) -> Void = { _ in }  // project id; nil = selected/last project
    var projectSettings: (UUID) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    var openSettings: () -> Void = {}
    /// A click on a sidebar row or tab takes the keyboard from the terminal (so F2 renames what was clicked).
    var releaseFocus: () -> Void = {}
    /// message, informative text, destructive button title, called on confirm.
    var confirm: (String, String, String, @escaping () -> Void) -> Void = { _, _, _, _ in }
    /// message, details.
    var showError: (String, String) -> Void = { _, _ in }
}

/// Every action on projects, tasks and tabs, defined once: context menus, the `…` menu, shortcuts (and later ⌘K) read it here.
enum Action: CaseIterable {
    case newTask, rename, togglePin, projectSettings, revealInFinder, copyPath, openInEditor
    case archive, restore, deletePermanently, removeProject, splitRight, splitDown, closeTab

    /// Menu order per target; "Open in …" only when `external_editor` is set.
    @MainActor static func list(for target: ActionTarget, app: AppState) -> [Action] {
        let editor: [Action] = app.config.externalEditor == nil ? [] : [.openInEditor]
        switch target {
        case .task(let id):
            if app.state.tasks.first(where: { $0.id == id })?.archived == true { return [.restore, .deletePermanently] }
            return [.rename, .togglePin, .revealInFinder, .copyPath] + editor + [.archive]
        case .project:
            return [.newTask, .rename, .projectSettings, .revealInFinder, .copyPath] + editor + [.removeProject]
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
        }
    }

    @MainActor func isEnabled(for target: ActionTarget, app: AppState) -> Bool {
        switch self {
        // Sidebar rows can't host a text field in rail mode.
        case .rename: if case .tab = target { true } else { !app.state.sidebarCollapsed }
        case .newTask, .revealInFinder, .openInEditor: app.path(of: target).map(folderExists) ?? false
        case .copyPath: app.path(of: target) != nil
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
            ctx.pasteboard.setString(path, forType: .string)
        case (.openInEditor, _):
            guard let editor = app.config.externalEditor, let path = app.path(of: target) else { return }
            openInExternalEditor(editor, path: path, shell: posixShell(app.userShell)) { details in
                ctx.showError(L10n.openFailed(editorName(editor)), details)
            }
        case (.archive, .task(let id)): app.archive(taskId: id)
        case (.restore, .task(let id)): app.restore(taskId: id)
        case (.deletePermanently, .task(let id)):
            guard let task = app.state.tasks.first(where: { $0.id == id }) else { return }
            ctx.confirm(L10n.deleteTaskConfirm(task.name), L10n.deleteTaskInfo, L10n.delete) {
                app.perform { $0.deleteTask(id: id) }
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
            if i > 0 && action.startsGroup { Divider() }
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
        default: nil
        }
    }
}

/// What holds the keyboard when F2 is pressed.
enum FirstResponderKind { case terminal, text, other }
enum F2Route: Equatable { case passthrough, rename(ActionTarget), ignore }

/// F2 belongs to the terminal (and to text fields) when they have focus; otherwise it renames the last clicked
/// sidebar row or tab, falling back to the selected task.
func f2Route(_ kind: FirstResponderKind, lastClicked: ActionTarget?, selectedTask: UUID?) -> F2Route {
    guard kind == .other else { return .passthrough }
    if let lastClicked { return .rename(lastClicked) }
    return selectedTask.map { .rename(.task($0)) } ?? .ignore
}
