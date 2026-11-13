import Git
import SwiftUI
import Workspace

/// «Новый чат» (design-system spec §3.14): its project (a pop-up in the header), name and agent, where to work (project
/// folder / separate copy), the copy's branch and setup, the prompt for the agent (folded or not as last time, HD-164).
/// Binds to `NewTaskModel`; all git work happens there.
struct NewTaskSheet: View {
    @Bindable var model: NewTaskModel
    /// Every project, for the header's pop-up; switching one makes a new model (the name and prompt carry over).
    let projects: [Project]
    let projectId: UUID
    let onProject: (UUID) -> Void
    /// «Задание для …» folded or unfolded: remembered for the next sheet.
    let onPromptOpen: (Bool) -> Void
    let onCreate: (_ name: String, _ message: String, _ mode: TaskMode) -> Void
    let onCancel: () -> Void

    @FocusState private var focus: Field?
    private enum Field { case name, place, branch, prompt, message }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.newTask) { projectButton }
            SheetFields {
                HStack(alignment: .bottom, spacing: Theme.Space.s3) {
                    SheetField(label: L10n.projectName) {
                        TextField("", text: $model.name)
                            .focused($focus, equals: .name)
                            .onSubmit(openPrompt)
                            .inputField(focused: focus == .name, placeholder: model.name.isEmpty ? L10n.taskNamePlaceholder : nil)
                            .disabled(model.creating)
                    }
                    SheetField(label: L10n.subChatAgent) {
                        AgentSegment(agent: model.agent) { model.agent = $0 }
                            .frame(height: Theme.Input.height)
                            .disabled(model.creating)
                    }
                    .fixedSize()
                }
                if model.availability != .notRepository {
                    SheetField(label: L10n.whereToWork) { whereOptions }
                    if model.worktree { copyFields }
                    errors
                } else {
                    // Why there is no «Где работать»: the chat works in the project folder.
                    Text(verbatim: L10n.notGitNoCopies)
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(Theme.ui.text3)
                }
                task
            }
            footer
        }
        .sheetFrame()
        .onAppear { focus = model.promptOpen ? .message : .name }
        .onChange(of: model.promptOpen) { onPromptOpen(model.promptOpen) }
        .onChange(of: model.branch) {
            if !model.branchFollowsName { Task { await model.validateBranch() } }
        }
    }

    /// The project as a pop-up button (§3.9): ⌘N may open the sheet for another project than meant (HD-164).
    private var projectButton: some View {
        let current = projects.first { $0.id == projectId }
        return PopupButton(title: current?.name ?? "—", help: L10n.newTaskProjectHelp) {
            PopoverMenuContent(projects.map { p in
                .item(PopoverMenuItem(title: p.name, checked: p.id == projectId, note: p.host) { if p.id != projectId { onProject(p.id) } })
            })
        }
        .disabled(model.creating)
    }

    // MARK: Where to work

    private var whereOptions: some View {
        WhereOptions(folderTitle: L10n.whereFolder, folderDetail: folderDetail, folderHelp: folderBranchHelp,
                     copyDetail: copyDetail, copyAvailable: copyAvailable, worktree: model.worktree, focused: focus == .place) {
            model.worktree = $0
        }
        .disabled(model.creating)
        .focused($focus, equals: .place)
        // SwiftUI's own Tab order skips the copy's fields that appear below after the group took focus.
        .onKeyPress(keys: [.tab]) { press in
            focus = press.modifiers.contains(.shift) ? .name : model.worktree ? .branch : .prompt
            return .handled
        }
    }

    /// «Ветка `main`. Изменения увидят все чаты проекта.» — the folder's live HEAD, mono.
    private var folderDetail: AttributedString {
        let shared = AttributedString(L10n.whereFolderShared)
        let word: String, code: String
        switch model.head {
        case .branch(let name): (word, code) = (L10n.whereFolderBranch, name)
        case .detached(let hash): (word, code) = (L10n.whereFolderCommit, hash)
        case nil: return shared
        }
        // A long branch would stretch the card to five lines: keep its start (the ticket) and end (HD-153).
        let max = Theme.folderBranchMaxChars
        var mono = AttributedString(code.count > max ? code.prefix(max / 2) + "…" + code.suffix(max - max / 2 - 1) : code)
        mono.font = Theme.Typography.mono.font()
        return AttributedString(word + " ") + mono + AttributedString(". ") + shared
    }

    /// The whole branch name when the card shows it cut.
    private var folderBranchHelp: String {
        if case .branch(let name) = model.head, name.count > Theme.folderBranchMaxChars { return name }
        return ""
    }

    /// Choosable while the repo still loads: `canCreate` waits for it, and a failed load turns the copy off.
    private var copyAvailable: Bool { model.availability == .ready || model.availability == .loading }

    private var copyDetail: String {
        switch model.availability {
        case .noCommits: L10n.copyNeedsCommit
        case .hostOffline(let host): L10n.hostOffline(host)
        default: L10n.whereCopyHint
        }
    }

    // MARK: Copy

    @ViewBuilder private var copyFields: some View {
        SheetField(label: L10n.newBranch) {
            // The field gets the whole row: next to the base it was squeezed to a few letters by a long base name (HD-153).
            TextField("", text: $model.branch)
                .focused($focus, equals: .branch)
                .onSubmit(openPrompt)
                .inputField(focused: focus == .branch, mono: true, invalid: model.branchError != nil)
                .disabled(model.creating)
            if let error = model.branchError {
                Text(verbatim: error).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.failedText)
            }
            HStack(spacing: Theme.Space.s2) {
                Text(verbatim: L10n.branchFrom).foregroundStyle(Theme.ui.text2)
                BranchPicker(selection: $model.base, branches: model.branches, defaultBase: model.defaultBase,
                             taskBranches: model.taskBranches, defaultOption: nil)
                    .disabled(model.creating)
                fetchButton
                Spacer(minLength: 0)
            }
        }
        if let command = model.setupCommand {
            Checkbox(L10n.afterCreate, detail: command, isOn: $model.runSetup)
                .disabled(model.creating)
                .help(model.setupSuggested ? L10n.afterCreateSuggestedHelp : command)
        }
    }

    /// ↻ after the base (a spinner while fetching); when the list was last fetched — in its tooltip. Nothing without a remote.
    @ViewBuilder private var fetchButton: some View {
        if model.availability == .ready, model.fetch != .noRemote {
            if model.fetch == .running {
                ProgressView().controlSize(.small)
                    .frame(width: Theme.Height.controlRegular, height: Theme.Height.controlRegular)
            } else {
                IconButton(icon: .refresh, size: .regular, help: refreshHelp) { Task { await model.refresh() } }
                    .disabled(model.creating)
            }
        }
    }

    private var refreshHelp: String {
        // Not after a failed/cancelled fetch: git rewrites FETCH_HEAD (our «last fetch») even then.
        guard let last = model.lastFetch, model.fetch == .done || model.fetch == .idle else { return L10n.refreshHelp }
        return L10n.refreshHelp + " — " + L10n.updatedAgo(ageLabel(since: last, now: Date()))
    }

    // MARK: Errors

    /// Failed/cancelled fetch (stderr + «Повторить» / «Создать без fetch»), git's stderr of a failed create.
    @ViewBuilder private var errors: some View {
        if model.worktree, hasErrors {
            VStack(alignment: .leading, spacing: Theme.Space.s2) {
                switch model.fetch {
                case .failed(let stderr):
                    Text(verbatim: L10n.fetchFailed).foregroundStyle(Theme.ui.failedText)
                    stderrText(stderr)
                    HStack(spacing: Theme.Space.s2) {
                        Button(L10n.retry) { Task { await model.refresh() } }
                            .buttonStyle(.hangar(.secondary))
                            .disabled(model.creating)
                        createWithoutFetch
                    }
                case .cancelled:
                    Text(verbatim: L10n.fetchCancelled).foregroundStyle(Theme.ui.text3)
                    createWithoutFetch
                default: EmptyView()
                }
                if let stderr = model.createError { stderrText(stderr) }
            }
            .font(Theme.Typography.secondary.font())
        }
    }

    private var hasErrors: Bool {
        if model.createError != nil { return true }
        switch model.fetch {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func stderrText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.Typography.mono.font())
            .foregroundStyle(Theme.ui.failedText)
            .wrappingError()
    }

    private var createWithoutFetch: some View {
        Button(L10n.createWithoutFetch) { create(skipFetch: true) }
            .buttonStyle(.hangar(.secondary))
            .disabled(!model.canCreate)
    }

    // MARK: Prompt

    /// Folded or not as the last sheet left it (HD-164): the prompt can be written later, in the agent's tab.
    private var task: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            // Not a Button: a Tab stop without Full Keyboard Access too; Space / ↩ fold and unfold.
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: model.promptOpen ? .chevronDown : .chevronRight, size: Theme.Icon.inline, tint: Theme.ui.text2)
                Text(verbatim: L10n.taskFor(model.agent == .codex ? "Codex" : "Claude")).foregroundStyle(Theme.ui.text1)
                Text(verbatim: "— " + L10n.taskLater).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: togglePrompt)
            .pointingHand()
            .focusable(interactions: .edit)
            .focused($focus, equals: .prompt)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, .return]) { _ in togglePrompt(); return .handled }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.ui.accent.opacity(Theme.Opacity.ring), lineWidth: Theme.Control.ringWidth)
                    .padding(-Theme.Space.s1)
                    .opacity(focus == .prompt ? 1 : 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(model.promptOpen ? L10n.toggleOn : L10n.toggleOff)
            .accessibilityAction { togglePrompt() }
            if model.promptOpen {
                TextField("", text: $model.message, axis: .vertical)
                    .lineLimit(Theme.promptLines)
                    .focused($focus, equals: .message)
                    .inputField(focused: focus == .message, multiline: true,
                                placeholder: model.message.isEmpty ? L10n.taskPromptPlaceholder : nil)
                    .disabled(model.creating)
            }
        }
    }

    private func togglePrompt() {
        model.promptOpen.toggle()
        focus = model.promptOpen ? .message : .prompt
    }

    /// ↩ in «Название» / «Ветка копии»: on to the prompt (unfolded).
    private func openPrompt() {
        model.promptOpen = true
        focus = .message
    }

    // MARK: Footer

    private var footer: some View {
        SheetFooter {
            if let entry = model.progress {
                Text(verbatim: L10n.copyingEntry(entry)).font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3).truncationMode(.middle)
            }
        } buttons: {
            blockedReason
            Button(L10n.cancel, action: cancel)
                .buttonStyle(.hangar(.secondary))
                .keyboardShortcut(.cancelAction)
            Button { create(skipFetch: false) } label: {
                // The label keeps its width under the spinner: no jump.
                Text(L10n.create).opacity(model.creating ? 0 : 1)
                    .overlay { if model.creating { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(.hangar(.primary, busy: model.creating))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canCreate)
            .help(L10n.createHelp)
        }
    }

    /// Why «Создать чат» is off: the repository still loading (spinner), or no base branch chosen.
    @ViewBuilder private var blockedReason: some View {
        if let blocked = model.createBlocked {
            HStack(spacing: Theme.Space.iconGap) {
                if blocked == .loading { ProgressView().controlSize(.small) }
                Text(verbatim: blocked == .loading ? L10n.createWaitsRepo : L10n.createNeedsBase)
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3)
            }
        }
    }

    /// While creating: Esc / «Отмена» cancels the pre-create fetch (the sheet stays), `worktree add` can't be
    /// interrupted. Otherwise closes the sheet.
    private func cancel() {
        if model.creating {
            model.cancelFetch()
        } else {
            onCancel()
        }
    }

    private func create(skipFetch: Bool) {
        guard model.canCreate else { return }
        let name = model.chatName
        let message = model.message
        Task {
            if let mode = await model.create(skipFetch: skipFetch) { onCreate(name, message, mode) }
        }
    }
}
