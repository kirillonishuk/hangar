import AppKit
import Git
import SwiftUI

/// One row of the diff tab.
enum DiffRow: Equatable, Identifiable {
    /// «Режим 100644 → 100755», «Переименован из …».
    case meta(String)
    case hunk(String)
    case line(DiffLine)
    /// Binary, too large, not a file, no longer changed, git error.
    case notice(String)

    /// Kind + text, not line numbers, so a line keeps it when lines are inserted above. Identical lines share it:
    /// `diffRowIds` adds the base position and the occurrence.
    var id: String {
        switch self {
        case .meta(let s): "m" + s
        case .hunk(let h): "h" + h
        case .notice(let s): "n" + s
        case .line(let l):
            switch l.kind {
            case .added: "+" + l.text
            case .deleted: "-" + l.text
            case .context: " " + l.text
            }
        }
    }
}

/// Rows of the diff tab; loading shows none (no flash while switching files).
@MainActor func diffRows(_ state: DiffState, origPath: String?) -> [DiffRow] {
    switch state {
    case .none, .loading: return []
    case .notChanged: return [.notice(L10n.diffNotChanged)]
    case .failed(let message): return [.notice(L10n.gitFailed(message))]
    case .loaded(let diff):
        switch diff {
        case .binary: return [.notice(L10n.diffBinary)]
        case .tooLarge(let n): return [.notice(L10n.diffTooLarge(n))]
        case .notAFile: return [.notice(L10n.diffNotAFile)]
        case .text(let hunks, let oldMode, let newMode):
            var rows: [DiffRow] = []
            if let origPath { rows.append(.meta(L10n.diffRenamedFrom(origPath))) }
            // A new or deleted file has one mode only: that is not a mode change.
            if let oldMode, let newMode, oldMode != newMode { rows.append(.meta(L10n.diffModeChange(oldMode, newMode))) }
            for hunk in hunks {
                rows.append(.hunk(hunk.header))
                rows.append(contentsOf: hunk.lines.map(DiffRow.line))
            }
            return rows
        }
    }
}

/// `+c` of `@@ -a,b +c,d @@`.
private func newStart(_ header: String) -> Int? {
    header.firstMatch(of: /\+(\d+)/).flatMap { Int($0.1) }
}

/// The line ↩ / double-click opens (nil: nothing to open, e.g. a deleted file `+0,0` or no hunks).
/// Selected: its new line; a deleted one — the next non-deleted line of its hunk, else the hunk's start.
/// None selected: the first added line, else the first hunk's start.
func openTarget(rows: [DiffRow], selected: Int?) -> Int? {
    let line: Int?
    if let selected, rows.indices.contains(selected) {
        var hunkStart: Int?
        for i in stride(from: selected, through: 0, by: -1) {
            if case .hunk(let h) = rows[i] { hunkStart = newStart(h); break }
        }
        switch rows[selected] {
        case .hunk(let h): line = newStart(h)
        case .line(let l) where l.kind != .deleted: line = l.newLine
        case .line:
            var next: Int?
            for row in rows[(selected + 1)...] {
                guard case .line(let l) = row else { break }  // the hunk ends
                if l.kind != .deleted { next = l.newLine; break }
            }
            line = next ?? hunkStart
        case .meta, .notice: line = nil
        }
    } else {
        let firstAdded = rows.lazy.compactMap { row -> Int? in
            if case .line(let l) = row, l.kind == .added { return l.newLine }
            return nil
        }.first
        let firstHunk = rows.lazy.compactMap { row -> Int? in
            if case .hunk(let h) = row { return newStart(h) }
            return nil
        }.first
        line = firstAdded ?? firstHunk
    }
    guard let line, line > 0 else { return nil }
    return line
}

/// `-a` of `@@ -a,b +c,d @@`.
private func oldStart(_ header: String) -> Int? {
    header.firstMatch(of: /-(\d+)/).flatMap { Int($0.1) }
}

/// Unique row ids that survive lines inserted above (the selection follows them across reloads). Worktree edits keep
/// the base side, so a context/deleted line is keyed by its base line, an added one by the base line it follows, a hunk
/// by its base start; identical keys are counted from the end, so an insertion above does not shift them.
func diffRowIds(_ rows: [DiffRow]) -> [String] {
    var after = 0
    let keys = rows.map { row -> String in
        switch row {
        case .hunk(let h):
            let start = oldStart(h) ?? 0
            after = start - 1
            return "h\(start)"
        case .line(let l):
            if l.kind != .added, let old = l.oldLine { after = old }
            return "\(after)" + row.id
        case .meta, .notice: return row.id
        }
    }
    var occurrences: [String: Int] = [:]
    var ids = keys
    for i in keys.indices.reversed() {
        let n = occurrences[keys[i], default: 0]
        occurrences[keys[i]] = n + 1
        ids[i] = "\(n)#" + keys[i]
    }
    return ids
}

/// Rows of one load with their stable ids and the widths, computed once per `DiffState` (not per redraw).
struct DiffContent {
    struct Item: Identifiable {
        let id: String
        let index: Int
        let row: DiffRow
    }
    var rows: [DiffRow] = []
    var items: [Item] = []
    var indexById: [String: Int] = [:]
    var added = 0
    var deleted = 0
    var isText = false
    /// Longest line in characters (tabs as `tabWidth`): rows are this wide, so the background reaches the edge
    /// and the horizontal range doesn't change while lazily scrolling.
    var maxChars = 0
    /// Bumped on every recompute (cheap equality for the list).
    var version = 0
    /// nil: unknown language, not text, or too large to color.
    var highlighter: DiffHighlighter?
}

/// shortcut: tabs shown as 4 spaces (Helix's default), when the editor's tab width is known — use it.
let diffTabWidth = 4

/// A diff line as shown (and highlighted): tabs expanded.
func diffDisplayText(_ text: String) -> String {
    text.contains("\t") ? text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: diffTabWidth)) : text
}

/// shortcut: bigger diffs stay plain (bounded work on main), raise when highlighting moves off main.
let diffHighlightMaxBytes = 1_000_000

@MainActor final class DiffContentCache {
    private var key: (state: DiffState, origPath: String?, path: String)?
    private var content = DiffContent()

    /// `path` picks the highlighting language.
    func content(_ state: DiffState, origPath: String?, path: String = "") -> DiffContent {
        if let key, key.origPath == origPath, key.path == path, key.state == state { return content }
        key = (state, origPath, path)
        var c = DiffContent()
        c.version = content.version + 1
        c.rows = diffRows(state, origPath: origPath)
        var bytes = 0
        let ids = diffRowIds(c.rows)
        c.items.reserveCapacity(c.rows.count)
        for (i, row) in c.rows.enumerated() {
            let id = ids[i]
            c.items.append(.init(id: id, index: i, row: row))
            c.indexById[id] = i
            if case .line(let l) = row {
                if l.kind == .added { c.added += 1 } else if l.kind == .deleted { c.deleted += 1 }
                let tabs = l.text.utf8.reduce(0) { $1 == 9 ? $0 + 1 : $0 }
                c.maxChars = max(c.maxChars, l.text.count + tabs * (diffTabWidth - 1))
                bytes += l.text.utf8.count
            } else if case .hunk(let h) = row {
                c.maxChars = max(c.maxChars, h.count)
            }
        }
        if case .loaded(.text) = state { c.isText = true }
        if c.isText, bytes <= diffHighlightMaxBytes, let lang = syntaxLanguage(forPath: path) {
            c.highlighter = DiffHighlighter(lang: lang, rows: c.rows)
        }
        content = c
        return content
    }
}

/// The shown diff tab: path header with `+N −M`, then the unified diff.
struct DiffView: View {
    let app: AppState

    var body: some View {
        if let tab = app.activeDiff {
            let content = app.activeDiffContent
            VStack(spacing: 0) {
                header(tab.path, content)
                DiffLines(content: content, selected: app.activeDiffSelection,
                          select: { app.selectDiffRow($0) }, open: { app.openActiveDiffInEditor() })
                    .equatable()
                    .id(tab.path)  // another file starts at the top
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.ui.panel)
        } else {
            Theme.ui.panel
        }
    }

    private func header(_ path: String, _ content: DiffContent) -> some View {
        HStack(spacing: Theme.Diff.headerGap) {
            Text(verbatim: path).foregroundStyle(Theme.ui.textStrong).fontWeight(.medium)
                .lineLimit(1).truncationMode(.head)
            if content.isText {
                Text(verbatim: "+\(content.added)").foregroundStyle(Theme.Diff.badgeA)
                Text(verbatim: "−\(content.deleted)").foregroundStyle(Theme.Diff.badgeD)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: Theme.Diff.font, design: .monospaced))
        .padding(.vertical, Theme.Diff.headerPaddingV)
        .padding(.horizontal, Theme.Diff.headerPaddingH)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }
}

/// Redrawn only when the load or the selection changes (closures are not compared).
private struct DiffLines: View, Equatable {
    let content: DiffContent
    let selected: Int?
    let select: (Int?) -> Void
    let open: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.content.version == b.content.version && a.selected == b.selected }

    private static let charWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: Theme.Diff.font, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    var body: some View {
        GeometryReader { geo in
            let textWidth = CGFloat(content.maxChars) * Self.charWidth
            let lineWidth = Theme.Diff.gutter + Theme.Diff.paddingH + Theme.Diff.markerWidth + textWidth + Theme.Diff.headerPaddingH
            let width = max(geo.size.width, lineWidth)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.items) { item in
                        // Only rows the lazy stack renders are highlighted.
                        DiffRowView(row: item.row, highlighted: highlighted(item), selected: item.index == selected, width: width)
                            .contentShape(Rectangle())
                            .onTapGesture { tap(item) }
                            .pointingHand(item.row.isClickable)
                    }
                }
                .padding(.bottom, Theme.Diff.headerPaddingV)
            }
            // A two-axis scroll view starts centered (and centers smaller content): start at the top left.
            .defaultScrollAnchor(.topLeading)
        }
    }

    private func highlighted(_ item: DiffContent.Item) -> AttributedString? {
        guard let h = content.highlighter, case .line(let l) = item.row else { return nil }
        return h.text(at: item.index, diffDisplayText(l.text))
    }

    /// One tap handler: a separate count-2 gesture would delay every single click.
    private func tap(_ item: DiffContent.Item) {
        guard item.row.isClickable else { return }
        select(item.index)
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open() }
    }
}

private extension DiffRow {
    var isClickable: Bool {
        switch self {
        case .hunk, .line: true
        case .meta, .notice: false
        }
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    /// The line's text with syntax colors (nil: plain).
    let highlighted: AttributedString?
    let selected: Bool
    /// The background reaches the right edge (or the longest line).
    let width: CGFloat

    var body: some View {
        content
            .font(.system(size: Theme.Diff.font, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: width, alignment: .leading)
            .background(background)
            .overlay { if selected { Theme.ui.selection.opacity(Theme.Diff.selectedOpacity) } }
    }

    @ViewBuilder private var content: some View {
        switch row {
        case .meta(let text), .notice(let text):
            Text(verbatim: text)
                .foregroundStyle(Theme.ui.text3)
                .padding(.vertical, Theme.Diff.headerPaddingV)
                .padding(.horizontal, Theme.Diff.headerPaddingH)
        case .hunk(let header):
            Text(verbatim: header.replacingOccurrences(of: "\t", with: String(repeating: " ", count: diffTabWidth)))
                .foregroundStyle(Theme.Diff.hunk)
                .padding(.vertical, Theme.Diff.hunkPaddingV)
                .padding(.horizontal, Theme.Diff.headerPaddingH)
        case .line(let line):
            HStack(spacing: 0) {
                // One column: the new number at added/context lines, the old one at deleted lines.
                Text(verbatim: (line.kind == .deleted ? line.oldLine : line.newLine).map(String.init) ?? "")
                    .foregroundStyle(Theme.ui.text3)
                    .frame(width: Theme.Diff.gutter, alignment: .trailing)
                    .padding(.trailing, Theme.Diff.paddingH)
                Text(verbatim: line.kind == .added ? "+" : line.kind == .deleted ? "-" : "")
                    .foregroundStyle(line.kind == .added ? Theme.Diff.addMarker : Theme.Diff.delMarker)
                    .frame(width: Theme.Diff.markerWidth, alignment: .leading)
                Group {
                    if let highlighted { Text(highlighted) } else { Text(verbatim: diffDisplayText(line.text)) }
                }
                    .foregroundStyle(Theme.ui.text)
                    .padding(.trailing, Theme.Diff.headerPaddingH)
            }
            .padding(.vertical, Theme.Diff.linePaddingV)
        }
    }

    private var background: Color {
        switch row {
        case .hunk: Theme.Diff.hunkBg
        case .line(let l) where l.kind == .added: Theme.Diff.add
        case .line(let l) where l.kind == .deleted: Theme.Diff.del
        default: .clear
        }
    }
}

/// Takes the keyboard while the diff tab is shown, so typing never reaches the hidden terminal.
final class DiffHostView: NSHostingView<DiffView> {
    override var acceptsFirstResponder: Bool { true }
}
