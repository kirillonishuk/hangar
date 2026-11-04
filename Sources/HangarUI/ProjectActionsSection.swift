import SwiftUI
import Workspace

/// One row of «Действия» as typed (#133).
struct ActionDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var command = ""
    var folder = ""
    var restart = true

    init(name: String = "", command: String = "", folder: String = "", restart: Bool = true) {
        self.name = name
        self.command = command
        self.folder = folder
        self.restart = restart
    }

    init(_ action: ProjectAction) { self.init(name: action.name, command: action.command, folder: action.folder ?? "", restart: action.restart) }
}

/// «Действия» → the project's list: fully blank rows dropped; a half-filled row, a repeated name or a folder outside the
/// project is an error (nothing saved).
@MainActor func projectActionsInput(_ rows: [ActionDraft]) -> Result<[ProjectAction], PathInputError> {
    var out: [ProjectAction] = []
    for row in rows {
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines), command = row.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && command.isEmpty && row.folder.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        guard let n = actionName(name), let c = actionCommand(command) else { return .failure(PathInputError(message: L10n.actionIncomplete)) }
        guard !actionFolderInvalid(row.folder) else { return .failure(PathInputError(message: L10n.actionFolderInvalid)) }
        guard !out.contains(where: { $0.name == n }) else { return .failure(PathInputError(message: L10n.actionDuplicate(n))) }
        out.append(ProjectAction(name: n, command: c, restart: row.restart, folder: actionFolder(row.folder)))
    }
    return .success(out)
}

/// Suggestions not yet in the list (same command in the same folder), filtered by `query` (name, command or folder).
func actionSuggestionsShown(_ groups: [ActionSuggestionGroup], rows: [ActionDraft], query: String) -> [ActionSuggestionGroup] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return groups.compactMap { g in
        let actions = g.actions.filter { a in
            !rows.contains { $0.command.trimmingCharacters(in: .whitespaces) == a.command && actionFolder($0.folder) == a.folder }
                && (q.isEmpty || [a.name, a.command, g.folder].contains { $0.lowercased().contains(q) })
        }
        return actions.isEmpty ? nil : ActionSuggestionGroup(folder: g.folder, actions: actions)
    }
}

/// Project Settings → «Действия» (#133): own actions (name, command, folder, «Перезапускать», ⋯ — up, down, remove), then
/// `.hangar/actions.json`'s, read-only (⋯ — edit as own, hide / show), then «Добавить действие» with the repository's
/// suggestions (package.json scripts of the root and workspace packages, Makefile, justfile), searched when it opens.
struct ProjectActionsSection: View {
    @Binding var rows: [ActionDraft]
    @Binding var hidden: [String]
    let repo: RepoActions
    let error: String?
    let discover: () async -> [ActionSuggestionGroup]
    let submit: () -> Void
    @FocusState private var focus: Field?
    @State private var discovering = false
    @State private var anchor = MenuAnchor()
    private enum Field: Hashable { case name(UUID), command(UUID), folder(UUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSection(title: L10n.sectionActions) {
                ForEach($rows) { $row in ownRow($row) }
                ForEach(repoShown, id: \.name) { a in repoRow(a) }
                addRow
            }
            if let error { message(error, Theme.ui.failed) }
            if let e = repo.error { message(e, Theme.ui.failed) }
            if rows.isEmpty && repo.actions.isEmpty && repo.error == nil { message(L10n.actionsHint, Theme.ui.text3) }
        }
    }

    private func ownRow(_ row: Binding<ActionDraft>) -> some View {
        let id = row.wrappedValue.id
        let index = rows.firstIndex { $0.id == id } ?? 0
        return HStack(spacing: Theme.pickGap) {
            TextField("", text: row.name)
                .focused($focus, equals: .name(id))
                .onSubmit(submit)
                .inputField(focused: focus == .name(id), placeholder: row.wrappedValue.name.isEmpty ? L10n.actionName : nil)
                .frame(width: Theme.actionNameWidth)
            TextField("", text: row.command)
                .focused($focus, equals: .command(id))
                .onSubmit(submit)
                .inputField(focused: focus == .command(id), mono: true, placeholder: row.wrappedValue.command.isEmpty ? L10n.actionCommand : nil)
            TextField("", text: row.folder)
                .focused($focus, equals: .folder(id))
                .onSubmit(submit)
                .inputField(focused: focus == .folder(id), mono: true, invalid: actionFolderInvalid(row.wrappedValue.folder),
                            placeholder: row.wrappedValue.folder.isEmpty ? L10n.actionFolderPlaceholder : nil)
                .frame(width: Theme.actionFolderWidth)
                .help(L10n.actionFolderHelp)
            Checkbox(L10n.actionRestart, showsLabel: false, isOn: row.restart)
                .help(L10n.actionRestartHelp)
            PopoverMenuButton(help: L10n.actionRowMenu) {
                [
                    .item(PopoverMenuItem(title: L10n.actionMoveUp, icon: .chevronUp, enabled: index > 0) { move(id, by: -1) }),
                    .item(PopoverMenuItem(title: L10n.actionMoveDown, icon: .chevronDown, enabled: index < rows.count - 1) { move(id, by: 1) }),
                    .separator,
                    .item(PopoverMenuItem(title: L10n.actionRemove, icon: .trash, destructive: true) { rows.removeAll { $0.id == id } }),
                ]
            }
        }
        .modifier(ActionRowFrame(first: index == 0))
    }

    private func repoRow(_ a: ProjectAction) -> some View {
        let isHidden = hidden.contains(a.name)
        return HStack(spacing: Theme.pickGap) {
            Text(verbatim: a.name).foregroundStyle(Theme.ui.text1)
                .frame(width: Theme.actionNameWidth, alignment: .leading)
            Text(verbatim: a.command).font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text2)
                .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .help(a.command)
            Text(verbatim: a.folder ?? "").font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text3)
                .truncationMode(.middle).frame(width: Theme.actionFolderWidth, alignment: .leading)
            Text(verbatim: isHidden ? L10n.actionHiddenNote : L10n.actionFromRepo).font(Theme.Typography.caption.font())
                .foregroundStyle(Theme.ui.text3)
                .fixedSize()
                .help(L10n.actionFromRepoHelp)
            PopoverMenuButton(help: L10n.actionRowMenu) {
                [
                    .item(PopoverMenuItem(title: L10n.actionEditOwn, icon: .rename) { rows.append(ActionDraft(a)) }),
                    .item(PopoverMenuItem(title: isHidden ? L10n.actionShow : L10n.actionHide, icon: isHidden ? .restore : .remove) {
                        if isHidden { hidden.removeAll { $0 == a.name } } else { hidden.append(a.name) }
                    }),
                ]
            }
        }
        .lineLimit(1)
        .opacity(isHidden ? Theme.Opacity.inactive : 1)
        .modifier(ActionRowFrame(first: rows.isEmpty && repoShown.first?.name == a.name))
    }

    private var addRow: some View {
        Button(action: openPicker) {
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: .add, size: Theme.Icon.inline)
                Text(verbatim: L10n.actionAdd)
            }
        }
        .buttonStyle(.hangar(.plain, .small, busy: discovering))
        .disabled(discovering)
        .background(MenuAnchorView(anchor: anchor))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ActionRowFrame(first: rows.isEmpty && repoShown.isEmpty))
        #if DEBUG
        .onAppear { debugActionPicker = openPicker }
        #endif
    }

    /// Discovery runs now (only when asked); then the searchable picker: «Пустое действие» and the suggestions by package.
    private func openPicker() {
        guard !discovering else { return }
        discovering = true
        Task {
            let groups = await discover()
            discovering = false
            let rowsBinding = $rows
            var content = PopoverMenuContent(search: .init(placeholder: L10n.actionSearch, highlightFirst: true), width: Theme.menuWidthWide) { query in
                var entries: [PopoverMenuEntry] = []
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    entries.append(.item(PopoverMenuItem(title: L10n.actionBlank, icon: .add) { rowsBinding.wrappedValue.append(ActionDraft()) }))
                }
                for g in actionSuggestionsShown(groups, rows: rowsBinding.wrappedValue, query: query) {
                    entries.append(.header(g.folder.isEmpty ? L10n.actionRootGroup : g.folder, mono: g.folder.isEmpty ? nil : g.folder))
                    entries += g.actions.map { a in
                        .item(PopoverMenuItem(title: a.name, icon: .play, note: a.command, help: a.command) { rowsBinding.wrappedValue.append(ActionDraft(a)) })
                    }
                }
                return entries
            }
            if groups.isEmpty { content.note = { PopoverMenuNote(text: L10n.actionNoSuggestions) } }
            PopoverMenu.show(content, below: anchor.view)
        }
    }

    private func move(_ id: UUID, by step: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(i + step) else { return }
        rows.swapAt(i, i + step)
    }

    /// Repository actions not overridden by an own one of the same name (hidden ones stay, dimmed, to be shown again).
    private var repoShown: [ProjectAction] {
        repo.actions.filter { r in !rows.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == r.name } }
    }

    private func message(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).font(Theme.Typography.secondary.font()).foregroundStyle(color)
            .lineLimit(Theme.errorMaxLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.sheetMessageTop)
    }

    /// A card row's insets and divider, without `CardRow`'s label above.
    private struct ActionRowFrame: ViewModifier {
        let first: Bool
        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, minHeight: Theme.cardRowMinHeight, alignment: .leading)
                .padding(.vertical, Theme.cardRowPaddingV)
                .padding(.horizontal, Theme.cardRowPaddingH)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1).opacity(first ? 0 : 1) }
        }
    }
}

#if DEBUG
/// Debug channel `actionPicker`: as a click on «Добавить действие» in the open Project Settings.
@MainActor var debugActionPicker: (() -> Void)?
#endif
