import Git
import SwiftUI

/// Filter chips (popup buttons, spec §3.9): Branch (always set, HEAD by default), Author, Date, Path. Each opens the one
/// menu (`PopoverMenu`); a set chip shows its value in `accentText` on `accent` .15 and a × that clears it.
struct GitFilterChips: View {
    let app: AppState
    let model: GitPanelModel

    enum Chip: String { case branch, author, date, path }

    var body: some View {
        HStack(spacing: Theme.Space.s1) {
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

    private func chip(_ which: Chip, title: String, on: Bool, clear: @escaping () -> Void) -> some View {
        // A set Branch chip keeps one width while the row has room (setting another filter used to resize it) and
        // shrinks only when it doesn't; unset it is the short word «Ветка», like the others.
        let flexible = which == .branch && on
        return PopupButton(title: title, on: on, clear: on ? clear : nil) { gitFilterMenu(which, app: app, model: model) }
            .frame(maxWidth: flexible ? Theme.GitTab.branchChipWidth : Theme.GitTab.chipMaxWidth, alignment: .leading)
            .fixedSize(horizontal: !flexible, vertical: false)
    }
}

/// The menu of one filter chip.
@MainActor func gitFilterMenu(_ chip: GitFilterChips.Chip, app: AppState, model: GitPanelModel) -> PopoverMenuContent {
    switch chip {
    case .branch:
        return PopoverMenuContent { _ in
            let item = { (title: String, scope: LogFilters.Scope, note: String?, mono: Bool) in
                PopoverMenuEntry.item(PopoverMenuItem(title: title, checked: model.query.scope == scope, note: note, mono: mono) {
                    model.query.scope = scope
                })
            }
            let local = model.branches?.local ?? []
            return [item(L10n.gitAllBranches, .all, nil, false), item("HEAD", .head, model.branches?.head.branch, false)]
                + (local.isEmpty ? [] : [.separator] + local.map { item($0.name, .ref($0.name), nil, true) })
        }
    case .author:
        let found = { (q: String) in
            model.authors.filter { q.isEmpty || $0.author.name.localizedCaseInsensitiveContains(q) || $0.author.email.localizedCaseInsensitiveContains(q) }
        }
        // ↩: the one match, else the typed text as a name (authors not loaded yet).
        let submit = { (text: String) in
            let q = text.trimmingCharacters(in: .whitespaces)
            let matches = found(q)
            if let one = matches.first, matches.count == 1 { model.query.author = one.author } else if !q.isEmpty { model.query.author = GitAuthor(name: q, email: "") }
        }
        return PopoverMenuContent(search: .init(placeholder: L10n.gitFindAuthor, submit: submit)) { text in
            let matches = found(text.trimmingCharacters(in: .whitespaces))
            let all = PopoverMenuEntry.item(PopoverMenuItem(title: L10n.gitAllAuthors, checked: model.query.author == nil) { model.query.author = nil })
            return [all] + (matches.isEmpty ? [] : [.separator] + matches.map { a in
                .item(PopoverMenuItem(title: a.author.name, checked: model.query.author == a.author, note: "\(a.count)", help: a.author.email) {
                    model.query.author = a.author
                })
            })
        }
    case .date:
        // shortcut: three fixed ranges, no custom period — add a range picker when someone asks for one.
        let item = { (title: String, r: GitDateRange?) in
            PopoverMenuEntry.item(PopoverMenuItem(title: title, checked: model.query.date == r) { model.query.date = r })
        }
        return PopoverMenuContent([item(L10n.gitAnyDate, nil), .separator] + GitDateRange.allCases.map { item(L10n.gitDateRange($0), $0) })
    case .path:
        // A typed path (↩ applies) or a pick from the Files tree already loaded.
        let set = { (p: String?) in model.query.path = GitQuery.normalizedPath(p) }
        let search = PopoverMenuContent.Search(placeholder: L10n.gitPathPlaceholder, mono: true, text: model.query.path ?? "", submit: set)
        return PopoverMenuContent(search: search) { text in
            let current = GitQuery.normalizedPath(model.query.path)
            let any = PopoverMenuEntry.item(PopoverMenuItem(title: L10n.gitAnyPath, checked: current == nil) { set(nil) })
            let picks = gitPathCandidates(app.inspector.tree, query: text, limit: Theme.GitTab.popoverListMax)
            return [any] + (picks.isEmpty ? [] : [.separator] + picks.map { e in
                .item(PopoverMenuItem(title: e.path, checked: e.path == current, mono: true, file: (e.name, e.isDir)) { set(e.path) })
            })
        }
    }
}
