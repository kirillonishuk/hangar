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
            HStack(alignment: .firstTextBaseline, spacing: Theme.statusDot) {
                Text(L10n.newTask)
                    .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                    .foregroundStyle(Theme.ui.sheetText)
                Text(projectName).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
            }
            .padding(.top, Theme.sheetHeaderTop)
            .padding(.bottom, Theme.sheetHeaderBottom)

            TextField("", text: $model.name, prompt: Text(L10n.taskNamePlaceholder).foregroundStyle(Theme.ui.text3))
                .font(.system(size: Theme.fontSize.taskName, design: .monospaced))
                .focused($focus, equals: .name)
                .onSubmit { focus = .message }
                .modifier(SheetField(focused: focus == .name))
                .padding(.top, Theme.sheetNameTop)

            if model.availability != .notRepository {
                card.padding(.top, Theme.sheetGap)
                errors
            }

            TextField("", text: $message, prompt: Text(L10n.firstMessagePlaceholder(agentName))
                .foregroundStyle(Theme.ui.text3), axis: .vertical)
                .font(.system(size: Theme.fontSize.sheetRow))
                .lineLimit(2...8)
                .focused($focus, equals: .message)
                .frame(minHeight: Theme.messageMinHeight - 2 * Theme.fieldPaddingV, alignment: .topLeading)
                .modifier(SheetField(focused: focus == .message))
                .padding(.top, Theme.sheetGap)

            footer.padding(.vertical, Theme.sheetFooterPaddingV)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .lineLimit(1)
        .background(Theme.ui.sheet)
        .onAppear { focus = .name }
        .onChange(of: model.branch) {
            if !model.branchFollowsName { Task { await model.validateBranch() } }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            row(L10n.worktreeLabel, first: true) {
                Text(worktreeHint).font(.system(size: Theme.fontSize.counter)).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: Theme.cardRowGap)
                Toggle("", isOn: $model.worktree)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Theme.ui.primary)
                    .disabled(model.availability != .ready)
                    .pointingHand(model.availability == .ready)
            }
            row(L10n.fromBranch) {
                BranchPicker(selection: $model.base, branches: model.branches, defaultBase: model.defaultBase,
                             taskBranches: model.taskBranches, defaultOption: nil)
                Spacer(minLength: Theme.cardRowGap)
                fetchStatus
            }
            .opacity(model.worktree ? 1 : Theme.dimmedRowOpacity)
            .disabled(!model.worktree)
            row(L10n.newBranch) {
                if model.worktree {
                    TextField("", text: $model.branch)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                        .foregroundStyle(Theme.ui.sheetText)
                        .focused($focus, equals: .branch)
                        .onSubmit { focus = .message }
                    if model.branchFollowsName, !model.branch.isEmpty {
                        Text(L10n.fromName).font(.system(size: Theme.fontSize.counter)).foregroundStyle(Theme.ui.text3)
                    }
                } else {
                    Text("—").font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                        .foregroundStyle(Theme.ui.sheetText)
                    Spacer(minLength: 0)
                }
            }
            .opacity(model.worktree ? 1 : Theme.dimmedRowOpacity)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.ui.lineSheet, lineWidth: 1))
    }

    private var worktreeHint: String {
        if model.availability == .noCommits { return L10n.noCommits }
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
                        .font(.system(size: Theme.fontSize.counter)).foregroundStyle(Theme.ui.text3)
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

    private func row(_ label: String, first: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: Theme.cardRowGap) {
            Text(label).foregroundStyle(Theme.ui.text2).frame(width: Theme.cardLabelWidth, alignment: .leading)
            HStack(spacing: Theme.pickGap) { value() }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.dropdownRowHeight, alignment: .leading)
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
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
                    HStack(spacing: Theme.statusDot) {
                        Button(L10n.retry) { Task { await model.refresh() } }
                            .buttonStyle(SheetButton(primary: false))
                            .disabled(model.creating)
                        createWithoutFetch
                    }
                case .cancelled:
                    Text(L10n.fetchCancelled).foregroundStyle(Theme.ui.text3)
                    HStack(spacing: Theme.statusDot) { createWithoutFetch }
                default: EmptyView()
                }
                if let stderr = model.createError { stderrText(stderr) }
            }
            .font(.system(size: Theme.fontSize.tab))
            .padding(.top, hasErrors ? Theme.statusDot : 0)
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
            .font(.system(size: Theme.fontSize.tab, design: .monospaced))
            .foregroundStyle(Theme.ui.failed)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var createWithoutFetch: some View {
        Button(L10n.createWithoutFetch) { create(skipFetch: true) }
            .buttonStyle(SheetButton(primary: false))
            .disabled(!model.canCreate)
            .opacity(model.canCreate ? 1 : Theme.disabledButtonOpacity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.statusDot) {
            Text(footerHint).font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
            Spacer(minLength: 0)
            Button(L10n.cancel, action: cancel)
                .buttonStyle(SheetButton(primary: false))
                .keyboardShortcut(.cancelAction)
            Button { create(skipFetch: false) } label: {
                // The label keeps its width under the spinner: no jump.
                Text(L10n.create).opacity(model.creating ? 0 : 1)
                    .overlay { if model.creating { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(SheetButton(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canCreate)
            .opacity(model.canCreate || model.creating ? 1 : Theme.disabledButtonOpacity)
        }
    }

    private var footerHint: String {
        if !model.worktree, let branch = model.currentBranch { return L10n.currentBranch(branch) }
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

/// Field: `field` background, `control` border; focused → `accent` border + 3 pt ring (DESIGN.md).
struct SheetField: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.ui.sheetText)
            .padding(.vertical, Theme.fieldPaddingV)
            .padding(.horizontal, Theme.fieldPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius)
                .stroke(focused ? Theme.ui.accent : Theme.ui.control, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius + Theme.focusRing / 2)
                .stroke(Theme.ui.accent.opacity(focused ? Theme.focusRingOpacity : 0), lineWidth: Theme.focusRing)
                .padding(-Theme.focusRing / 2 - 1))
    }
}

struct SheetButton: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Theme.ui.selectionText : Theme.ui.sheetText)
            .padding(.vertical, Theme.buttonPaddingV)
            .padding(.horizontal, Theme.buttonPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(primary ? Theme.ui.primary : Theme.ui.button))
            .opacity(configuration.isPressed ? Theme.pressedOpacity : 1)
            .pointingHand()
    }
}
