import Git
import SwiftUI

/// Right column (decision #44): segment Files / Changes N / Git (git only) / Search (#91), the lazy file tree or the changes list.
/// Top: the segment in a tab-bar-high row, so its bottom line continues the tab bar's.
struct InspectorView: View {
    let app: AppState
    private var model: InspectorModel { app.inspector }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let text = app.inspectorNotice {
                notice(text)
                Spacer(minLength: 0)
            } else if model.segment == .changes && model.isGit {
                ChangesList(app: app, model: model)
            } else if model.segment == .git && model.isGit {
                GitPanelView(app: app)
            } else if model.segment == .search {
                SearchPanel(app: app)
            } else {
                FilesList(app: app, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ui.inspector)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 0) {
            if app.inspectorNotice == nil { segment }
        }
        .padding(.horizontal, Theme.inspectorSegmentPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.tabBarHeight, maxHeight: Theme.tabBarHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    /// Equal parts (Changes at least its label and badge), so a changing count never moves the labels; a plain folder
    /// has only Files and Search.
    private var segment: some View {
        HStack(spacing: 0) {
            segmentItem(L10n.segmentFiles, .files, help: L10n.help(L10n.showFiles, .inspectorFiles))
            if model.isGit {
                let count = model.changes?.files.count ?? 0
                SegmentItem(title: L10n.segmentChangesTitle, badge: segmentBadge(count), reserveBadge: true, on: model.segment == .changes) {
                    model.segment = .changes
                }
                .help(L10n.help(L10n.statusShowChanges, .inspectorChanges))
                .accessibilityLabel(L10n.segmentChanges(count))
                segmentItem(L10n.segmentGit, .git, help: L10n.help(L10n.showGit, .inspectorGit))
            }
            segmentItem(L10n.segmentSearch, .search, help: L10n.help(L10n.findInFiles, .findInFiles))
        }
        .padding(Theme.segmentPadding)
        // As the settings segment: on `bg` a `panel` track alone would be invisible.
        .background(RoundedRectangle(cornerRadius: Theme.inspectorSegmentRadius).fill(Theme.ui.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.inspectorSegmentRadius).stroke(Theme.ui.control, lineWidth: 1))
        .animation(Motion.ease(Theme.selectionFade), value: model.segment)
    }

    private func segmentItem(_ title: String, _ value: InspectorModel.Segment, help: String) -> some View {
        SegmentItem(title: title, on: model.segment == value) { model.segment = value }.help(help)
    }
}

/// The Changes count as a segment badge: none at 0, «99+» past 99.
func segmentBadge(_ count: Int) -> String? {
    count <= 0 ? nil : count > 99 ? "99+" : String(count)
}

/// One part of the Files / Changes / Git / Search segment; an inactive one lights up on hover.
private struct SegmentItem: View {
    let title: String
    var badge: String? = nil
    /// Keeps the badge's room even without one, so a count appearing or growing never resizes the parts.
    var reserveBadge = false
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let lit = hover && !on
        HStack(spacing: Theme.segmentBadgeGap) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge { SegmentBadge(text: badge, on: on) }
        }
        .font(Theme.Typography.secondary.font())
        .foregroundStyle(on ? Theme.ui.textStrong : lit ? Theme.ui.text : Theme.ui.text2)
        .padding(.vertical, Theme.segmentItemPaddingV)
        .padding(.horizontal, Theme.segmentBadgeGap)
        .frame(minWidth: reserveBadge ? Self.reserved(title) : 0, maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.inspectorSegmentItemRadius).fill(on ? Theme.ui.moreBg : lit ? Theme.ui.segmentHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .pointingHand(!on)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// Label + gap + a two-digit badge + side paddings («99+» may grow it a little).
    private static func reserved(_ title: String) -> CGFloat {
        let label = ceil((title as NSString).size(withAttributes: [.font: Theme.Typography.secondary.nsFont()]).width)
        return label + Theme.segmentBadgeGap * 3 + SegmentBadge.width("00")
    }
}

/// The count after a segment label: a small muted pill, digits in fixed width.
private struct SegmentBadge: View {
    let text: String
    let on: Bool

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.caption.font().monospacedDigit())
            .foregroundStyle(on ? Theme.ui.text : Theme.ui.text2)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: Self.width("0") - Theme.segmentBadgePaddingH * 2)
            .padding(.horizontal, Theme.segmentBadgePaddingH)
            .frame(height: Theme.segmentBadgeHeight)
            .background(Capsule().fill(Theme.ui.text3.opacity(on ? Theme.segmentBadgeOnOpacity : Theme.segmentBadgeOpacity)))
    }

    /// Width of a badge with `digits` (at least round: as tall as wide).
    static func width(_ digits: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Typography.caption.size, weight: .regular)
        let text = ceil((digits as NSString).size(withAttributes: [.font: font]).width)
        return max(text + Theme.segmentBadgePaddingH * 2, Theme.segmentBadgeHeight)
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
    return FileMenuItem.items(remote: host != nil).filter { opens || $0 != .openInEditorTab }.map { item in
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
            if let empty = model.emptyFilesNotice { notice(empty) }
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
            return { row.expanded ? model.collapse(entry.path) : model.expand(entry.path) }
        }
        guard entry.opensInEditor, let root = model.root else { return nil }
        // One click previews (one reused tab), a double click keeps the tab (as in VS Code, #83).
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
                    IconView(icon: row.expanded ? .chevronDown : .chevronRight, size: Theme.smallIconSize)
                } else {
                    Color.clear.frame(width: Theme.smallIconSize, height: Theme.smallIconSize)
                }
                FileIconView(name: row.entry.name, isDir: row.entry.isDir || row.entry.isDirLink, expanded: row.expanded)
                Text(row.entry.name)
                    .font(Theme.Typography.body.font())
                    .foregroundStyle(Theme.ui.textRow)
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
                        if changes.files.isEmpty { notice(L10n.noChanges) }
                        let columns = ChangeColumns(changes.files)
                        ForEach(changes.files) { file in
                            ChangeRow(file: file, columns: columns, selected: file.path == model.diffPath) { app.openDiff(path: file.path) }
                                .popoverContextMenu { fileMenu(app: app, relative: file.path, opens: file.change != .deleted) }
                        }
                    }
                }
                .padding(.vertical, Theme.fileRowPaddingV)
            }
        }
    }

    /// The list's header: two mode chips, the chosen one lit (controls-v2 B′); ⌥B switches, the key is in the tooltip.
    /// Always there (empty while loading), so the rows never move; without a base the second chip is dimmed.
    private var modeLine: some View {
        let onBase = if case .base = model.changes?.mode { true } else { false }
        let base: String? = if case .base(let b) = model.changes?.mode { b } else { model.baseName }
        let hasBase = base != nil && model.changes?.baseMissing != true
        return HStack(spacing: Theme.GitTab.chipGap) {
            ModeChip(title: L10n.changesHintUncommitted, on: model.changes != nil && !onBase) { model.toggleMode() }
                .fixedSize()
                .help(L10n.changesHintToUncommitted)
            ModeChip(title: base ?? L10n.changesBaseNone, icon: .branch, mono: base != nil, on: onBase, enabled: hasBase) { model.toggleMode() }
                .help(hasBase ? L10n.changesHintToBase(base ?? "") : base.map(L10n.baseMissing) ?? L10n.baseMissingUnknown)
            Spacer(minLength: 0)
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
    let action: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HoverRow(selected: selected, action: action) { _ in
            HStack(spacing: Theme.inlineGap) {
                FileIconView(name: name)
                NameFolderLayout(gap: Theme.inlineGap, minFolder: Theme.rowFolderMin) {
                    Text(name)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !dir.isEmpty {
                        Text(dir)
                            .font(Theme.Typography.caption.font())
                            .foregroundStyle(Theme.ui.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
                Text(verbatim: file.added.map { "+\($0)" } ?? "")
                    .foregroundStyle(Theme.Diff.badgeA)
                    .frame(width: columns.added, alignment: .trailing)
                Text(verbatim: file.deleted.map { "−\($0)" } ?? "")
                    .foregroundStyle(Theme.Diff.badgeD)
                    .frame(width: columns.deleted, alignment: .trailing)
                changeBadge(file.change)
                    .frame(width: Theme.GitTab.badgeWidth, alignment: .center)
            }
            .font(Theme.Typography.monoSmall.font())
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, Theme.fileRowPaddingV)
        }
        .help(file.origPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// A file name, then its folder in the room left after it — dropped (laid out at zero width) when less than
/// `minFolder` remains, so a tight row shows the whole name rather than a sliver of path.
struct NameFolderLayout: Layout {
    var gap: CGFloat
    var minFolder: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideal.map(\.height).max() ?? 0
        let natural = ideal.map(\.width).reduce(0, +) + gap * CGFloat(max(ideal.count - 1, 0))
        return CGSize(width: proposal.width ?? natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let name = subviews.first else { return }
        let nameWidth = min(name.sizeThatFits(.unspecified).width, bounds.width)
        name.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: nameWidth, height: bounds.height))
        guard subviews.count > 1 else { return }
        let room = folderRoom(width: bounds.width, name: nameWidth, gap: gap, minFolder: minFolder)
        subviews[1].place(at: CGPoint(x: bounds.minX + nameWidth + gap, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: room, height: bounds.height))
    }
}

/// What the folder gets after the name: the rest of the row, or 0 when that is under `minFolder`.
func folderRoom(width: CGFloat, name: CGFloat, gap: CGFloat, minFolder: CGFloat) -> CGFloat {
    let room = width - name - gap
    return room >= minFolder ? room : 0
}
