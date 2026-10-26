import AppKit
import Workspace

/// An editor leaf (#80): one Monaco page with a model per open file and its own file tabs. The open files, the active
/// one and the cursors live in the leaf (`Leaf.editorFiles`), so the tab restores; the buffers live in the page.
/// Exists only while its leaf does; hidden → no watcher (and WebKit stops painting the hidden view).
@MainActor final class EditorPane: NSView {
    let leafId: UUID
    let page: MonacoPage
    private let app: AppState
    private(set) var session: EditorSession
    private var watcher: FileWatcher?
    private var watchedPaths: Set<String> = []
    private var visible = false
    private var shownMinimap: Bool
    var onFocus: (() -> Void)?

    init(leafId: UUID, app: AppState) {
        self.leafId = leafId
        self.app = app
        shownMinimap = app.state.editorMinimap
        page = MonacoPage(mode: .editor, inline: false, minimap: shownMinimap)
        session = EditorSession(io: app.editorIO(host: app.remoteLeafHost(leafId))) { [page] in page.send($0) }
        super.init(frame: .zero)
        page.webView.frame = bounds
        page.webView.autoresizingMask = [.width, .height]
        addSubview(page.webView)
        page.onMessage = { [weak self] in self?.handle($0) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The leaf is closed: the page and the watcher go.
    func tearDown() {
        watcher?.stop()
        watcher = nil
        page.tearDown()
    }

    var unsaved: [String] { session.files.filter { $0.value.dirty }.map(\.key).sorted() }

    /// The model already lists the file (`openEditorFile`); before the page is ready it loads from there.
    func open(path: String, line: Int?, column: Int?) {
        guard page.isReady else { return }
        Task {
            await session.open(path: path, line: line, column: column)
            restartWatcher()
        }
    }

    func focusEditor() {
        window?.makeFirstResponder(page.webView)
        page.send(.focus)
    }

    func setVisible(_ shown: Bool) {
        guard shown != visible else { return }
        visible = shown
        if shown { Task { await session.checkDisk() } }
        restartWatcher()
    }

    func apply(minimap: Bool) {
        guard minimap != shownMinimap else { return }
        shownMinimap = minimap
        page.send(.options(inline: false, minimap: minimap))
    }

    /// ⌘W: the active file's tab; with none left the leaf (and a tab of one leaf) closes.
    func closeActive() {
        guard let active = app.editorLeaf(leafId)?.openFile else { app.closeLeaf(leafId); return }
        requestClose(active)
    }

    /// ⌥⌘← / ⌥⌘→, wrapping as in VS Code.
    func step(_ offset: Int) {
        guard let leaf = app.editorLeaf(leafId) else { return }
        let files = leaf.editorFileList.map(\.path)
        guard files.count > 1, let i = files.firstIndex(where: { $0 == leaf.openFile }) else { return }
        let next = files[(i + offset + files.count) % files.count]
        app.perform { $0.activateEditorFile(leafId: leafId, path: next) }
        page.send(.activate(path: next, line: nil, column: nil))
    }

    private func handle(_ m: BridgeMessage) {
        switch m {
        case .ready: restore()
        case .focus:
            app.focused(leafId: leafId)
            onFocus?()
            if !session.io.isLocal { Task { await session.checkDisk() } }
        case .changed, .save, .conflict: Task { await session.handle(m) }
        case .cursor(let path, let line, let column):
            app.perform { $0.setEditorCursor(leafId: leafId, path: path, line: line, column: column) }
        case .activate(let path): app.perform { $0.activateEditorFile(leafId: leafId, path: path) }
        case .close(let path): requestClose(path)
        case .openFile(let path, let line, let column): app.openInEditor(path: path, line: line, column: column)
        case .minimap(let on): app.perform { $0.editorMinimap = on }
        case .request(let r):
            Task {
                let result = await app.editorProvider?(r)
                page.send(.resolve(id: r.id, result: result))
            }
        case .openAt, .inline, .log: break  // the diff's; logged by the page
        }
    }

    /// The page (re)loaded: every file of the leaf in tab order with its cursor, then the active one.
    private func restore() {
        session = EditorSession(io: session.io, limits: session.limits) { [page] in page.send($0) }
        guard let leaf = app.editorLeaf(leafId) else { return }
        Task {
            for f in leaf.editorFileList { await session.open(path: f.path, line: f.line, column: f.column) }
            if let active = leaf.openFile { page.send(.activate(path: active, line: nil, column: nil)) }
            restartWatcher()
        }
    }

    private func requestClose(_ path: String) {
        guard session.isDirty(path), let window else { finishClose(path); return }
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
                        if let text = await self.page.text(of: path) { await self.session.handle(.save(file: path, text: text)) }
                        if !self.session.isDirty(path) { self.finishClose(path) }  // a failed save keeps the tab
                    }
                case .alertSecondButtonReturn: self.finishClose(path)
                default: break
                }
            }
        }
    }

    private func finishClose(_ path: String) {
        session.close(path: path)
        page.send(.close(path: path))
        var empty = false
        app.perform { empty = $0.closeEditorFile(leafId: leafId, path: path) }
        if empty {
            app.closeLeaf(leafId)
        } else if let active = app.editorLeaf(leafId)?.openFile {
            page.send(.activate(path: active, line: nil, column: nil))
        }
        restartWatcher()
    }

    /// FSEvents on the folders of the open local files, only while shown; a clean buffer reloads, a dirty one asks.
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
