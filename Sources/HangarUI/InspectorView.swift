import Git
import SwiftUI

/// Right column (decision HD-044): segment Files / Changes N / Git (git only) / Search (HD-091), the lazy file tree or the changes list;
/// or a clicked subagent (spec agent-subagents §5).
/// Top: under the window toolbar (§3.1), the segment in a tab-bar-high row, so its bottom line continues the tab bar's.
struct InspectorView: View {
    let app: AppState
    private var model: InspectorModel { app.inspector }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Theme.Height.barToolbar)
            // No chat: nothing to inspect, and the centre already says what to do (§3.19, HD-106).
            if app.selectedTask == nil {
                Spacer(minLength: 0)
            } else if let panel = app.subagentPanel {
                // A subagent row was clicked: its view instead of the segment until «×» / Esc / a segment shortcut.
                SubagentPanel(app: app, model: panel)
            } else if hostShell {
                // «<host> · терминал»: the folder of its shell and Search there (no git, HD-124).
                header
                if model.segment == .search { SearchPanel(app: app) } else { RemoteFilesView(app: app) }
            } else if let text = app.inspectorNotice {
                header
                EmptyNote(text: text)
                Spacer(minLength: 0)
            } else {
                header
                if model.segment == .changes && model.isGit {
                    ChangesList(app: app, model: model)
                } else if model.segment == .git && model.isGit {
                    GitPanelView(app: app)
                } else if model.segment == .search {
                    SearchPanel(app: app)
                } else if app.selectedTask.map(app.state.isFreeChatTask) == true {
                    FilesList(app: app, model: model).modifier(FreeChatDrop(app: app))
                } else {
                    FilesList(app: app, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ui.bg1)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 0) { if hostShell || app.inspectorNotice == nil { segment } }
        .padding(.horizontal, Theme.inspectorSegmentPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.Height.barTabs, maxHeight: Theme.Height.barTabs)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    /// Equal parts (Changes at least its label and count), so a changing count never moves the labels; a plain folder
    /// has only Files and Search.
    private var hostShell: Bool { app.selectedTask.map { app.isHostShellTask($0.id) } ?? false }

    private var segment: some View {
        let count = model.changes?.files.count ?? 0
        var options = [SegmentOption(value: InspectorModel.Segment.files, title: L10n.segmentFiles, help: L10n.help(L10n.showFiles, .inspectorFiles))]
        if model.isGit && !hostShell {
            options.append(SegmentOption(value: .changes, title: L10n.segmentChangesTitle, badge: segmentBadge(count), reserveBadge: true,
                                         help: L10n.help(L10n.statusShowChanges, .inspectorChanges), accessibilityLabel: L10n.segmentChanges(count)))
            options.append(SegmentOption(value: .git, title: L10n.segmentGit, help: L10n.help(L10n.showGit, .inspectorGit)))
        }
        options.append(SegmentOption(value: .search, title: L10n.segmentSearch, help: L10n.help(L10n.findInFiles, .findInFiles)))
        let selection = hostShell && model.segment != .search ? .files : model.segment
        return Segmented(selection: selection, options: options, equal: true) { model.segment = $0 }
    }
}

/// Context menu of a Files / Changes row (Pane «File previews»); Finder sees only this Mac's disk.
enum FileMenuItem: Equatable, CaseIterable {
    case openInEditorTab, revealInFinder, copyPath, copyRelativePath

    static func items(remote: Bool) -> [FileMenuItem] { allCases.filter { !remote || $0 != .revealInFinder } }

    /// Pasteboard text of the copy items (a remote path as `host:path`, like the sidebar's «Скопировать путь»).
    func copied(root: String, relative: String, host: String?) -> String? {
        switch self {
        case .copyPath: (host.map { $0 + ":" } ?? "") + root + "/" + relative
        case .copyRelativePath: relative
        case .openInEditorTab, .revealInFinder: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case .openInEditorTab: L10n.openInEditorTab
        case .revealInFinder: L10n.revealInFinder
        case .copyPath: L10n.copyPath
        case .copyRelativePath: L10n.copyRelativePath
        }
    }

    var icon: Icon {
        switch self {
        case .openInEditorTab: .editor
        case .revealInFinder: .finder
        case .copyPath, .copyRelativePath: .copy
        }
    }
}

/// The custom menu for `relative` under the inspector's root; `opens`: the row opens in the editor (not a directory or deleted file).
@MainActor func fileMenu(app: AppState, relative: String, opens: Bool) -> [PopoverMenuEntry] {
    guard let root = app.inspector.root else { return [] }
    let host = remoteHost(app)
    let items: [PopoverMenuEntry] = FileMenuItem.items(remote: host != nil).filter { opens || $0 != .openInEditorTab }.map { item in
        .item(PopoverMenuItem(title: item.title, icon: item.icon) {
            let path = root + "/" + relative
            switch item {
            case .openInEditorTab: app.openInEditor(path: path, line: nil)
            case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case .copyPath, .copyRelativePath:
                guard let text = item.copied(root: root, relative: relative, host: host) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        })
    }
    // «Вставить путь в чат» (HD-163): into the chat's agent, no Enter; without a running agent — disabled.
    let agent = app.chatAgent
    return items + [.item(PopoverMenuItem(title: L10n.sendPathToChat, icon: agent?.kind == .codex ? .codex : .claude,
                                          enabled: agent != nil, help: agent == nil ? L10n.sendToChatNoAgent : nil) {
        app.sendPathToChat(root + "/" + relative)
    })]
}

/// «Откатить изменения…» (HD-156), the last group: only a file with uncommitted changes; a server's project — disabled.
@MainActor func revertMenu(app: AppState, relative: String) -> [PopoverMenuEntry] {
    guard app.canRevert(relative) else { return [] }
    let local = app.selectedProjectIsLocal
    return [.separator, .item(PopoverMenuItem(title: L10n.revertFile, icon: .restore, destructive: true, enabled: local,
                                              help: local ? nil : L10n.revertRemote) { app.requestRevert(relative) })]
}

@MainActor private func remoteHost(_ app: AppState) -> String? {
    app.selectedTask.flatMap { app.project($0.projectId)?.host }
}

/// A one-line `text3` remark above a list (missing base, truncation, git error, no task).
private func notice(_ text: String) -> some View {
    Text(text)
        .font(Theme.Typography.caption.font())
        .foregroundStyle(Theme.ui.text3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, Theme.fileRowPaddingV * 2)
}

private func changeBadge(_ change: FileChange?) -> some View {
    Text(verbatim: change?.rawValue ?? "")
        .font(Theme.Typography.monoSmall.font(.semibold))
        .foregroundStyle(change.map(Theme.Diff.badge) ?? .clear)
}

private struct FilesList: View {
    let app: AppState
    let model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.offline, let host = remoteHost(app) {
                notice(L10n.hostOffline(host))
            } else if model.remoteNoGit {
                notice(L10n.remoteNoGit)
            } else if let error = model.filesError ?? model.error {
                notice(L10n.gitFailed(error))
            }
            if model.filesTruncated { notice(L10n.filesTruncated(FileListing.limit)) }
            if let empty = model.emptyFilesNotice { EmptyNote(text: empty) }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows(model.tree, expanded: model.expanded)) { row in
                        FileRow(row: row, change: model.badges[row.entry.path], action: action(row))
                            .popoverContextMenu { fileMenu(app: app, relative: row.entry.path, opens: !row.entry.isDir && row.entry.opensInEditor) }
                    }
                }
                .padding(.vertical, Theme.fileRowPaddingV)
            }
        }
    }

    /// Directories toggle; files open in the task's editor; a directory symlink does nothing.
    private func action(_ row: TreeRow) -> (() -> Void)? {
        let entry = row.entry
        if entry.isDir {
            // A compact row opens and closes all of its folders.
            return { row.expanded ? row.chain.forEach(model.collapse) : row.chain.forEach(model.expand) }
        }
        guard entry.opensInEditor, let root = model.root else { return nil }
        // One click previews (one reused tab), a double click keeps the tab (as in VS Code, HD-083).
        return { app.openInEditor(path: root + "/" + entry.path, line: nil, preview: (NSApp.currentEvent?.clickCount ?? 1) < 2) }
    }
}

private struct FileRow: View {
    let row: TreeRow
    let change: FileChange?
    let action: (() -> Void)?

    var body: some View {
        HoverRow(action: action) { _ in
            HStack(spacing: Theme.railInset) {
                // Files keep the chevron's slot, so names of one level line up.
                if row.entry.isDir {
                    IconView(icon: row.expanded ? .chevronDown : .chevronRight, size: Theme.Icon.inline)
                } else {
                    Color.clear.frame(width: Theme.Icon.inline, height: Theme.Icon.inline)
                }
                FileIconView(name: row.entry.name, isDir: row.entry.isDir || row.entry.isDirLink, expanded: row.expanded)
                Text(row.name)
                    .font(Theme.Typography.body.font())
                    .foregroundStyle(Theme.ui.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.railInset)
                changeBadge(change)
            }
            .padding(.leading, Theme.rowPaddingH + CGFloat(row.depth) * Theme.treeIndent)
            .padding(.trailing, Theme.rowPaddingH)
            .padding(.vertical, Theme.fileRowPaddingV)
        }
        .help(row.entry.path)
    }
}

private struct ChangesList: View {
    let app: AppState
    let model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            modeLine
            if model.offline, let host = remoteHost(app) {
                notice(L10n.hostOffline(host))
            } else if let error = model.error {
                notice(L10n.gitFailed(error))
            }
            if let changes = model.changes {
                if changes.baseMissing { notice(model.baseName.map(L10n.baseMissing) ?? L10n.baseMissingUnknown) }
                if changes.truncated || model.statusTruncated { notice(L10n.statusTruncated(changes.files.count)) }
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if let changes = model.changes {
                        if changes.files.isEmpty { EmptyNote(text: L10n.noChanges) }
                        let columns = ChangeColumns(changes.files)
                        let viewed = app.viewedChanges
                        ForEach(changes.files) { file in
                            ChangeRow(file: file, columns: columns, selected: file.path == model.diffPath,
                                      viewed: viewed.contains(file.path)) { app.openDiff(path: file.path) }
                                .popoverContextMenu { fileMenu(app: app, relative: file.path, opens: file.change != .deleted) + revertMenu(app: app, relative: file.path) }
                        }
                    }
                }
                .padding(.vertical, Theme.fileRowPaddingV)
            }
        }
    }

    /// The list's header: the mode segment «Не в коммите · Вся ветка» (§3.7, §3.9); ⌥B switches, the key and the base
    /// are in the tooltips. Always there, so the rows never move; without a base «Вся ветка» is dimmed.
    private var modeLine: some View {
        let onBase: Bool = if let mode = model.changes?.mode { if case .base = mode { true } else { false } } else { model.modeChoice == .base }
        let base: String? = if case .base(let b) = model.changes?.mode { b } else { model.baseName }
        let hasBase = base != nil && model.changes?.baseMissing != true
        return HStack(spacing: 0) {
            // Without a base «Вся ветка» is dimmed: never shown as the chosen one (also while the list loads).
            Segmented(selection: onBase && hasBase ? InspectorModel.ModeChoice.base : .uncommitted, options: [
                SegmentOption(value: .uncommitted, title: L10n.changesHintUncommitted, help: L10n.changesHintToUncommitted),
                SegmentOption(value: .base, title: L10n.changesWholeBranch,
                              help: hasBase ? L10n.changesHintToBase(base ?? "") : base.map(L10n.baseMissing) ?? L10n.baseMissingUnknown),
            ], disabled: hasBase ? [] : [.base]) { choice in
                if choice != model.modeChoice { model.toggleMode() }
            }
            Spacer(minLength: Theme.Space.s2)
            // Progress of «Просмотрено» (HD-151): the total is the segment's count, so only the viewed number here.
            let viewed = app.viewedChanges.count
            if viewed > 0, let total = model.changes?.files.count {
                Text(verbatim: L10n.changesViewed(viewed))
                    .font(Theme.Typography.caption.font())
                    .foregroundStyle(Theme.ui.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(L10n.changesViewedOf(viewed, total))
            }
        }
        .padding(.horizontal, Theme.rowPaddingH)
        .frame(height: Theme.GitTab.sectionHeight)
    }
}

/// Widths of the `+N` / `−M` columns of one Changes list: the longest numbers of the list, so stats line up.
struct ChangeColumns: Equatable {
    var added: CGFloat
    var deleted: CGFloat

    init(_ files: [ChangedFile]) {
        added = Self.width(files.compactMap(\.added).max())
        deleted = Self.width(files.compactMap(\.deleted).max())
    }

    /// A sign and the digits of `n` in the stats' monospaced font; nothing to show → 0.
    static func width(_ n: Int?) -> CGFloat {
        guard let n else { return 0 }
        let font = Theme.Typography.monoSmall.nsFont()
        return ceil(("+\(n)" as NSString).size(withAttributes: [.font: font]).width)
    }
}

private struct ChangeRow: View {
    let file: ChangedFile
    let columns: ChangeColumns
    let selected: Bool
    /// «Просмотрено» (HD-151): a check instead of the file icon, the row dimmed (not hidden).
    var viewed = false
    let action: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HoverRow(selected: selected, action: action) { _ in
            HStack(spacing: Theme.inlineGap) {
                if viewed {
                    IconView(icon: .check, size: Theme.Icon.toolbar, tint: Theme.ui.text2)
                } else {
                    FileIconView(name: name)
                }
                NameFolderLayout(gap: Theme.inlineGap, folderTail: dir.isEmpty ? 0 : folderTailWidth(dir)) {
                    Text(name)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(selected ? Theme.ui.text0 : Theme.ui.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !dir.isEmpty { FolderText(dir: dir) }
                }
                // A zero side is noise («+3 −0»): only what changed.
                Text(verbatim: file.added.flatMap { $0 > 0 ? "+\($0)" : nil } ?? "")
                    .foregroundStyle(Theme.Diff.badgeA)
                    .frame(width: columns.added, alignment: .trailing)
                Text(verbatim: file.deleted.flatMap { $0 > 0 ? "−\($0)" : nil } ?? "")
                    .foregroundStyle(Theme.Diff.badgeD)
                    .frame(width: columns.deleted, alignment: .trailing)
                changeBadge(file.change)
                    .frame(width: Theme.GitTab.badgeWidth, alignment: .center)
            }
            .font(Theme.Typography.monoSmall.font())
            .opacity(viewed ? Theme.Opacity.inactive : 1)
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, Theme.fileRowPaddingV)
        }
        .help((file.origPath.map { "\($0) → \(file.path)" } ?? file.path) + (viewed ? " — " + L10n.diffViewed.lowercased() : ""))
    }
}

/// A file name, then its folder in the room left after it. The folder always keeps at least its last component
/// (`folderTail`, up to half the row): two `index.ts` of different folders stay apart; the name gives way first.
struct NameFolderLayout: Layout {
    var gap: CGFloat
    var folderTail: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        let natural = ideal.map(\.width).reduce(0, +) + gap * CGFloat(max(ideal.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let name = subviews.first else { return }
        let ideal = name.sizeThatFits(.unspecified).width
        let w = subviews.count > 1 ? nameFolderWidths(width: bounds.width, name: ideal, gap: gap, folderTail: folderTail)
                                   : (name: min(ideal, bounds.width), folder: 0)
        name.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w.name, height: bounds.height))
        guard subviews.count > 1 else { return }
        // A cut name draws narrower than offered: the folder follows the drawn name and takes the slack.
        let drawn = min(name.sizeThatFits(ProposedViewSize(width: w.name, height: bounds.height)).width, w.name)
        subviews[1].place(at: CGPoint(x: bounds.minX + drawn + gap, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: w.folder + w.name - drawn, height: bounds.height))
    }
}

/// The name's and the folder's widths in a row `width` wide: the folder keeps `folderTail` (at most half the row),
/// the name the rest up to its own width, the folder anything left after that.
func nameFolderWidths(width: CGFloat, name: CGFloat, gap: CGFloat, folderTail: CGFloat) -> (name: CGFloat, folder: CGFloat) {
    let tail = min(folderTail, max(width / 2, 0))
    let nameWidth = max(min(name, width - gap - tail), 0)
    return (nameWidth, max(width - nameWidth - gap, 0))
}

/// What a folder shown head-truncated needs to keep its last component whole: «…web» (or «web» when it is all).
@MainActor func folderTailWidth(_ dir: String) -> CGFloat {
    let last = (dir as NSString).lastPathComponent
    let text = last == dir ? last : "…" + last
    return ceil((text as NSString).size(withAttributes: [.font: Theme.Typography.caption.nsFont()]).width) + 1
}

/// The folder of a Changes / Search row: `text3`, cut from the head so its last component stays.
struct FolderText: View {
    let dir: String

    var body: some View {
        Text(dir)
            .font(Theme.Typography.caption.font())
            .foregroundStyle(Theme.ui.text3)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}

/// «Файлы» of a chat without a project takes files from Finder (copies, never moves); the target shows the focus ring.
private struct FreeChatDrop: ViewModifier {
    let app: AppState
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Theme.ui.accent, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.ui.accent.opacity(Theme.Opacity.ring), lineWidth: Theme.focusRing))
                    .padding(Theme.Space.s2)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for p in providers {
                        let url: URL? = await withCheckedContinuation { c in
                            _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                        }
                        if let url { urls.append(url) }
                    }
                    app.dropIntoChats(urls)
                }
                return true
            }
    }
}
