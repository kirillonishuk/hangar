import Git
import SwiftUI

/// Right column (decision #44): segment Files / Changes N (git only), the lazy file tree or the changes list.
/// Top: a titlebar-high drag zone, then the segment in a tab-bar-high row, so its bottom line continues the tab bar's.
struct InspectorView: View {
    let app: AppState
    private var model: InspectorModel { app.inspector }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Theme.titleBarHeight).background(WindowDragArea())
            header
            if app.selectedTask == nil {
                notice(L10n.inspectorNoTask)
                Spacer(minLength: 0)
            } else if model.segment == .changes && model.isGit {
                ChangesList(app: app, model: model)
            } else {
                FilesList(app: app, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ui.bg)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 0) {
            if app.selectedTask != nil, model.isGit { segment }
        }
        .padding(.horizontal, Theme.inspectorSegmentPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.tabBarHeight, maxHeight: Theme.tabBarHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    /// Equal halves, so a changing count never moves the other label.
    private var segment: some View {
        HStack(spacing: 0) {
            segmentItem(L10n.segmentFiles, .files, help: L10n.help(L10n.showFiles, .inspectorFiles))
            segmentItem(L10n.segmentChanges(model.changes?.files.count ?? 0), .changes, help: L10n.help(L10n.statusShowChanges, .inspectorChanges))
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

/// One half of the Files / Changes segment; an inactive half lights up on hover.
private struct SegmentItem: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let lit = hover && !on
        Text(title)
            .font(.system(size: Theme.fontSize.segment))
            .lineLimit(1)
            .foregroundStyle(on ? Theme.ui.textStrong : lit ? Theme.ui.text : Theme.ui.text2)
            .padding(.vertical, Theme.segmentItemPaddingV)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.inspectorSegmentItemRadius).fill(on ? Theme.ui.control : lit ? Theme.ui.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .pointingHand(!on)
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Context menu of a Files / Changes row (Pane «File previews»); Finder sees only this Mac's disk.
enum FileMenuItem: Equatable, CaseIterable {
    case openInHelix, revealInFinder, copyPath, copyRelativePath

    static func items(remote: Bool) -> [FileMenuItem] { allCases.filter { !remote || $0 != .revealInFinder } }

    /// Pasteboard text of the copy items (a remote path as `host:path`, like the sidebar's «Скопировать путь»).
    func copied(root: String, relative: String, host: String?) -> String? {
        switch self {
        case .copyPath: (host.map { $0 + ":" } ?? "") + root + "/" + relative
        case .copyRelativePath: relative
        case .openInHelix, .revealInFinder: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case .openInHelix: L10n.openInHelix
        case .revealInFinder: L10n.revealInFinder
        case .copyPath: L10n.copyPath
        case .copyRelativePath: L10n.copyRelativePath
        }
    }

    var icon: Icon {
        switch self {
        case .openInHelix: .editor
        case .revealInFinder: .finder
        case .copyPath, .copyRelativePath: .copy
        }
    }
}

/// The menu items for `relative` under the inspector's root; `opens`: the row can open in Helix (not a directory or deleted file).
struct FileMenu: View {
    let app: AppState
    let relative: String
    let opens: Bool

    var body: some View {
        let host = remoteHost(app)
        if let root = app.inspector.root {
            ForEach(FileMenuItem.items(remote: host != nil).filter { opens || $0 != .openInHelix }, id: \.self) { item in
                Button { perform(item, root: root, host: host) } label: {
                    Label { Text(item.title) } icon: { Image(nsImage: item.icon.image) }
                }
            }
        }
    }

    private func perform(_ item: FileMenuItem, root: String, host: String?) {
        let path = root + "/" + relative
        switch item {
        case .openInHelix: app.openInEditor(path: path, line: nil)
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .copyPath, .copyRelativePath:
            guard let text = item.copied(root: root, relative: relative, host: host) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

@MainActor private func remoteHost(_ app: AppState) -> String? {
    app.selectedTask.flatMap { app.project($0.projectId)?.host }
}

/// A one-line `text3` remark above a list (missing base, truncation, git error, no task).
private func notice(_ text: String) -> some View {
    Text(text)
        .font(.system(size: Theme.fontSize.counter))
        .foregroundStyle(Theme.ui.text3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.vertical, Theme.fileRowPaddingV * 2)
}

private func changeBadge(_ change: FileChange?) -> some View {
    Text(verbatim: change?.rawValue ?? "")
        .font(.system(size: Theme.fontSize.counter, weight: .semibold, design: .monospaced))
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
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows(model.tree, expanded: model.expanded)) { row in
                        FileRow(row: row, change: model.badges[row.entry.path], action: action(row))
                            .contextMenu { FileMenu(app: app, relative: row.entry.path, opens: !row.entry.isDir && row.entry.opensInEditor) }
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
        return { app.openInEditor(path: root + "/" + entry.path, line: nil) }
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
                    .font(.system(size: Theme.fontSize.row))
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
                        ForEach(changes.files) { file in
                            ChangeRow(file: file, selected: file.path == model.diffPath) { app.openDiff(path: file.path) }
                                .contextMenu { FileMenu(app: app, relative: file.path, opens: file.change != .deleted) }
                        }
                        hint(changes)
                    }
                }
                .padding(.vertical, Theme.fileRowPaddingV)
            }
        }
    }

    /// Two lines: what is compared, and what ⌥B (or a click here) switches to. A missing base offers nothing.
    @ViewBuilder private func hint(_ changes: ChangeSet) -> some View {
        let lines: (Text, String?) = {
            if case .base(let b) = changes.mode {
                return (monoBranch(L10n.changesHintBase(b), b), L10n.changesHintToUncommitted)
            }
            if changes.baseMissing { return (Text(L10n.changesHintUncommitted), nil) }
            return (Text(L10n.changesHintUncommitted), model.baseName.map(L10n.changesHintToBase))
        }()
        ChangesHint(first: lines.0, second: lines.1) { model.toggleMode() }
    }
}

/// What is compared and what ⌥B switches to: one line each (truncated, never wrapped); clickable when it offers a switch.
private struct ChangesHint: View {
    let first: Text
    let second: String?
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.changesHintLineGap) {
            first
            if let second { Text(second) }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.system(size: Theme.fontSize.counter))
        .foregroundStyle(hover && second != nil ? Theme.ui.text2 : Theme.ui.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.rowPaddingH)
        .padding(.top, Theme.changesHintTop)
        .contentShape(Rectangle())
        .onTapGesture { if second != nil { toggle() } }
        .pointingHand(second != nil)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
    }
}

/// The branch name inside a localized sentence, set in monospaced (DESIGN.md «Моно»: ветки).
private func monoBranch(_ sentence: String, _ branch: String) -> Text {
    guard let r = sentence.range(of: branch, options: .backwards) else { return Text(sentence) }
    let mono = Text(branch).font(.system(size: Theme.fontSize.counter, design: .monospaced))
    return Text(sentence[..<r.lowerBound]) + mono + Text(sentence[r.upperBound...])
}

private struct ChangeRow: View {
    let file: ChangedFile
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let name = (file.path as NSString).lastPathComponent
        let dir = (file.path as NSString).deletingLastPathComponent
        HoverRow(selected: selected, action: action) { _ in
            HStack(spacing: Theme.inlineGap) {
                FileIconView(name: name)
                Text(name)
                    .font(.system(size: Theme.fontSize.row))
                    .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !dir.isEmpty {
                    Text(dir)
                        .font(.system(size: Theme.fontSize.counter))
                        .foregroundStyle(Theme.ui.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if let added = file.added, let deleted = file.deleted {
                    Text(verbatim: "+\(added)").foregroundStyle(Theme.Diff.badgeA)
                    Text(verbatim: "−\(deleted)").foregroundStyle(Theme.Diff.badgeD)
                }
                changeBadge(file.change)
            }
            .font(.system(size: Theme.fontSize.counter, design: .monospaced))
            .padding(.horizontal, Theme.rowPaddingH)
            .padding(.vertical, Theme.fileRowPaddingV)
        }
        .help(file.origPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
