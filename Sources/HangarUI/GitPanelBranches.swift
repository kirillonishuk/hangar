import Git
import SwiftUI

/// «Ветки»: collapsed to the HEAD line by default; open, HEAD / Local / Remote with `/` folders, up to 6 rows
/// before it scrolls. A click on a branch filters the log to it; the refresh button is `git fetch`.
struct GitBranchesBlock: View {
    let model: GitPanelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.branchesOpen, let list = model.branches {
                let rows = branchRows(list, expanded: model.expanded)
                let height = CGFloat(min(rows.count, Theme.GitTab.branchesMaxRows)) * Theme.GitTab.treeRow
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in GitBranchRow(row: row, selected: selected(row)) { tap(row) } }
                    }
                }
                .scrollDisabled(rows.count <= Theme.GitTab.branchesMaxRows)
                .frame(height: height)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.GitTab.rowGap) {
            Button { model.branchesOpen.toggle() } label: {
                HStack(spacing: Theme.GitTab.rowGap) {
                    IconView(icon: model.branchesOpen ? .chevronDown : .chevronRight, size: Theme.GitTab.chevron, tint: Theme.ui.text3)
                    // The checked-out branch (or the detached hash) is the header; the list holds the rest.
                    IconView(icon: .branch, size: Theme.GitTab.rowIcon, tint: Theme.ui.text2)
                    Text(verbatim: headTitle)
                        .font(.system(size: Theme.GitTab.mono, design: .monospaced))
                        .foregroundStyle(Theme.ui.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help(L10n.gitBranches + ": " + headTitle)
            .accessibilityLabel(L10n.gitBranches + ", " + headTitle)
            if model.branches?.remote.isEmpty == false {
                GitIconButton(icon: .refresh, help: L10n.gitFetchHelp, enabled: !model.fetching) { model.fetch() }
            }
        }
        .padding(.leading, Theme.GitTab.padding - Theme.GitTab.rowInset)
        .padding(.trailing, Theme.GitTab.padding - Theme.GitTab.rowInset)
        .frame(height: Theme.GitTab.sectionHeight)
    }

    private var headTitle: String {
        guard let head = model.branches?.head else { return "" }
        return head.branch ?? head.hash.map { String($0.prefix(7)) } ?? "HEAD"
    }

    private func selected(_ row: BranchRowItem) -> Bool {
        guard let scope = row.scope else { return false }
        return scope == model.query.scope
    }

    private func tap(_ row: BranchRowItem) {
        if let scope = row.scope {
            model.query.scope = scope
        } else if model.expanded.contains(row.id) {
            model.expanded.remove(row.id)
        } else {
            model.expanded.insert(row.id)
        }
    }
}

private struct GitBranchRow: View {
    let row: BranchRowItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        GitRow(selected: selected, action: action) {
            HStack(spacing: Theme.GitTab.rowGap) {
                Group {
                    if row.kind == .section || row.kind == .folder {
                        IconView(icon: row.expanded ? .chevronDown : .chevronRight, size: Theme.GitTab.chevron, tint: Theme.ui.text3)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Theme.GitTab.chevronSlot)
                icon
                title
                Spacer(minLength: Theme.GitTab.rowGap)
                trailing
            }
            .padding(.leading, CGFloat(row.depth) * Theme.GitTab.treeIndent)
            .padding(.trailing, Theme.GitTab.chipLeading)
            .frame(height: Theme.GitTab.treeRow)
        }
        .help(help)
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .head: IconView(icon: .branch, size: Theme.GitTab.rowIcon, tint: Theme.ui.accentText)
        case .branch: IconView(icon: .branch, size: Theme.GitTab.rowIcon, tint: row.branch?.isHead == true ? Theme.ui.accentText : Theme.ui.text2)
        case .folder: FileIconView(name: row.title, isDir: true, expanded: row.expanded)
        case .section: EmptyView()
        }
    }

    @ViewBuilder private var title: some View {
        if row.kind == .head {
            Text(verbatim: "HEAD").font(.system(size: Theme.fontSize.row)).foregroundStyle(Theme.ui.text1)
            GitRefPill(ref: CommitRef(kind: .head, name: row.title), lane: 0, head: nil)
        } else {
            Text(verbatim: row.title)
                .font(.system(size: Theme.fontSize.row, design: row.kind == .branch ? .monospaced : .default))
                .foregroundStyle(selected ? Theme.ui.text0 : Theme.ui.text1)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let b = row.branch, b.ahead > 0 || b.behind > 0 {
            HStack(spacing: Theme.GitTab.rowGap) {
                if b.ahead > 0 { Text(verbatim: "↑\(b.ahead)") }
                if b.behind > 0 { Text(verbatim: "↓\(b.behind)") }
            }
            .font(.system(size: Theme.GitTab.mono, design: .monospaced))
            .foregroundStyle(Theme.ui.text3)
        } else if let count = row.count {
            Text(verbatim: "\(count)").font(.system(size: Theme.fontSize.footer)).foregroundStyle(Theme.ui.text3)
        }
    }

    private var help: String {
        guard let b = row.branch else { return row.title }
        if let up = b.upstream, b.ahead > 0 || b.behind > 0 { return b.name + "\n" + L10n.gitAheadBehind(b.ahead, b.behind, up) }
        return b.name
    }
}
