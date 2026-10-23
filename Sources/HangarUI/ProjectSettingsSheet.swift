import AppKit
import Exec
import Git
import SwiftUI
import Workspace

struct PathInputError: Error, Equatable { let message: String }

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

/// Project settings (sheet 580, `new-task-v4` style): name, path with «Choose…», default base branch and worktree folder (git projects only).
/// A missing folder is shown as an error and nothing is saved. A remote project: paths are typed (no «Choose…»),
/// the folder is checked on its host.
struct ProjectSettingsSheet: View {
    let project: Project
    let git: Git
    let runner: Runner
    let onSave: (_ name: String, _ path: String, _ baseBranch: String?, _ worktreeRoot: String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var path: String
    @State private var baseBranch: String?
    @State private var worktreeRoot: String
    @State private var error: String?
    @State private var rootError: String?
    /// nil until git has answered; the git-only rows appear only for a repository with commits.
    @State private var isGit: Bool?
    @State private var branches: [Branch] = []
    @State private var defaultBase: String?
    @State private var branchesError: String?
    @FocusState private var focus: Field?
    private enum Field { case name, path, root }

    init(project: Project, git: Git, runner: Runner,
         onSave: @escaping (_ name: String, _ path: String, _ baseBranch: String?, _ worktreeRoot: String?) -> Void,
         onCancel: @escaping () -> Void) {
        self.project = project
        self.git = git
        self.runner = runner
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project.name)
        _path = State(initialValue: project.path)
        _baseBranch = State(initialValue: project.lastBaseBranch)
        _worktreeRoot = State(initialValue: project.worktreeRoot ?? "")
    }

    private var remote: Bool { project.host != nil }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.sheetButtonGap) {
                Text(L10n.projectSettings)
                    .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                    .foregroundStyle(Theme.ui.sheetText)
                Text(project.name).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
            }
            .padding(.top, Theme.sheetHeaderTop)
            .padding(.bottom, Theme.sheetHeaderBottom)

            card.padding(.top, Theme.sheetNameTop)
            messages

            HStack(spacing: Theme.sheetButtonGap) {
                Text(L10n.escCancel).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: 0)
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save, action: save)
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : Theme.disabledButtonOpacity)
            }
            .padding(.vertical, Theme.sheetFooterPaddingV)
            .padding(.top, Theme.sheetGap)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .lineLimit(1)
        .background(Theme.ui.sheet)
        .onAppear { focus = .name }
        .task { await loadGit() }
    }

    // MARK: Card

    /// One card of rows (DESIGN.md «Правила»): name, path + «Выбрать…», then the git-only rows.
    private var card: some View {
        VStack(spacing: 0) {
            CardRow(label: L10n.projectName, labelWidth: Theme.projectCardLabelWidth, first: true) {
                TextField("", text: $name)
                    .modifier(CardField())
                    .focused($focus, equals: .name)
                    .onSubmit(save)
            }
            CardRow(label: L10n.projectPath, labelWidth: Theme.projectCardLabelWidth) {
                TextField("", text: $path)
                    .modifier(CardField(mono: true))
                    .focused($focus, equals: .path)
                    .onSubmit(save)
                    .onChange(of: path) { error = nil }
                if !remote { Button(L10n.chooseEllipsis, action: choose).buttonStyle(SheetButton(primary: false)).fixedSize() }
            }
            if isGit == true {
                CardRow(label: L10n.defaultBranch, labelWidth: Theme.projectCardLabelWidth) {
                    BranchPicker(selection: $baseBranch, branches: branches, defaultBase: defaultBase, taskBranches: [],
                                 defaultOption: L10n.branchAuto(defaultBase ?? "origin/HEAD"))
                    Spacer(minLength: 0)
                }
                CardRow(label: L10n.worktreeFolder, labelWidth: Theme.projectCardLabelWidth) {
                    TextField("", text: $worktreeRoot, prompt: Text(defaultRootPlaceholder).foregroundStyle(Theme.ui.text3))
                        .modifier(CardField(mono: true))
                        .focused($focus, equals: .root)
                        .onSubmit(save)
                        .onChange(of: worktreeRoot) { rootError = nil }
                    if !remote { Button(L10n.chooseEllipsis, action: chooseRoot).buttonStyle(SheetButton(primary: false)).fixedSize() }
                }
            }
        }
        .sheetCard()
    }

    /// Under the card, as in the new-task sheet: errors and the «inside the project» hint.
    @ViewBuilder private var messages: some View {
        if let error { message(error, Theme.ui.failed) }
        if isGit == true {
            if let branchesError { message(branchesError, Theme.ui.failed) }
            if rootError == nil, case .success(let root?) = worktreeRootInput(worktreeRoot, remote: remote),
               worktreeRootInsideProject(root, project: path) {
                message(L10n.worktreeRootInsideProject, Theme.ui.text3)
            }
            if let rootError { message(rootError, Theme.ui.failed) }
        }
    }

    private func message(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(.system(size: Theme.fontSize.tab)).foregroundStyle(color)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.sheetMessageTop)
    }

    /// Default worktree folder for the current project path.
    private var defaultRootPlaceholder: String {
        (worktreePath(projectPath: path, root: nil, branch: "x") as NSString).deletingLastPathComponent
    }

    /// Reads branches without fetching.
    private func loadGit() async {
        guard (try? await git.isRepository()) == true, await git.hasCommits() else { isGit = false; return }
        do { branches = try await git.listBranches() } catch {
            branchesError = (error as? GitError)?.errorDescription ?? error.localizedDescription
        }
        defaultBase = try? await git.defaultBranch()
        isGit = true
    }

    private func save() {
        guard canSave else { return }
        var root: String?
        if isGit == true {
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
            onSave(name, trimmed, base, root)
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
            onSave(name, trimmed, base, root)
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: worktreeRoot.isEmpty ? defaultRootPlaceholder : (worktreeRoot as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { worktreeRoot = url.path }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        // Modal over the sheet: a sheet can't host another sheet-modal panel.
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
