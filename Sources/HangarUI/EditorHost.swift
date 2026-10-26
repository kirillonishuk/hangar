import AppKit

/// The one Monaco page of the window's file tabs (#83): a model per open file, the shown tab's model in the editor.
/// Each file tab's `EditorPane` borrows the web view while it is on screen. Exists only while some file tab does.
@MainActor final class EditorHost {
    let page: MonacoPage
    private var panes: [UUID: EditorPane] = [:]
    private(set) var shown: UUID?
    private var minimap: Bool

    init(minimap: Bool, appearance: EditorAppearance) {
        self.minimap = minimap
        page = MonacoPage(mode: .editor, inline: false, minimap: minimap, appearance: appearance)
        page.onMessage = { [weak self] m, doc in self?.route(m, doc: doc) }
    }

    var isEmpty: Bool { panes.isEmpty }

    func register(_ pane: EditorPane) {
        panes[pane.leafId] = pane
        if page.isReady { pane.load() }
    }

    /// The tab closed: its model goes.
    func unregister(_ pane: EditorPane) {
        guard panes.removeValue(forKey: pane.leafId) != nil else { return }
        page.send(.close(path: ""), doc: pane.leafId)
        if shown == pane.leafId { shown = nil }
    }

    /// The pane's tab is on screen: the web view moves into it and shows its model (view state kept per model).
    func show(_ pane: EditorPane) {
        let view = page.webView
        if view.superview !== pane {
            view.frame = pane.bounds
            view.autoresizingMask = [.width, .height]
            pane.addSubview(view)
        }
        guard shown != pane.leafId else { return }
        shown = pane.leafId
        page.send(.activate(path: "", line: nil, column: nil), doc: pane.leafId)
    }

    func setMinimap(_ on: Bool) {
        guard on != minimap else { return }
        minimap = on
        page.send(.options(inline: false, minimap: on))
    }

    func tearDown() {
        panes = [:]
        page.tearDown()
    }

    private func route(_ m: BridgeMessage, doc: UUID?) {
        if m == .ready {
            // A new (or reloaded) page: every tab's file again, then the shown one.
            for pane in panes.values { pane.load() }
            if let shown { page.send(.activate(path: "", line: nil, column: nil), doc: shown) }
            return
        }
        guard let doc, let pane = panes[doc] else { return }
        pane.handle(m)
    }
}
