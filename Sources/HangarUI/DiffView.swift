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

/// shortcut: tabs shown as 4 spaces (the editor's default), when the editor's tab width is known — use it.
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

/// The shown diff tab: path header with `+N −M` and the side-by-side / inline switch, then Monaco's diff editor
/// (#80); binary, too large and failed diffs show their notice instead.
struct DiffView: View {
    let app: AppState
    /// Its task: another task's diff never loads into this page.
    let taskId: UUID
    let editor: DiffEditorController

    var body: some View {
        if app.selectedTask?.id == taskId, let tab = app.activeDiff {
            let content = app.activeDiffContent
            VStack(spacing: 0) {
                header(tab.path, commit: tab.commit, content)
                ForEach(Array(notes(content).enumerated()), id: \.offset) { _, text in
                    Text(verbatim: text)
                        .font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Diff.headerPaddingV)
                        .padding(.horizontal, Theme.Diff.headerPaddingH)
                }
                // Monaco found nothing and git counts no lines either (not an EOL-only diff): a strip, the editor stays usable.
                if content.isText, editor.changes.isEmpty, content.added + content.deleted == 0 {
                    Text(verbatim: L10n.diffNoChanges)
                        .font(Theme.Typography.mono.font())
                        .foregroundStyle(Theme.ui.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Diff.headerPaddingV)
                        .padding(.horizontal, Theme.Diff.headerPaddingH)
                }
                if content.isText {
                    MonacoDiffView(editor: editor)
                        // Every new load (another file, a refresh after an edit on disk) goes to the page.
                        .task(id: "\(tab.path)|\(tab.commit ?? "")|\(content.version)") { await editor.load(tab) }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.ui.panel)
        } else {
            Theme.ui.panel
        }
    }

    /// «Переименован из …», a mode change, or the notice that replaces the diff.
    private func notes(_ content: DiffContent) -> [String] {
        content.rows.compactMap { row in
            switch row {
            case .meta(let s), .notice(let s): s
            case .hunk, .line: nil
            }
        }
    }

    private func header(_ path: String, commit: String?, _ content: DiffContent) -> some View {
        HStack(spacing: Theme.Diff.headerGap) {
            HStack(spacing: Theme.iconGap) {
                FileIconView(name: (path as NSString).lastPathComponent)
                Text(verbatim: path).foregroundStyle(Theme.ui.textStrong).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.head)
            }
            // A commit's file (Git tab): which commit, as the details show its hash.
            if let commit { Text(verbatim: String(commit.prefix(7))).foregroundStyle(Theme.ui.accentText) }
            // No «+N −M» here: the Changes (or commit) row beside it already shows the counts.
            Spacer(minLength: 0)
            if content.isText {
                changeNav
                HStack(spacing: Theme.GitTab.chipGap) {
                    modeButton(L10n.diffSideBySide, inline: false)
                    modeButton(L10n.diffInline, inline: true)
                }
            }
        }
        .font(Theme.Typography.mono.font())
        .padding(.horizontal, Theme.Diff.headerPaddingH)
        // The slot of the editor's file-tab row: switching editor ↔ diff doesn't move the code.
        .frame(height: Theme.Editor.headerHeight)
        .background(Theme.ui.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    /// «2 из 5» with ↑ ↓ (F7 / ⇧F7); the counter's slot is always there, so nothing shifts while the diff computes.
    private var changeNav: some View {
        let counter = editor.changes
        return HStack(spacing: Theme.Diff.headerGap / 2) {
            Text(verbatim: counter.text ?? "").foregroundStyle(Theme.ui.text2).monospacedDigit()
                .frame(minWidth: Theme.Diff.counterWidth, alignment: .trailing)
            navButton(.chevronUp, help: L10n.diffPrevChange + " — " + DiffChangeKey.prev, next: false)
            navButton(.chevronDown, help: L10n.diffNextChange + " — " + DiffChangeKey.next, next: true)
        }
        .padding(.trailing, Theme.Diff.headerGap)
    }

    private func navButton(_ icon: Icon, help: String, next: Bool) -> some View {
        let enabled = editor.changes.canStep
        return Button { editor.goChange(next: next) } label: {
            IconView(icon: icon, size: Theme.smallIconSize, tint: Theme.ui.text2)
                .frame(width: Theme.Diff.navButtonWidth, height: Theme.Diff.navButtonHeight)
                .overlay(RoundedRectangle(cornerRadius: Theme.Diff.navButtonRadius).strokeBorder(Theme.ui.line, lineWidth: 1))
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.Diff.navButtonRadius))
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Input.disabledOpacity)
        .help(help)
    }

    /// Side by side / inline as mode chips; the choice persists (`WorkspaceState.diffInline`).
    private func modeButton(_ title: String, inline: Bool) -> some View {
        Chip(title: title, on: app.state.diffInline == inline) {
            app.perform { $0.diffInline = inline }
            editor.setInline(inline)
        }
        .fixedSize()
    }
}

/// The diff page's web view inside the SwiftUI tab (one view for the controller's life, reparented as needed).
private struct MonacoDiffView: NSViewRepresentable {
    let editor: DiffEditorController
    func makeNSView(context: Context) -> NSView { editor.container }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Takes the keyboard while the diff tab is shown, so typing never reaches the hidden terminal.
final class DiffHostView: NSHostingView<DiffView> {
    override var acceptsFirstResponder: Bool { true }
}
