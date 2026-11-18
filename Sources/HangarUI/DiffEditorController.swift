import AppKit
import Git
import Workspace

/// The diff tab's Monaco diff editor (HD-080): base on the left (read-only), the working file on the right — editable and
/// saved like the editor's files for the session's changes, read-only for a commit's file. Lives while the task has a
/// diff tab (`TerminalArea`); its page then goes on to the next diff tab (HD-167).
@MainActor @Observable final class DiffEditorController {
    let page: MonacoPage
    /// The web view's holder inside SwiftUI (the page stays the same while files change).
    let container = ResizeReportingView()
    private let app: AppState
    private var session: EditorSession?
    /// The editable working file shown on the right, if any.
    private var editablePath: String?
    private var shown: EditorDiff?
    /// The file (path and commit) the page shows; the view stays hidden until it is the tab's (a reused page shows the
    /// previous file meanwhile).
    private(set) var shownKey: String?
    /// A load started before the inspector's diff came (`prefetch`): the first load of that file waits for it.
    private var early: (key: String, task: Task<Void, Never>)?
    /// Which change the cursor is at, and how many; unknown until the page has computed the diff.
    private(set) var changes = ChangeCounter()
    /// The shown file has one side only: one column whatever the saved setting (HD-150).
    private(set) var oneSided = false
    /// The pane is narrower than `Theme.diffSideBySideMin`: one column, the saved choice stays (HD-162). Decided here, not by
    /// Monaco's `useInlineViewWhenSpaceIsLimited`: that one stays inline after the pane widens again.
    private(set) var narrow = false

    /// `page`: a kept one (HD-167), else a new one.
    init(app: AppState, page kept: MonacoPage? = nil) {
        self.app = app
        page = kept ?? Self.makePage(app)
        page.webView.frame = container.bounds
        page.webView.autoresizingMask = [.width, .height]
        container.addSubview(page.webView)
        page.onMessage = { [weak self] m, _ in self?.handle(m) }
        container.onResize = { [weak self] width in
            guard let self else { return }
            let narrow = diffIsNarrow(width: width)
            guard self.narrow != narrow else { return }
            self.narrow = narrow
            self.sendOptions()
        }
        sendOptions()  // a kept page has the options of the previous tab, or of the launch
    }

    static func makePage(_ app: AppState) -> MonacoPage {
        MonacoPage(mode: .diff, inline: app.state.diffInline, minimap: false, wrap: app.state.diffWrap,
                   appearance: EditorAppearance(app.config))
    }

    func tearDown() {
        early?.task.cancel()
        page.tearDown()
    }

    /// The diff tab closed: the page goes on (to the next diff tab), without this controller.
    func detachPage() -> MonacoPage {
        early?.task.cancel()
        page.onMessage = nil
        page.webView.removeFromSuperview()
        return page
    }

    static func key(_ tab: DiffTab) -> String { tab.path + "|" + (tab.commit ?? "") }

    var hasUnsaved: Bool { editablePath.map { session?.isDirty($0) == true } ?? false }
    var unsavedPath: String? { hasUnsaved ? editablePath : nil }

    /// The next / previous change (F7 / ⇧F7, the header's arrows).
    func goChange(next: Bool) { page.send(.goChange(next: next)) }

    /// The saved «Одной колонкой» and «Переносить строки» to the page; a one-sided file or a narrow pane stays one column.
    func sendOptions() {
        page.send(.options(inline: app.state.diffInline || oneSided || narrow, minimap: false, wrap: app.state.diffWrap))
    }

    /// Loads both sides of the shown diff tab and hands them to the page; a refresh of the same file keeps an edited
    /// buffer (a change on disk then shows the conflict bar instead).
    func load(_ tab: DiffTab) async {
        let key = Self.key(tab)
        if let early, early.key == key {
            self.early = nil
            await early.task.value
            if shownKey == key { return }
        }
        await fetch(tab)
    }

    /// Starts the load of a newly opened file of the session's changes while the inspector still runs git's numstat
    /// and diff (HD-167): `git show` of the base and the file read don't need them. Only a file git counted lines for:
    /// a binary or huge one waits for git's verdict as before.
    func prefetch(_ tab: DiffTab) {
        let key = Self.key(tab)
        guard tab.commit == nil, key != shownKey, early?.key != key,
              let file = app.inspector.changes?.files.first(where: { $0.path == tab.path }), diffPrefetchable(file) else { return }
        early?.task.cancel()
        early = (key, Task { [weak self] in await self?.fetch(tab) })
    }

    private func fetch(_ tab: DiffTab) async {
        guard let task = app.selectedTask, let project = app.project(task.projectId) else { return }
        let key = Self.key(tab)
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
            let base = git(root), from = changes.from, basePath = "./" + (file.origPath ?? file.path)
            // The base side and the working file are read at once.
            async let original = added ? nil : ((try? await base.show(rev: from, path: basePath)) ?? nil)
            let io = app.editorIO(host: project.host)
            let full = root + "/" + tab.path
            let s = EditorSession(io: io) { [page] in page.send($0) }
            diff = EditorDiff(name: tab.path, original: "", modified: "", path: nil, line: nil)
            if file.change != .deleted, let opened = await s.adopt(path: full) {
                diff.modified = opened.text
                if !opened.readOnly { diff.path = full }
            }
            diff.original = await original ?? ""
            session = s
        }
        guard !Task.isCancelled, app.activeDiff.map(Self.key) == key else { return }
        let oneSided = diffOneSided(app.diffChange(of: tab))
        if oneSided != self.oneSided {
            self.oneSided = oneSided
            sendOptions()
        }
        editablePath = diff.path
        shownKey = key
        guard diff != shown else { return }  // e.g. the refresh after our own save
        shown = diff
        changes = ChangeCounter()
        page.send(.diff(diff))
        page.revealAfterPaint()
    }

    private func handle(_ m: BridgeMessage) {
        switch m {
        case .ready: if let shown { changes = ChangeCounter(); sendOptions(); page.send(.diff(shown)) }  // a reloaded page (the first load is queued)
        case .changed, .save, .conflict: Task { await session?.handle(m) }
        case .changes(let index, let count): changes = ChangeCounter(index: index, count: count)
        case .focus: if let session, !session.io.isLocal { Task { await session.checkDisk() } }
        case .openAt(let line, let column): app.openActiveDiffInEditor(line: line, column: column)
        case .openFile(let path, let line, let column): app.openInEditor(path: path, line: line, column: column)
        case .sendLines(let path, let from, let to): app.sendLinesToChat(path, from: from, to: to)
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
        window.beginHangarSheet({ end in
            ConfirmSheet(message: L10n.editorUnsavedTitle((path as NSString).lastPathComponent), info: L10n.editorUnsavedInfo,
                         button: L10n.save, destructive: false, other: L10n.editorDontSave,
                         onOther: { end(.alertSecondButtonReturn) },
                         onConfirm: { _ in end(.alertFirstButtonReturn) }, onCancel: { end(.cancel) })
        }, done: { [weak self] response in
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
        })
    }
}

/// A file of the session's changes whose diff text can load before git's own diff (`prefetch`): git counted its lines
/// (not binary, not an unread untracked file) and they fit the diff's limit.
func diffPrefetchable(_ file: ChangedFile) -> Bool {
    guard let added = file.added else { return false }
    return added + (file.deleted ?? 0) <= Git.diffMaxLines
}

/// The header's «2 из 5»: nil count until the page has computed the diff (nothing is claimed before that).
@MainActor struct ChangeCounter: Equatable {
    var index = 0
    var count: Int?

    var isEmpty: Bool { count == 0 }
    var canStep: Bool { (count ?? 0) > 0 }
    /// nil while unknown or empty.
    var text: String? { count.flatMap { $0 > 0 ? L10n.diffChangeCounter(index, $0) : nil } }
}

/// The diff's web view holder: reports its width (narrow → one column, HD-162).
final class ResizeReportingView: NSView {
    var onResize: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize.width)
    }
}
