import AppKit
import Git
import Workspace

/// The diff tab's Monaco diff editor (#80): base on the left (read-only), the working file on the right — editable and
/// saved like the editor's files for the session's changes, read-only for a commit's file. Lives while the task has a
/// diff tab (`TerminalArea`).
@MainActor final class DiffEditorController {
    let page: MonacoPage
    /// The web view's holder inside SwiftUI (the page stays the same while files change).
    let container = NSView()
    private let app: AppState
    private var session: EditorSession?
    /// The editable working file shown on the right, if any.
    private var editablePath: String?
    private var shown: EditorDiff?
    private var shownKey: String?

    init(app: AppState) {
        self.app = app
        page = MonacoPage(mode: .diff, inline: app.state.diffInline, minimap: false)
        page.webView.frame = container.bounds
        page.webView.autoresizingMask = [.width, .height]
        container.addSubview(page.webView)
        page.onMessage = { [weak self] in self?.handle($0) }
    }

    func tearDown() { page.tearDown() }

    var hasUnsaved: Bool { editablePath.map { session?.isDirty($0) == true } ?? false }

    func setInline(_ inline: Bool) { page.send(.options(inline: inline, minimap: false)) }

    /// Loads both sides of the shown diff tab and hands them to the page; a refresh of the same file keeps an edited
    /// buffer (a change on disk then shows the conflict bar instead).
    func load(_ tab: DiffTab) async {
        guard let task = app.selectedTask, let project = app.project(task.projectId) else { return }
        let key = tab.path + "|" + (tab.commit ?? "")
        if key == shownKey, let path = editablePath, let session, session.isDirty(path) {
            await session.checkDisk()
            return
        }
        let git = { (root: String) in Git(repo: root, runner: self.app.runner(for: project)) }
        var diff: EditorDiff
        if let hash = tab.commit {
            guard let root = app.gitPanel.root else { return }
            let original = (try? await git(root).show(rev: hash + "^", path: tab.origPath ?? tab.path)) ?? nil
            let modified = (try? await git(root).show(rev: hash, path: tab.path)) ?? nil
            diff = EditorDiff(name: tab.path, original: original ?? "", modified: modified ?? "", path: nil, line: nil)
            session = nil
        } else {
            guard let root = app.inspector.root, let changes = app.inspector.changes,
                  let file = changes.files.first(where: { $0.path == tab.path }) else { return }
            let added = file.change == .untracked || file.change == .added
            let original = added ? nil : (try? await git(root).show(rev: changes.from, path: "./" + (file.origPath ?? file.path))) ?? nil
            let io = app.editorIO(host: project.host)
            let full = root + "/" + tab.path
            let s = EditorSession(io: io) { [page] in page.send($0) }
            diff = EditorDiff(name: tab.path, original: original ?? "", modified: "", path: nil, line: nil)
            if file.change != .deleted, let opened = await s.adopt(path: full) {
                diff.modified = opened.text
                if !opened.readOnly { diff.path = full }
            }
            session = s
        }
        guard !Task.isCancelled, app.activeDiff.map({ $0.path + "|" + ($0.commit ?? "") }) == key else { return }
        editablePath = diff.path
        shownKey = key
        guard diff != shown else { return }  // e.g. the refresh after our own save
        shown = diff
        page.send(.diff(diff))
    }

    private func handle(_ m: BridgeMessage) {
        switch m {
        case .ready: if let shown { page.send(.diff(shown)) }  // a reloaded page (the first load is queued)
        case .changed, .save, .conflict: Task { await session?.handle(m) }
        case .focus: if let session, !session.io.isLocal { Task { await session.checkDisk() } }
        case .openAt(let line, let column): app.openActiveDiffInEditor(line: line, column: column)
        case .openFile(let path, let line, let column): app.openInEditor(path: path, line: line, column: column)
        case .request(let r):
            // shortcut: the diff's buffer is not sent to tsserver; it answers only for a file also open in an editor tab.
            let host = app.selectedTask.flatMap { app.project($0.projectId)?.host }
            Task {
                let result = await app.languages.request(r, host: host) { _ in nil }
                page.send(.resolve(id: r.id, result: result))
            }
        default: break
        }
    }

    /// Before the diff tab shows another file or closes: an edited buffer is saved, dropped or kept (Cancel).
    func confirmLeave(_ then: @escaping () -> Void) {
        guard hasUnsaved, let path = editablePath, let window = page.webView.window else { then(); return }
        let alert = NSAlert()
        alert.messageText = L10n.editorUnsavedTitle((path as NSString).lastPathComponent)
        alert.informativeText = L10n.editorUnsavedInfo
        alert.addButton(withTitle: L10n.save)
        alert.addButton(withTitle: L10n.editorDontSave)
        alert.addButton(withTitle: L10n.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    Task {
                        if let text = await self.page.text(of: path) { await self.session?.handle(.save(file: path, text: text)) }
                        if !self.hasUnsaved { then() }
                    }
                case .alertSecondButtonReturn:
                    self.session = nil
                    self.editablePath = nil
                    self.shown = nil  // the same file again is sent afresh, without the dropped edits
                    then()
                default: break
                }
            }
        }
    }
}
