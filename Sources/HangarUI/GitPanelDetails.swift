import AppKit
import Git
import SwiftUI

/// The selected commit: message, hash (click copies), author, date, then its files by folder with `+N −M`.
/// A file click opens that commit's diff of it in the diff tab. `compact`: replaces the log, with «← Коммиты».
struct GitDetailsView: View {
    let app: AppState
    let compact: Bool
    private var model: GitPanelModel { app.gitPanel }
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if let d = model.details, d.commit.hash == model.selected {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        message(d)
                        GitMetaLine(commit: d.commit, now: model.loadedAt)
                        files(d)
                    }
                    .padding(.bottom, Theme.GitTab.blockGap)
                }
            } else if let error = model.detailsError {
                GitNotice(text: L10n.gitFailed(error))
            }
            Spacer(minLength: 0)
        }
        .onChange(of: model.selected) { collapsed = [] }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if compact {
                Button { model.select(nil) } label: {
                    HStack(spacing: Theme.GitTab.rowGap) {
                        IconView(icon: .chevronRight, size: Theme.GitTab.searchIcon).rotationEffect(.degrees(180))
                        Text(L10n.gitCommits).font(Theme.Typography.body.font())
                    }
                }
                .buttonStyle(HeaderActionStyle())
                .padding(.leading, -Theme.Control.headerPaddingH)
            } else {
                Text(L10n.gitCommit)
                    .font(Theme.Typography.secondary.font(.semibold))
                    .foregroundStyle(Theme.ui.text3)
            }
            Spacer(minLength: 0)
            GitIconButton(icon: .close, help: L10n.close) { model.select(nil) }
        }
        .padding(.leading, Theme.GitTab.padding)
        .padding(.trailing, Theme.GitTab.rowInset)
        .frame(height: Theme.GitTab.detailsHeader)
        .overlay(alignment: .bottom) { if compact { Rectangle().fill(Theme.ui.line).frame(height: 1) } }
    }

    @ViewBuilder private func message(_ d: CommitDetails) -> some View {
        let parts = d.message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        Text(verbatim: d.commit.subject)
            .font((compact ? Theme.Typography.title : Theme.Typography.body).font(.semibold))
            .foregroundStyle(Theme.ui.textStrong)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, Theme.GitTab.padding)
            .padding(.top, compact ? Theme.GitTab.blockGap : 0)
        if !body.isEmpty {
            Text(verbatim: body)
                .font(Theme.Typography.body.font())
                .foregroundStyle(Theme.ui.text2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.GitTab.padding)
                .padding(.top, Theme.fileRowPaddingV)
        }
    }

    @ViewBuilder private func files(_ d: CommitDetails) -> some View {
        let total = commitFileTotals(d.files)
        HStack(spacing: Theme.GitTab.blockGap) {
            Text(L10n.fileCount(d.files.count)).font(Theme.Typography.secondary.font(.semibold)).foregroundStyle(Theme.ui.text3)
            Spacer(minLength: 0)
            GitNumbers(added: total.added, deleted: total.deleted)
        }
        .padding(.horizontal, Theme.GitTab.padding)
        .frame(height: Theme.GitTab.filesHeader)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        if d.truncated { GitNotice(text: L10n.statusTruncated(d.files.count)) }
        let open = app.activeDiff.flatMap { $0.commit == d.commit.hash ? $0.path : nil }
        ForEach(commitFileGroups(d.files)) { group in
            if !group.dir.isEmpty {
                let shut = collapsed.contains(group.dir)
                GitRow(action: { if shut { collapsed.remove(group.dir) } else { collapsed.insert(group.dir) } }) {
                    HStack(spacing: Theme.GitTab.rowGap) {
                        IconView(icon: shut ? .chevronRight : .chevronDown, size: Theme.GitTab.chevron, tint: Theme.ui.text3)
                            .frame(width: Theme.GitTab.chevronSlot)
                        FileIconView(name: (group.dir as NSString).lastPathComponent, isDir: true, expanded: !shut)
                        Text(verbatim: group.dir).font(Theme.Typography.body.font()).foregroundStyle(Theme.ui.textRow)
                            .lineLimit(1).truncationMode(.head)
                        Text(verbatim: "\(group.files.count)").font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                        Spacer(minLength: Theme.GitTab.rowGap)
                        GitNumbers(added: group.added, deleted: group.deleted)
                    }
                    .padding(.trailing, Theme.GitTab.chipLeading)
                    .frame(height: Theme.GitTab.treeRow)
                }
                .help(group.dir)
            }
            if group.dir.isEmpty || !collapsed.contains(group.dir) {
                ForEach(group.files) { file in
                    GitCommitFileRow(file: file, indent: group.dir.isEmpty ? 0 : Theme.GitTab.fileIndent, selected: file.path == open) {
                        app.openCommitDiff(hash: d.commit.hash, file: file)
                    }
                }
            }
        }
    }
}

/// Hash (click copies; ✓ until the pointer leaves) · author · date · parents of a merge.
private struct GitMetaLine: View {
    let commit: Commit
    let now: Date
    @State private var copied = false

    var body: some View {
        // A merge's «2 родителя» moves under the line when hash · author · date leave it no room.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.GitTab.blockGap) {
                main.fixedSize()
                if let parents { sep; parents.fixedSize() }
            }
            VStack(alignment: .leading, spacing: Theme.GitTab.blockGap) {
                HStack(spacing: Theme.GitTab.blockGap) { main }
                parents?.fixedSize()
            }
        }
        .font(Theme.Typography.secondary.font())
        .foregroundStyle(Theme.ui.text2)
        .padding(.horizontal, Theme.GitTab.padding)
        .padding(.vertical, Theme.GitTab.metaPaddingV)
        .onChange(of: commit.hash) { copied = false }
    }

    @ViewBuilder private var main: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
            copied = true
        } label: {
            HStack(spacing: Theme.railInset) {
                Text(verbatim: String(commit.hash.prefix(7))).font(Theme.Typography.mono.font())
                IconView(icon: copied ? .checkServer : .copy, size: Theme.GitTab.chipIcon, tint: Theme.ui.accentText)
            }
            .foregroundStyle(Theme.ui.accentText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()  // the author gives way first, the hash never wraps
        .pointingHand()
        .onHover { if !$0 { copied = false } }
        .help(L10n.gitCopyHash)
        sep
        Text(verbatim: commit.authorName).lineLimit(1).help(commit.authorEmail)
        sep
        Text(gitLongDate(commit.date, now: now)).lineLimit(1).fixedSize()
    }

    private var parents: GitRefPill? {
        commit.parents.count > 1 ? GitRefPill(ref: CommitRef(kind: .remote, name: L10n.gitParents(commit.parents.count)), lane: 0, head: nil) : nil
    }

    private var sep: some View { Text(verbatim: "·").foregroundStyle(Theme.ui.text3) }
}

private struct GitCommitFileRow: View {
    let file: ChangedFile
    let indent: CGFloat
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        GitRow(selected: selected, action: action) {
            HStack(spacing: Theme.GitTab.rowGap) {
                Color.clear.frame(width: Theme.GitTab.chevronSlot)
                FileIconView(name: name)
                Text(verbatim: name)
                    .font(Theme.Typography.body.font())
                    .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.GitTab.rowGap)
                if let a = file.added, let d = file.deleted { GitNumbers(added: a, deleted: d) }
                Text(verbatim: file.change.rawValue)
                    .font(Theme.Typography.mono.font(.semibold))
                    .foregroundStyle(Theme.Diff.badge(file.change))
                    .frame(width: Theme.GitTab.badgeWidth)
            }
            .padding(.leading, indent)
            .padding(.trailing, Theme.GitTab.chipLeading)
            .frame(height: Theme.GitTab.treeRow)
        }
        .help(file.origPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// `+N −M` in mono 12, the diff colours.
struct GitNumbers: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: Theme.GitTab.rowGap) {
            Text(verbatim: "+\(added)").foregroundStyle(Theme.Diff.badgeA)
            Text(verbatim: "−\(deleted)").foregroundStyle(Theme.Diff.badgeD)
        }
        .font(Theme.Typography.mono.font())
        .fixedSize()
    }
}
