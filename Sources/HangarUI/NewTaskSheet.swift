import Git
import SwiftUI
import Workspace

/// «Новый чат» (design-system spec §3.14): name, where to work (project folder / separate copy), the copy's branch
/// and setup, the folded prompt for the agent. Binds to `NewTaskModel`; all git work happens there.
struct NewTaskSheet: View {
    @Bindable var model: NewTaskModel
    let projectName: String
    /// «Claude» / «Codex»: who gets the prompt.
    let agentName: String
    let onCreate: (_ name: String, _ message: String, _ mode: TaskMode) -> Void
    let onCancel: () -> Void

    @FocusState private var focus: Field?
    private enum Field { case name, place, branch, prompt, message }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                labeled(L10n.projectName) {
                    TextField("", text: $model.name)
                        .focused($focus, equals: .name)
                        .onSubmit(openPrompt)
                        .inputField(focused: focus == .name, placeholder: model.name.isEmpty ? L10n.taskNamePlaceholder : nil)
                        .disabled(model.creating)
                }
                if model.availability != .notRepository {
                    labeled(L10n.whereToWork) { whereOptions }
                    if model.worktree { copyFields }
                    errors
                }
                task
            }
            .padding(.top, Theme.Space.s4)
            .padding([.horizontal, .bottom], Theme.Space.s5)
            footer
        }
        .frame(width: Theme.sheetWidth)
        .font(Theme.Typography.body.font())
        .lineLimit(1)
        .background(Theme.ui.bg2)
        .onAppear { focus = .name }
        .onChange(of: model.branch) {
            if !model.branchFollowsName { Task { await model.validateBranch() } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
            Text(verbatim: L10n.newTask).font(Theme.Typography.title.font(.semibold)).foregroundStyle(Theme.ui.text0)
            Text(verbatim: projectName).foregroundStyle(Theme.ui.text2)
                .truncationMode(.middle)
                .help(projectName)
        }
        .padding([.top, .horizontal], Theme.Space.s5)
    }

    /// A field's label above it: `secondary` `text2`, 4 to the control.
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            Text(verbatim: label).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text2)
            content()
        }
    }

    // MARK: Where to work

    /// A radio group: one Tab stop (as a text field, so without Full Keyboard Access too); ←/↑ the folder, →/↓ the
    /// copy, Space switches; VoiceOver reads it as radio buttons.
    private var whereOptions: some View {
        let grouped = focus == .place
        return HStack(spacing: Theme.Space.s2) {
            RadioOption(title: L10n.whereFolder, detail: folderDetail, selected: !model.worktree,
                        focused: grouped && !model.worktree) { chooseCopy(false) }
            RadioOption(title: L10n.whereCopy, detail: AttributedString(copyDetail), selected: model.worktree,
                        focused: grouped && model.worktree) { chooseCopy(true) }
                .disabled(!copyAvailable)
        }
        .fixedSize(horizontal: false, vertical: true)  // both cards as tall as the taller one
        .disabled(model.creating)
        .focusable(!model.creating, interactions: .edit)
        .focused($focus, equals: .place)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .leftArrow, .upArrow, .rightArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow, .upArrow: chooseCopy(false)
            case .rightArrow, .downArrow: chooseCopy(true)
            default: chooseCopy(!model.worktree)
            }
            return .handled
        }
        // SwiftUI's own Tab order skips the copy's fields that appear below after the group took focus.
        .onKeyPress(keys: [.tab]) { press in
            focus = press.modifiers.contains(.shift) ? .name : model.worktree ? .branch : .prompt
            return .handled
        }
        .accessibilityRepresentation {
            Picker(L10n.whereToWork, selection: Binding(get: { model.worktree }, set: { chooseCopy($0) })) {
                Text(verbatim: L10n.whereFolder).tag(false)
                Text(verbatim: L10n.whereCopy).tag(true)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func chooseCopy(_ on: Bool) {
        guard !model.creating, !on || copyAvailable else { return }
        model.worktree = on
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
        var mono = AttributedString(code)
        mono.font = Theme.Typography.mono.font()
        return AttributedString(word + " ") + mono + AttributedString(". ") + shared
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
        labeled(L10n.newBranch) {
            HStack(spacing: Theme.Space.s2) {
                TextField("", text: $model.branch)
                    .focused($focus, equals: .branch)
                    .onSubmit(openPrompt)
                    .inputField(focused: focus == .branch, mono: true, invalid: model.branchError != nil)
                    .disabled(model.creating)
                Text(verbatim: L10n.branchFrom).foregroundStyle(Theme.ui.text2)
                BranchPicker(selection: $model.base, branches: model.branches, defaultBase: model.defaultBase,
                             taskBranches: model.taskBranches, defaultOption: nil)
                    .disabled(model.creating)
                fetchButton
            }
            if let error = model.branchError {
                Text(verbatim: error).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.failedText)
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
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var createWithoutFetch: some View {
        Button(L10n.createWithoutFetch) { create(skipFetch: true) }
            .buttonStyle(.hangar(.secondary))
            .disabled(!model.canCreate)
    }

    // MARK: Prompt

    /// Folded by default: the prompt can be written later, in the agent's tab.
    private var task: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            // Not a Button: a Tab stop without Full Keyboard Access too; Space / ↩ fold and unfold.
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: model.promptOpen ? .chevronDown : .chevronRight, size: Theme.Icon.inline, tint: Theme.ui.text2)
                Text(verbatim: L10n.taskFor(agentName)).foregroundStyle(Theme.ui.text1)
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
                    .lineLimit(2...8)
                    .focused($focus, equals: .message)
                    .inputField(focused: focus == .message, multiline: true)
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
        HStack(spacing: Theme.Space.s2) {
            if let entry = model.progress {
                Text(verbatim: L10n.copyingEntry(entry)).font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text3).truncationMode(.middle)
            }
            Spacer(minLength: 0)
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
        .padding(.vertical, Theme.Space.s3)
        .padding(.horizontal, Theme.Space.s5)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line2).frame(height: 1) }
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
