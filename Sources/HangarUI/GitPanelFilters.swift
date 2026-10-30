import Git
import SwiftUI

/// Chips 24: Branch (always set, HEAD by default), Author, Date, Path. Each opens a popover of the «⋯» menu's look;
/// an active chip shows its value in `accent` 14 % and a `×` that clears it.
struct GitFilterChips: View {
    let app: AppState
    let model: GitPanelModel
    @State private var open: Chip?

    enum Chip { case branch, author, date, path }

    var body: some View {
        HStack(spacing: Theme.GitTab.chipGap) {
            // The current branch is the panel's header: only another scope lights the chip up.
            chip(.branch, title: branchTitle, on: model.query.scope != .head) { model.query.scope = .head }
            chip(.author, title: model.query.author?.name ?? L10n.gitAuthor, on: model.query.author != nil) { model.query.author = nil }
            chip(.date, title: model.query.date.map(L10n.gitDateRange) ?? L10n.gitDate, on: model.query.date != nil) { model.query.date = nil }
            let path = GitQuery.normalizedPath(model.query.path)
            chip(.path, title: path.map { ($0 as NSString).lastPathComponent } ?? L10n.gitPath, on: path != nil) { model.query.path = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.GitTab.padding)
        .padding(.vertical, Theme.GitTab.chipsMargin)
    }

    private var branchTitle: String {
        switch model.query.scope {
        case .all: L10n.gitAllBranches
        case .head: L10n.gitBranch
        case .ref(let r): r
        }
    }

    private func chip(_ which: Chip, title: String, on: Bool, clear: (() -> Void)?) -> some View {
        let binding = Binding(get: { open == which }, set: { if !$0 { open = nil } })
        // A set Branch chip keeps one width while the row has room (setting another filter used to resize it) and
        // shrinks only when it doesn't; unset it is the short word «Ветка», like the others.
        let flexible = which == .branch && on
        return GitChip(title: title, on: on, open: open == which, clear: on ? clear : nil) { open = which }
            .fixedSize(horizontal: !flexible, vertical: false)
            .frame(minWidth: 0, maxWidth: flexible ? Theme.GitTab.branchChipWidth : nil)
            .help(title)
            .popover(isPresented: binding, arrowEdge: .bottom) {
                Group {
                    switch which {
                    case .branch: GitBranchMenu(model: model) { open = nil }
                    case .author: GitAuthorMenu(model: model) { open = nil }
                    case .date: GitDateMenu(model: model) { open = nil }
                    case .path: GitPathMenu(tree: app.inspector.tree, model: model) { open = nil }
                    }
                }
                .padding(Theme.GitTab.popoverPadding)
                .frame(width: Theme.GitTab.popoverWidth)
                .background(Theme.ui.bg2)
                .environment(\.hoverPalette, .raised)
            }
    }
}

private struct GitChip: View {
    let title: String
    let on: Bool
    let open: Bool
    let clear: (() -> Void)?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: Theme.railInset) {
            Text(verbatim: title).lineLimit(1).truncationMode(.middle)
            if let clear {
                IconView(icon: .close, size: Theme.GitTab.chipIcon, tint: Theme.ui.accentText)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clear)
                    .help(L10n.gitClearFilter)
            } else {
                IconView(icon: .chevronDown, size: Theme.GitTab.chipIcon, tint: tint)
            }
        }
        .font(Theme.Typography.secondary.font())
        .foregroundStyle(tint)
        .padding(.leading, Theme.GitTab.chipLeading)
        .padding(.trailing, Theme.GitTab.chipTrailing)
        .frame(height: Theme.GitTab.chipHeight)
        .frame(maxWidth: Theme.GitTab.chipMaxWidth)
        .background(RoundedRectangle(cornerRadius: Theme.GitTab.chipRadius).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: Theme.GitTab.chipRadius).stroke(border, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .pointingHand()
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
    }

    private var tint: Color { on ? Theme.ui.accentText : open || hover ? Theme.ui.text1 : Theme.ui.text2 }
    private var fill: Color {
        on ? Theme.ui.accent.opacity(Theme.Opacity.fill) : open || hover ? Theme.ui.hover : .clear
    }
    private var border: Color {
        open && !on ? Theme.ui.line2 : .clear
    }
}

/// A popover item 30: check slot, title, a `text3` note on the right.
private struct GitMenuItem: View {
    let title: String
    var note: String?
    var checked = false
    var mono = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.GitTab.rowGap) {
                Group {
                    if checked { IconView(icon: .checkServer, size: Theme.GitTab.searchIcon, tint: Theme.ui.accentText) } else { Color.clear }
                }
                .frame(width: Theme.GitTab.menuCheck)
                Text(verbatim: title)
                    .font((mono ? Theme.Typography.mono : Theme.Typography.body).font())
                    .foregroundStyle(Theme.ui.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.GitTab.rowGap)
                if let note {
                    Text(verbatim: note).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                }
            }
            .padding(.horizontal, Theme.GitTab.chipLeading)
            .frame(height: Theme.GitTab.menuItem)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.GitTab.menuItemRadius))
    }
}

private struct GitMenuSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.ui.line2).frame(height: 1).padding(.vertical, Theme.GitTab.popoverPadding)
    }
}

/// A popover's own search field (the log's look, smaller margins).
private struct GitMenuField: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onSubmit(submit)
            .inputField(focused: focused, icon: .search, placeholder: text.isEmpty ? placeholder : nil)
        .padding(.bottom, Theme.GitTab.popoverPadding)
        .onAppear { focused = true }
    }
}

private struct GitBranchMenu: View {
    let model: GitPanelModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            item(L10n.gitAllBranches, .all)
            item("HEAD", .head, note: model.branches?.head.branch)
            if let local = model.branches?.local, !local.isEmpty {
                GitMenuSeparator()
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(local, id: \.name) { b in item(b.name, .ref(b.name), mono: true) }
                    }
                }
                .frame(maxHeight: CGFloat(Theme.GitTab.popoverListMax) * Theme.GitTab.menuItem)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func item(_ title: String, _ scope: LogFilters.Scope, note: String? = nil, mono: Bool = false) -> some View {
        GitMenuItem(title: title, note: note, checked: model.query.scope == scope, mono: mono) {
            model.query.scope = scope
            done()
        }
    }
}

private struct GitAuthorMenu: View {
    let model: GitPanelModel
    let done: () -> Void
    @State private var search = ""

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let found = model.authors.filter {
            q.isEmpty || $0.author.name.localizedCaseInsensitiveContains(q) || $0.author.email.localizedCaseInsensitiveContains(q)
        }
        VStack(spacing: 0) {
            GitMenuField(placeholder: L10n.gitFindAuthor, text: $search) {
                // Return: the one match, else the typed text as a name (authors not loaded yet).
                if let one = found.first, found.count == 1 { pick(one.author) } else if !q.isEmpty { pick(GitAuthor(name: q, email: "")) }
            }
            GitMenuItem(title: L10n.gitAllAuthors, checked: model.query.author == nil) { pick(nil) }
            if !found.isEmpty {
                GitMenuSeparator()
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(found, id: \.author) { a in
                            GitMenuItem(title: a.author.name, note: "\(a.count)", checked: model.query.author == a.author) { pick(a.author) }
                                .help(a.author.email)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(Theme.GitTab.popoverListMax) * Theme.GitTab.menuItem)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pick(_ a: GitAuthor?) {
        model.query.author = a
        done()
    }
}

/// shortcut: three fixed ranges, no custom period — add a range picker when someone asks for one.
private struct GitDateMenu: View {
    let model: GitPanelModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GitMenuItem(title: L10n.gitAnyDate, checked: model.query.date == nil) { pick(nil) }
            GitMenuSeparator()
            ForEach(GitDateRange.allCases, id: \.self) { r in
                GitMenuItem(title: L10n.gitDateRange(r), checked: model.query.date == r) { pick(r) }
            }
        }
    }

    private func pick(_ r: GitDateRange?) {
        model.query.date = r
        done()
    }
}

/// A typed path (Return applies) or a pick from the Files tree already loaded.
private struct GitPathMenu: View {
    let tree: FileTree
    let model: GitPanelModel
    let done: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            GitMenuField(placeholder: L10n.gitPathPlaceholder, text: $text) { pick(text) }
            GitMenuItem(title: L10n.gitAnyPath, checked: GitQuery.normalizedPath(model.query.path) == nil) { pick(nil) }
            let picks = gitPathCandidates(tree, query: text, limit: Theme.GitTab.popoverListMax)
            if !picks.isEmpty {
                GitMenuSeparator()
                ForEach(picks, id: \.path) { e in
                    Button { pick(e.path) } label: {
                        HStack(spacing: Theme.GitTab.rowGap) {
                            FileIconView(name: e.name, isDir: e.isDir)
                            Text(verbatim: e.path).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.text1)
                                .lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.GitTab.chipLeading)
                        .frame(height: Theme.GitTab.menuItem)
                    }
                    .buttonStyle(HoverButtonStyle(selected: e.path == GitQuery.normalizedPath(model.query.path), radius: Theme.GitTab.menuItemRadius))
                }
            }
        }
        .onAppear { text = model.query.path ?? "" }
    }

    private func pick(_ p: String?) {
        model.query.path = GitQuery.normalizedPath(p)
        done()
    }
}
