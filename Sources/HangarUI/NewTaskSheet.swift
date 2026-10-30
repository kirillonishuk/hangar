import SwiftUI
import Workspace

/// New-task sheet (new-task-v4): name, one card (Worktree / От ветки / Новая ветка), first message.
/// Binds to `NewTaskModel`; all git work happens there.
struct NewTaskSheet: View {
    @Bindable var model: NewTaskModel
    let projectName: String
    let agentName: String
    let onCreate: (_ name: String, _ message: String, _ mode: TaskMode) -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @FocusState private var focus: Field?
    private enum Field { case name, branch, message }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.newTask, subtitle: projectName)

            TextField("", text: $model.name)
                .focused($focus, equals: .name)
                .onSubmit { focus = .message }
                .inputField(focused: focus == .name, placeholder: model.name.isEmpty ? L10n.taskNamePlaceholder : nil)
                .disabled(model.creating)
                .padding(.top, Theme.sheetNameTop)

            if model.availability != .notRepository {
                card.padding(.top, Theme.sheetGap)
                errors
            }

            TextField("", text: $message, axis: .vertical)
                .lineLimit(2...8)
                .focused($focus, equals: .message)
                .inputField(focused: focus == .message, multiline: true,
                            placeholder: message.isEmpty ? L10n.firstMessagePlaceholder(agentName) : nil)
                .padding(.top, Theme.sheetGap)

            footer
        }
        .sheetFrame()
        .onAppear { focus = .name }
        .onChange(of: model.branch) {
            if !model.branchFollowsName { Task { await model.validateBranch() } }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            CardRow(label: L10n.worktreeLabel, first: true) {
                Text(worktreeHint).font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: Theme.cardRowGap)
                Checkbox(L10n.worktreeLabel, showsLabel: false, isOn: $model.worktree)
                    .disabled(model.availability != .ready || model.creating)
            }
            CardRow(label: L10n.fromBranch) {
                BranchPicker(selection: $model.base, branches: model.branches, defaultBase: model.defaultBase,
                             taskBranches: model.taskBranches, defaultOption: nil)
                Spacer(minLength: Theme.cardRowGap)
                fetchStatus
            }
            .disabled(!model.worktree)  // the label and the picker dim themselves (no double fade)
            CardRow(label: L10n.newBranch) {
                if model.worktree {
                    TextField("", text: $model.branch)
                        .focused($focus, equals: .branch)
                        .onSubmit { focus = .message }
                        .inputField(focused: focus == .branch, mono: true, invalid: model.branchError != nil)
                        .disabled(model.creating)
                    if model.branchFollowsName, !model.branch.isEmpty {
                        Text(L10n.fromName).font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
                    }
                } else {
                    Text("—").font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text0)
                    Spacer(minLength: 0)
                }
            }
            .opacity(model.worktree ? 1 : Theme.Opacity.inactive)
            // Always there (no jump when the lockfile is read); a suggestion stays off until turned on.
            CardRow(label: L10n.afterCreate) {
                if let command = model.setupCommand {
                    Text(verbatim: command).font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text0)
                        .truncationMode(.middle)
                        .help(command)
                    Spacer(minLength: Theme.cardRowGap)
                    Checkbox(L10n.afterCreate, showsLabel: false, isOn: $model.runSetup)
                        .disabled(!model.worktree || model.creating)
                } else {
                    Text("—").font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text0)
                    Spacer(minLength: 0)
                }
            }
            .help(model.setupSuggested ? L10n.afterCreateSuggestedHelp : "")
            .opacity(model.worktree ? 1 : Theme.Opacity.inactive)
        }
        .sheetCard()
    }

    private var worktreeHint: String {
        if model.availability == .noCommits { return L10n.noCommits }
        if case .hostOffline(let host) = model.availability { return L10n.hostOffline(host) }
        return model.worktree ? L10n.worktreeOnHint : L10n.worktreeOffHint
    }

    /// «обновлено N мин назад» (recomputed on redraw only), spinner while fetching, ↻. Nothing without a remote.
    @ViewBuilder private var fetchStatus: some View {
        if model.worktree, model.availability == .ready, model.fetch != .noRemote {
            HStack(spacing: Theme.pickGap) {
                if model.fetch == .running {
                    ProgressView().controlSize(.small)
                } else if let last = model.lastFetch, model.fetch == .done || model.fetch == .idle {
                    // Not after a failed/cancelled fetch: git rewrites FETCH_HEAD (our «last fetch») even then.
                    Text(L10n.updatedAgo(ageLabel(since: last, now: Date())))
                        .font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3)
                }
                Button { Task { await model.refresh() } } label: {
                    IconView(icon: .refresh, size: Theme.smallIconSize)
                        .frame(width: Theme.sheetIconButtonSize, height: Theme.sheetIconButtonSize)
                }
                .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                .disabled(model.fetch == .running || model.creating)
                .help(L10n.refreshHelp)
            }
        }
    }

    // MARK: Errors

    /// Under the card: bad branch, failed/cancelled fetch (stderr + «Повторить» / «Создать без fetch»), git stderr.
    @ViewBuilder private var errors: some View {
        if model.worktree {
            VStack(alignment: .leading, spacing: Theme.pickGap) {
                if let error = model.branchError { Text(error).foregroundStyle(Theme.ui.failed) }
                switch model.fetch {
                case .failed(let stderr):
                    Text(L10n.fetchFailed).foregroundStyle(Theme.ui.failed)
                    stderrText(stderr)
                    HStack(spacing: Theme.sheetButtonGap) {
                        Button(L10n.retry) { Task { await model.refresh() } }
                            .buttonStyle(.hangar(.secondary))
                            .disabled(model.creating)
                        createWithoutFetch
                    }
                case .cancelled:
                    Text(L10n.fetchCancelled).foregroundStyle(Theme.ui.text3)
                    HStack(spacing: Theme.sheetButtonGap) { createWithoutFetch }
                default: EmptyView()
                }
                if let stderr = model.createError { stderrText(stderr) }
            }
            .font(Theme.Typography.secondary.font())
            .padding(.top, hasErrors ? Theme.sheetMessageTop : 0)
        }
    }

    private var hasErrors: Bool {
        if model.branchError != nil || model.createError != nil { return true }
        switch model.fetch {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private func stderrText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.mono.font())
            .foregroundStyle(Theme.ui.failed)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var createWithoutFetch: some View {
        Button(L10n.createWithoutFetch) { create(skipFetch: true) }
            .buttonStyle(.hangar(.secondary))
            .disabled(!model.canCreate)
    }

    // MARK: Footer

    private var footer: some View {
        SheetFooter(hint: footerHint) {
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
        }
    }

    private var footerHint: String {
        if let entry = model.progress { return L10n.copyingEntry(entry) }
        // Not «текущая ветка: main»: the «От ветки» row above already names it.
        return L10n.escCancel
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
        let name = model.name
        let message = message
        Task {
            if let mode = await model.create(skipFetch: skipFetch) { onCreate(name, message, mode) }
        }
    }
}
