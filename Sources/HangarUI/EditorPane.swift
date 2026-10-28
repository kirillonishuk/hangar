import AppKit
import Workspace

/// A file tab (#83): one file of a Monaco page of `EditorHost` (`page`), shown in this view while its tab is on screen.
/// The file and its cursor live in the leaf (`Leaf.editorFiles`), so the tab restores; the buffer lives in the page.
/// Exists only while its leaf does; hidden → no watcher.
@MainActor final class EditorPane: NSView {
    let leafId: UUID
    let host: EditorHost
    /// The host's page holding this pane's model; two panes on screen at once are on different pages.
    private(set) var page: Int
    /// A move between pages in flight, and where the latest sync wants the pane.
    private var moving = false
    private var wanted: Int?
    /// Bumped with each new session: output of a replaced one (a load still reading, a save finishing) is dropped.
    private var generation = 0
    private let app: AppState
    private(set) var session: EditorSession
    private let remoteHost: String?
    private var watcher: FileWatcher?
    private var watchedPaths: Set<String> = []
    private var visible = false
    /// Language requests in flight, by the page's id (a `cancel` from the page stops one).
    private var requests: [Int: Task<Void, Never>] = [:]
    var onFocus: (() -> Void)?

    /// `page`: where its model goes first (a free one when it opens beside another editor).
    init(leafId: UUID, app: AppState, host: EditorHost, page: Int = 0) {
        self.leafId = leafId
        self.app = app
        self.host = host
        self.page = page
        remoteHost = app.remoteLeafHost(leafId)
        session = EditorSession(io: app.editorIO(host: remoteHost)) { _ in }
        super.init(frame: .zero)
        session = makeSession(io: session.io, limits: session.limits)
        host.register(self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var webView: NSView { host.page(page).webView }

    /// The tab is closed: its model, language document and watcher go.
    func tearDown() {
        app.languages.closedAll(owner: leafId)
        watcher?.stop()
        watcher = nil
        host.unregister(self)
        app.editorDirty.remove(leafId)
        app.editorLanguage[leafId] = nil
    }

    var unsaved: [String] { session.files.filter { $0.value.dirty }.map(\.key).sorted() }

    /// The page (re)loaded or this tab is new: its file from the leaf, at its cursor; a buffer carried over from the
    /// other page (`rehome`) opens as it was.
    func load() {
        guard !moving else { return }  // the new page got ready mid-move: the move loads it, with the carried buffer
        app.languages.closedAll(owner: leafId)  // a reloaded page lost its models
        let moved = carried
        carried = nil
        // A save that finished during the move gives its stamp; the buffer stays unsaved (`File.carried`).
        // shortcut: a save still writing when the move ends keeps the old stamp (a false conflict bar on the next save); rare.
        let latest = moved.flatMap { session.files[$0.path] }
        session = makeSession(io: session.io, limits: session.limits)
        guard let leaf = app.editorLeaf(leafId), let path = leaf.openFile else { return }
        let cursor = leaf.editorFileList.first { $0.path == path }
        if let moved, moved.path == path {
            session.adopt(path: path, text: moved.text, file: .carried(moved.file, latest: latest), line: cursor?.line, column: cursor?.column)
            restartWatcher()
            return
        }
        Task {
            await session.open(path: path, line: cursor?.line, column: cursor?.column)
            restartWatcher()
        }
    }

    /// An unsaved buffer on its way to the new page, until that page is ready.
    private var carried: (path: String, text: String, file: EditorSession.File)?

    /// Moves the model to page `target`: an unsaved buffer goes along (text, dirty, conflict), a clean one reloads there.
    func rehome(to target: Int) async {
        guard !moving else { wanted = target; return }
        guard target != page else { return }
        moving = true
        let from = page, old = host.page(from)
        page = target
        host.beginMove(self, from: from)
        let path = app.editorLeaf(leafId)?.openFile
        if let path, let file = session.files[path], file.dirty, let text = await old.text(of: leafId.uuidString) {
            carried = (path, text, file)
        }
        old.send(.close(path: ""), doc: leafId)
        requests.values.forEach { $0.cancel() }
        requests = [:]
        host.endMove(self)
        moving = false
        guard host.holds(self) else { carried = nil; return }  // closed while its buffer was read
        if host.page(page).isReady { load() } else { app.languages.closedAll(owner: leafId) }  // else its `.ready` loads
        if let next = wanted {
            wanted = nil
            await rehome(to: next)
        }
    }

    /// Opened again (Files, ⌘P, a definition): the cursor moves there.
    func open(path: String, line: Int?, column: Int?) {
        guard host.page(page).isReady, session.files[path] != nil else { return }
        Task { await session.open(path: path, line: line, column: column) }
    }

    func focusEditor() {
        window?.makeFirstResponder(webView)
        host.page(page).send(.focus, doc: leafId)
    }

    /// `page`: where the pane shows when on screen (the sync's assignment; its model follows by `rehome`).
    func setVisible(_ shown: Bool, page shownPage: Int? = nil) {
        if shown { host.show(self, page: shownPage ?? page) }
        guard shown != visible else { return }
        visible = shown
        if shown { Task { await session.checkDisk() } }
        restartWatcher()
    }

    func handle(_ m: BridgeMessage) {
        switch m {
        case .focus:
            app.focused(leafId: leafId)
            onFocus?()
            if !session.io.isLocal { Task { await session.checkDisk() } }
        case .changed, .save, .conflict: Task { await session.handle(m) }
        case .cursor(let path, let line, let column):
            app.perform { $0.setEditorCursor(leafId: leafId, path: path, line: line, column: column) }
        case .openFile(let path, let line, let column): app.openInEditor(path: path, line: line, column: column)
        case .request(let r):
            let io = session.io, limit = EditorLimits.editableBytes, page = host.page(page), doc = leafId
            requests[r.id] = Task { [weak self] in
                let result = await self?.app.languages.request(r, host: self?.remoteHost) { path in
                    guard case .text(let text, _)? = try? await io.read(path, limit) else { return nil }
                    return text
                }
                self?.requests[r.id] = nil
                if !Task.isCancelled { page.send(.resolve(id: r.id, result: result), doc: doc) }
            }
        case .cancel(let id): requests.removeValue(forKey: id)?.cancel()
        case .edit(let path, let edits): app.languages.edited(path, edits, host: remoteHost)
        case .restartLanguage(let path): app.languages.restart(path, host: remoteHost)
        case .ready, .openAt, .inline, .log, .clipboard: break  // the host's, the diff's, the page's
        }
    }

    /// The tsserver status item (status bar) was clicked.
    func restartLanguage() {
        guard let path = app.editorLeaf(leafId)?.openFile else { return }
        app.languages.restart(path, host: remoteHost)
    }

    /// A session sending to this tab's model on its page now; opened TS/JS files go to tsserver, whose status goes to
    /// the status bar. Once replaced (a new load, a move to the other page) it says nothing more.
    private func makeSession(io: EditorIO, limits: EditorLimits) -> EditorSession {
        generation += 1
        let index = page, gen = generation, page = host.page(page), doc = leafId
        let current = { [weak self] in self?.page == index && self?.generation == gen }
        let session = EditorSession(io: io, limits: limits) { if current() { page.send($0, doc: doc) } }
        session.onDirty = { [weak self] _, dirty in if current() { self?.app.editorDirtyChanged(leafId: doc, dirty: dirty) } }
        session.onOpened = { [weak self] path, text in
            guard let self, current() else { return }
            let owner = Languages.Owner(id: doc, root: app.editorLeaf(doc)?.cwd ?? "/", send: { [weak self] cmd in
                if case .language(_, let status) = cmd { self?.app.editorLanguage[doc] = status } else if current() { page.send(cmd, doc: doc) }
            }, text: { _ in await page.text(of: doc.uuidString) })
            app.languages.opened(path, text: text, host: remoteHost, owner: owner)
        }
        return session
    }

    /// FSEvents on the folder of the file (local), only while shown; a clean buffer reloads, a dirty one asks.
    private func restartWatcher() {
        let paths: Set<String> = visible && session.io.isLocal ? Set(session.files.filter { !$0.value.refused }.keys.map(realPath)) : []
        guard paths != watchedPaths else { return }
        watcher?.stop()
        watcher = nil
        watchedPaths = paths
        guard !paths.isEmpty else { return }
        let dirs = Set(paths.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        watcher = FileWatcher(paths: dirs, onChange: { [weak self] _ in
            guard let self else { return }
            Task { await self.session.checkDisk() }
        }, classify: { events in events.contains { paths.contains($0.path) } ? .status : [] })
    }
}
