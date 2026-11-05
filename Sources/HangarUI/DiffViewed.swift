import Foundation
import Git
import SwiftUI

/// The diff header's review controls, rightmost so nothing moves when the Monaco controls before them hide (HD-147):
/// «Код · Просмотр» (an HTML / Markdown / SVG file of this Mac) and «Просмотрено» (a Changes file, not a commit's).
struct DiffReviewControls: View {
    let app: AppState
    let tab: DiffTab
    let isText: Bool

    var body: some View {
        if previewEligible(path: tab.path, isText: isText, local: app.selectedProjectIsLocal) {
            RenderSwitch(app: app)
        }
        if tab.commit == nil, app.inspector.changes?.files.contains(where: { $0.path == tab.path }) == true {
            let viewed = app.viewedChanges.contains(tab.path)
            Chip(title: L10n.diffViewed, icon: .check, on: viewed, toggles: true) { app.toggleDiffViewed() }
                .help((viewed ? L10n.diffUnmarkViewed : L10n.diffMarkViewed) + " — " + DiffChangeKey.viewed)
        }
    }
}

/// What a «Просмотрено» mark is bound to (HD-147): the diff's base, the change and the file on disk (size and mtime;
/// `root` nil — a server's project — the line counts instead). Any change of it drops the mark.
func viewStamp(_ file: ChangedFile, from: String, root: String?) -> String {
    let head = "\(from)|\(file.change)|\(file.origPath ?? "")|"
    guard let root else {
        // shortcut: on a server only the counts tell an edit (no stat there); same-count edits keep the mark.
        // An untracked file's count arrives after the list: it would drop a fresh mark.
        return head + (file.change == .untracked ? "" : "\(file.added ?? -1)|\(file.deleted ?? -1)")
    }
    let a = try? FileManager.default.attributesOfItem(atPath: root + "/" + file.path)
    let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
    let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return head + "\(size)|\(mtime)"
}

/// Paths of `files` whose mark still matches their stamp; costs one stat per mark, not per file.
func viewedPaths(_ marks: [String: String], files: [ChangedFile], stamp: (ChangedFile) -> String) -> Set<String> {
    guard !marks.isEmpty else { return [] }
    var result: Set<String> = []
    for file in files where marks[file.path] != nil && marks[file.path] == stamp(file) { result.insert(file.path) }
    return result
}

/// The file after `current` in list order that is not viewed, wrapping to the top; nil — all others are viewed.
func nextUnviewed(_ files: [String], after current: String, viewed: Set<String>) -> String? {
    let start = (files.firstIndex(of: current) ?? -1) + 1
    let order = files[min(start, files.count)...] + files[..<min(start, files.count)]
    return order.first { $0 != current && !viewed.contains($0) }
}

extension AppState {
    private var viewedContext: (task: UUID, changes: ChangeSet, root: String?)? {
        guard let task = selectedTask, inspector.shownTaskId == task.id, let changes = inspector.changes,
              let project = project(task.projectId) else { return nil }
        return (task.id, changes, runner(for: project).isLocal ? inspector.root : nil)
    }

    /// Changes rows of the selected chat marked «Просмотрено» whose file hasn't changed since.
    var viewedChanges: Set<String> {
        guard let c = viewedContext, let marks = viewedFiles[c.task] else { return [] }
        return viewedPaths(marks, files: c.changes.files) { viewStamp($0, from: c.changes.from, root: c.root) }
    }

    /// ⌥V / «Просмотрено» in the diff header: marks the shown Changes file and opens the next unviewed one,
    /// or clears the mark. A commit's file (Git tab) has no mark.
    func toggleDiffViewed() {
        guard let tab = activeDiff, tab.commit == nil, let c = viewedContext,
              let file = c.changes.files.first(where: { $0.path == tab.path }) else { return }
        var viewed = viewedChanges
        if viewed.contains(file.path) {
            viewedFiles[c.task]?[file.path] = nil
            return
        }
        viewedFiles[c.task, default: [:]][file.path] = viewStamp(file, from: c.changes.from, root: c.root)
        viewed.insert(file.path)
        if let next = nextUnviewed(c.changes.files.map(\.path), after: file.path, viewed: viewed) { openDiff(path: next) }
    }
}
