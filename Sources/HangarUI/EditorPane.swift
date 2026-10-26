import AppKit
import Workspace

/// A file tab (#83): one file of the shared Monaco page (`EditorHost`), shown in this view while its tab is on screen.
/// The file and its cursor live in the leaf (`Leaf.editorFiles`), so the tab restores; the buffer lives in the page.
/// Exists only while its leaf does; hidden → no watcher.
@MainActor final class EditorPane: NSView {
    let leafId: UUID
    let host: EditorHost
    private let app: AppState
    private(set) var session: EditorSession
    private let remoteHost: String?
    private var watcher: FileWatcher?
    private var watchedPaths: Set<String> = []
    private var visible = false
    var onFocus: (() -> Void)?

    init(leafId: UUID, app: AppState, host: EditorHost) {
        self.leafId = leafId
        self.app = app
        self.host = host
        remoteHost = app.remoteLeafHost(leafId)
        session = EditorSession(io: app.editorIO(host: remoteHost)) { _ in }
        super.init(frame: .zero)
        session = makeSession(io: session.io, limits: session.limits)
        host.register(self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var webView: NSView { host.page.webView }

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

    /// The page (re)loaded or this tab is new: its file from the leaf, at its cursor.
    func load() {
        app.languages.closedAll(owner: leafId)  // a reloaded page lost its models
        session = makeSession(io: session.io, limits: session.limits)
        guard let leaf = app.editorLeaf(leafId), let path = leaf.openFile else { return }
        let cursor = leaf.editorFileList.first { $0.path == path }
        Task {
            await session.open(path: path, line: cursor?.line, column: cursor?.column)
            restartWatcher()
        }
    }

    /// Opened again (Files, ⌘P, a definition): the cursor moves there.
    func open(path: String, line: Int?, column: Int?) {
        guard host.page.isReady, session.files[path] != nil else { return }
        Task { await session.open(path: path, line: line, column: column) }
    }

    func focusEditor() {
        window?.makeFirstResponder(webView)
        host.page.send(.focus, doc: leafId)
    }

    func setVisible(_ shown: Bool) {
        if shown { host.show(self) }
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
            let io = session.io, limit = EditorLimits.editableBytes, page = host.page, doc = leafId
            Task {
                let result = await app.languages.request(r, host: remoteHost) { path in
                    guard case .text(let text, _)? = try? await io.read(path, limit) else { return nil }
                    return text
                }
                page.send(.resolve(id: r.id, result: result), doc: doc)
            }
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

    /// A session sending to this tab's model; opened TS/JS files go to tsserver, whose status goes to the status bar.
    private func makeSession(io: EditorIO, limits: EditorLimits) -> EditorSession {
        let page = host.page, doc = leafId
        let session = EditorSession(io: io, limits: limits) { page.send($0, doc: doc) }
        session.onDirty = { [weak self] _, dirty in self?.app.editorDirtyChanged(leafId: doc, dirty: dirty) }
        session.onOpened = { [weak self] path, text in
            guard let self else { return }
            let owner = Languages.Owner(id: doc, root: app.editorLeaf(doc)?.cwd ?? "/", send: { [weak self] cmd in
                if case .language(_, let status) = cmd { self?.app.editorLanguage[doc] = status } else { page.send(cmd, doc: doc) }
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
