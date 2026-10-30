import AppKit
import Exec
import Git
import SwiftUI
import Workspace

struct PathInputError: Error, Equatable { let message: String }

/// «Копировать в worktree» (nil = the default list) and «Команда после создания» as the sheet saves them.
struct WorktreeSetup: Equatable { var copy: [String]?; var command: String? }

/// The comma-separated field → entries; blank ones dropped.
func worktreeCopyInput(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

/// True if `root` is the project folder or lies inside it (worktrees would show up in the project's own tree).
func worktreeRootInsideProject(_ root: String, project: String) -> Bool {
    func trimmed(_ p: String) -> String {
        var p = (p.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
    let r = trimmed(root), p = trimmed(project)
    return r == p || r.hasPrefix(p + "/")
}

/// «Папка worktree» input: blank → nil (default folder), `~` expanded (`remote`: not — this Mac's home is not the server's),
/// a relative path is an error.
@MainActor func worktreeRootInput(_ text: String, remote: Bool = false) -> Result<String?, PathInputError> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .success(nil) }
    let expanded = remote ? trimmed : (trimmed as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? .success(expanded) : .failure(PathInputError(message: L10n.pathMustBeAbsolute))
}

/// Project settings (sheet 640: the wider label column, `new-task-v4` style): name, path with «Choose…», default base branch and worktree folder (git projects only).
/// A missing folder is shown as an error and nothing is saved. A remote project: paths are typed (no «Choose…»),
/// the folder is checked on its host.
struct ProjectSettingsSheet: View {
    let project: Project
    let git: Git
    let runner: Runner
    let onSave: (_ name: String, _ path: String, _ baseBranch: String?, _ worktreeRoot: String?, _ setup: WorktreeSetup) -> Void
    let onCancel: () -> Void
    /// Applied on «Сохранить», only when changed.
    var onNotifications: (ProjectNotifications) -> Void = { _ in }

    @State private var name: String
    @State private var path: String
    @State private var baseBranch: String?
    @State private var worktreeRoot: String
    @State private var copyText: String
    @State private var setupCommand: String
    @State private var notifications: ProjectNotifications
    /// A project without its own list / command shows its package manager's defaults (the list: only what exists in
    /// the main checkout, prefilled; the command: a placeholder, never run unless saved); saved unchanged, they stay nil.
    @State private var defaults: WorktreeDefaults?
    @State private var suggestedCopy: String?
    @State private var error: String?
    @State private var rootError: String?
    /// nil until git has answered; the git-only rows appear only for a repository with commits.
    @State private var isGit: Bool?
    @State private var branches: [Branch] = []
    @State private var defaultBase: String?
    @State private var branchesError: String?
    @FocusState private var focus: Field?
    private enum Field { case name, path, root, copy, setup }

    init(project: Project, git: Git, runner: Runner,
         onSave: @escaping (_ name: String, _ path: String, _ baseBranch: String?, _ worktreeRoot: String?, _ setup: WorktreeSetup) -> Void,
         onNotifications: @escaping (ProjectNotifications) -> Void = { _ in },
         onCancel: @escaping () -> Void) {
        self.onNotifications = onNotifications
        self.project = project
        self.git = git
        self.runner = runner
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path)
        _baseBranch = State(initialValue: project.lastBaseBranch)
        _worktreeRoot = State(initialValue: project.worktreeRoot ?? "")
        _copyText = State(initialValue: project.worktreeCopy?.joined(separator: ", ") ?? "")
        _setupCommand = State(initialValue: project.setupCommand ?? "")
        _notifications = State(initialValue: project.notifications)
    }

    private var remote: Bool { project.host != nil }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.projectSettings, subtitle: project.name)

            card.padding(.top, Theme.sheetNameTop)
            messages

            SheetFooter {
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save, action: save)
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : Theme.Opacity.inactive)
            }
            .padding(.top, Theme.sheetGap)
        }
        .sheetFrame()
        .onAppear { focus = .name }
        .task { await loadGit() }
    }

    // MARK: Card

    /// One card of rows (DESIGN.md «Правила»): name, path + «Выбрать…», then the git-only rows.
    private var card: some View {
        VStack(spacing: Theme.sheetGap) {
            CardSection(title: L10n.sectionProjectTitle) { projectRows }
            if isGit == true { CardSection(title: L10n.worktreeLabel) { worktreeRows } }
        }
    }

    @ViewBuilder private var projectRows: some View {
            CardRow(label: L10n.projectName, first: true) {
                TextField("", text: $name)
                    .focused($focus, equals: .name)
                    .onSubmit(save)
                    .inputField(focused: focus == .name)
            }
            CardRow(label: L10n.projectPath) {
                pathField($path, placeholder: "", field: .path, invalid: error != nil)
                    .onChange(of: path) { error = nil }
                if !remote { Button(L10n.chooseEllipsis, action: choose).buttonStyle(SheetButton(primary: false)).fixedSize() }
            }
            CardRow(label: L10n.projectNotificationsTitle) {
                Segment(selection: notifications, options: ProjectNotifications.allCases.map { ($0, L10n.notifySegment($0)) }) { notifications = $0 }
                Spacer(minLength: 0)
            }
    }

    @ViewBuilder private var worktreeRows: some View {
                CardRow(label: L10n.defaultBranch, first: true) {
                    BranchPicker(selection: $baseBranch, branches: branches, defaultBase: defaultBase, taskBranches: [],
                                 defaultOption: L10n.branchAuto(defaultBase ?? "origin/HEAD"))
                    Spacer(minLength: 0)
                }
                CardRow(label: L10n.worktreeFolder) {
                    pathField($worktreeRoot, placeholder: defaultRootPlaceholder, field: .root, invalid: rootError != nil)
                        .onChange(of: worktreeRoot) { rootError = nil }
                    if !remote { Button(L10n.chooseEllipsis, action: chooseRoot).buttonStyle(SheetButton(primary: false)).fixedSize() }
                }
                .help(L10n.worktreeRootHint(rootShown))
                CardRow(label: L10n.worktreeCopy) {
                    // Blank + no own list = the default list; an own empty list copies nothing (no placeholder).
                    TextField("", text: $copyText)
                        .modifier(CardPlaceholder(text: project.worktreeCopy == nil ? (defaults?.copy ?? []).joined(separator: ", ") : "",
                                                  shown: copyText.isEmpty))
                        .focused($focus, equals: .copy)
                        .onSubmit(save)
                        .inputField(focused: focus == .copy, mono: true)
                }
                .help(L10n.worktreeCopyHelp)
                CardRow(label: L10n.setupCommand) {
                    // The lockfile's command is a placeholder only: it runs once typed in and saved (or turned on in the new-task sheet).
                    TextField("", text: $setupCommand)
                        .modifier(CardPlaceholder(text: suggestedCommand ?? "", shown: setupCommand.isEmpty))
                        .focused($focus, equals: .setup)
                        .onSubmit(save)
                        .inputField(focused: focus == .setup, mono: true)
                }
                .help(L10n.setupCommandHelp)
    }

    /// Under the card, as in the new-task sheet: errors and the «inside the project» hint.
    @ViewBuilder private var messages: some View {
        if let error { message(error, Theme.ui.failed) }
        if isGit == true {
            if let branchesError { message(branchesError, Theme.ui.failed) }
            // No «Сюда создаются все worktree…» line: it repeated the folder field above (it is that row's tooltip).
            // Shown for as long as the command is only suggested (not while typing): no jump.
            if suggestedCommand != nil { message(L10n.setupCommandSuggested, Theme.ui.text3) }
            if rootError == nil, case .success(let root?) = worktreeRootInput(worktreeRoot, remote: remote),
               worktreeRootInsideProject(root, project: path) {
                message(L10n.worktreeRootInsideProject, Theme.ui.text3)
            }
            if let rootError { message(rootError, Theme.ui.failed) }
        }
    }

    private func message(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(Theme.Typography.secondary.font()).foregroundStyle(color)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.sheetMessageTop)
    }

    /// The lockfile's command while the project has none of its own: a placeholder, never saved or run as is.
    private var suggestedCommand: String? { project.setupCommand == nil ? defaults?.command : nil }

    /// A path in a card row: unfocused, `~` + cut in the middle so the last components show (full path in the tooltip);
    /// focused, the full text, editable and scrolling. The field stays underneath (only its text is hidden), so nothing moves.
    private func pathField(_ text: Binding<String>, placeholder: String, field: Field, invalid: Bool) -> some View {
        let focused = focus == field
        let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = value.isEmpty ? placeholder : (remote ? value : (value as NSString).expandingTildeInPath)
        let shown = remote ? full : abbreviatedHomePath(full)
        return TextField("", text: text)
            .foregroundStyle(focused ? Theme.ui.inputText : .clear)
            .focused($focus, equals: field)
            .onSubmit(save)
            .overlay(alignment: .leading) {
                // The same plain field (not a `Text`): identical baseline and inset to the editor, so focus doesn't move the text.
                GeometryReader { geo in
                    TextField("", text: .constant(middleTruncatedPath(shown, maxLength: Int((geo.size.width - Theme.fieldTextInset) / Self.monoCharWidth))))
                        .foregroundStyle(value.isEmpty ? Theme.ui.inputPlaceholder : Theme.ui.inputText)  // inside the field's, so it wins
                        .focusable(false)
                        .frame(maxHeight: .infinity, alignment: .leading)
                }
                .opacity(focused && !value.isEmpty ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .inputField(focused: focused, mono: true, invalid: invalid)
            .help(full)
    }

    /// A `TextField` prompt ignores its colour here and reads as a value: the placeholder is drawn over the field instead.
    private struct CardPlaceholder: ViewModifier {
        let text: String
        let shown: Bool

        func body(content: Content) -> some View {
            content.overlay(alignment: .leading) {
                Text(verbatim: text)
                    .font(Theme.Input.font(mono: true))
                    .foregroundStyle(Theme.ui.inputPlaceholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One character of the card's monospaced font (the cut is counted in characters).
    private static let monoCharWidth = ("0" as NSString).size(withAttributes:
        [.font: Theme.Input.nsFont(mono: true)]).width

    /// Default worktree folder for the current project path.
    private var defaultRootPlaceholder: String {
        (worktreePath(projectPath: path, root: nil, branch: "x") as NSString).deletingLastPathComponent
    }

    /// The folder new worktrees go to, as typed now (the default one while the field is blank or invalid).
    private var rootShown: String {
        if case .success(let root?) = worktreeRootInput(worktreeRoot, remote: remote) { return root }
        return defaultRootPlaceholder
    }

    /// Reads branches without fetching, then fills what the project leaves to its package manager's defaults.
    private func loadGit() async {
        guard await loadBranches() else { isGit = false; return }
        guard project.worktreeCopy == nil || project.setupCommand == nil else { isGit = true; return }
        let found = WorktreeDefaults(lockfiles: (try? await git.lockfiles()) ?? [])
        defaults = found
        isGit = true  // after the defaults: the suggestion hint comes with the rows, not a moment later
        guard project.worktreeCopy == nil, let entries = try? await git.ignoredEntries() else { return }
        let present = found.copy.filter { !matchIgnored([$0], entries).isEmpty }.joined(separator: ", ")
        suggestedCopy = present
        if copyText.isEmpty { copyText = present }
    }

    /// Reads branches without fetching; false: not a repository with commits.
    private func loadBranches() async -> Bool {
        guard (try? await git.isRepository()) == true, await git.hasCommits() else { return false }
        do { branches = try await git.listBranches() } catch {
            branchesError = (error as? GitError)?.errorDescription ?? error.localizedDescription
        }
        defaultBase = try? await git.defaultBranch()
        return true
    }

    private func commit(_ name: String, _ path: String, _ base: String?, _ root: String?, _ setup: WorktreeSetup) {
        if notifications != project.notifications { onNotifications(notifications) }
        onSave(name, path, base, root, setup)
    }

    private func save() {
        guard canSave else { return }
        var root: String?
        var setup = WorktreeSetup(copy: project.worktreeCopy, command: project.setupCommand)  // hidden rows keep what is stored
        if isGit == true {
            setup = WorktreeSetup(copy: project.worktreeCopy == nil && copyText == (suggestedCopy ?? "") ? nil : worktreeCopyInput(copyText),
                                  command: project.setupCommand == nil && setupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : setupCommand)
            switch worktreeRootInput(worktreeRoot, remote: remote) {
            case .success(let value): root = value
            case .failure(let e): rootError = e.message; return
            }
        } else {
            root = project.worktreeRoot  // hidden rows keep what is stored
        }
        let typed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = remote ? typed : (typed as NSString).expandingTildeInPath
        let base = isGit == true ? baseBranch : project.lastBaseBranch
        guard remote else {
            guard folderExists(trimmed) else { error = L10n.folderMissing(trimmed); return }
            commit(name, trimmed, base, root, setup)
            return
        }
        // Nothing is saved unless the host says the folder is there; a host that isn't connected says so.
        Task {
            do {
                guard trimmed.hasPrefix("/"), try await directoryExists(trimmed, runner: runner) else { error = L10n.folderMissing(trimmed); return }
            } catch RemoteHostError.notConnected(let host) {
                error = L10n.hostOffline(host); return
            } catch {
                self.error = L10n.folderMissing(trimmed); return
            }
            commit(name, trimmed, base, root, setup)
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // The folder itself, else its nearest existing parent: a missing directoryURL makes the panel fall back elsewhere.
        panel.directoryURL = URL(fileURLWithPath: panelStartDirectory(worktreeRoot, fallback: defaultRootPlaceholder, exists: folderExists),
                                 isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { worktreeRoot = url.path }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // The current folder's parent, with the folder itself selected.
        let current = panelStartDirectory(path, fallback: project.path, exists: folderExists)
        panel.directoryURL = current == "/" ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: current, isDirectory: false)
        // Modal over the sheet: a sheet can't host another sheet-modal panel.
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
