import AppKit

/// The visible editor panes of a tab, in tree order, get pages `0..<count`: the current one if no earlier pane took it,
/// else the first free one. Panes over `count` stay unassigned (the model caps them, `Tab.maxEditorPanes`).
func assignPages(visible: [(leaf: UUID, page: Int?)], count: Int) -> [UUID: Int] {
    var result: [UUID: Int] = [:]
    var taken = Set<Int>()
    // Keepers first so an earlier pane never takes a later one's page.
    for pane in visible {
        guard let page = pane.page, (0..<count).contains(page), !taken.contains(page) else { continue }
        result[pane.leaf] = page
        taken.insert(page)
    }
    for pane in visible where result[pane.leaf] == nil {
        guard let free = (0..<count).first(where: { !taken.contains($0) }) else { break }
        result[pane.leaf] = free
        taken.insert(free)
    }
    return result
}

/// The Monaco pages of the window's file tabs (#83): up to `Tab.maxEditorPanes`, one per editor pane on screen at once
/// (splits). Each page holds the models of the panes bound to it and shows one of them; a pane borrows its page's web
/// view while it is on screen. A page exists only while some pane is bound to it (or moving off it).
@MainActor final class EditorHost {
    private(set) var pages: [MonacoPage?] = [nil, nil]
    private var panes: [UUID: EditorPane] = [:]
    /// The pane each page shows.
    private(set) var shown: [UUID?] = [nil, nil]
    /// Pages a pane is moving off: kept until its buffer is read.
    private var leaving: [UUID: Int] = [:]
    private var minimap: Bool
    private var appearance: EditorAppearance

    init(minimap: Bool, appearance: EditorAppearance) {
        self.minimap = minimap
        self.appearance = appearance
    }

    var isEmpty: Bool { panes.isEmpty }
    func holds(_ pane: EditorPane) -> Bool { panes[pane.leafId] === pane }

    /// The page in slot `i`, made on first use.
    func page(_ i: Int) -> MonacoPage {
        if let page = pages[i] { return page }
        let page = MonacoPage(mode: .editor, inline: false, minimap: minimap, appearance: appearance)
        page.onMessage = { [weak self] m, doc in self?.route(m, doc: doc, page: i) }
        pages[i] = page
        uiLog.info("editor page \(i) created")
        return page
    }

    func register(_ pane: EditorPane) {
        panes[pane.leafId] = pane
        if page(pane.page).isReady { pane.load() }
    }

    /// The tab closed: its model goes.
    func unregister(_ pane: EditorPane) {
        guard panes.removeValue(forKey: pane.leafId) != nil else { return }
        pages[pane.page]?.send(.close(path: ""), doc: pane.leafId)
        if shown[pane.page] == pane.leafId { shown[pane.page] = nil }
        releaseUnused()
    }

    /// `pane` leaves page `from` (its buffer is being read there); `pane.page` is already the new one.
    func beginMove(_ pane: EditorPane, from: Int) {
        leaving[pane.leafId] = from
        if shown[from] == pane.leafId { shown[from] = nil }
    }

    func endMove(_ pane: EditorPane) {
        leaving[pane.leafId] = nil
        releaseUnused()
    }

    /// The pane is on screen: page `i`'s web view moves into it and shows its model (view state kept per model).
    func show(_ pane: EditorPane, page i: Int) {
        let view = page(i).webView
        if view.superview !== pane {
            view.frame = pane.bounds
            view.autoresizingMask = [.width, .height]
            pane.addSubview(view)
        }
        guard shown[i] != pane.leafId else { return }
        shown[i] = pane.leafId
        page(i).send(.activate(path: "", line: nil, column: nil), doc: pane.leafId)
    }

    func setMinimap(_ on: Bool) {
        guard on != minimap else { return }
        minimap = on
        for page in pages { page?.send(.options(inline: false, minimap: on)) }
    }

    func setAppearance(_ look: EditorAppearance) {
        appearance = look
        for page in pages { page?.send(.appearance(look)) }
    }

    func tearDown() {
        panes = [:]
        for i in pages.indices { pages[i]?.tearDown(); pages[i] = nil; shown[i] = nil }
    }

    /// A page no pane is bound to (nor moving off) goes with its web content process.
    private func releaseUnused() {
        let used = Set(panes.values.map(\.page)).union(leaving.values)
        for i in pages.indices where pages[i] != nil && !used.contains(i) {
            pages[i]?.tearDown()
            pages[i] = nil
            shown[i] = nil
            uiLog.info("editor page \(i) released")
        }
    }

    private func route(_ m: BridgeMessage, doc: UUID?, page i: Int) {
        if m == .ready {
            // A new (or reloaded) page: its panes' files again, then the shown one.
            for pane in panes.values where pane.page == i { pane.load() }
            if let shown = shown[i] { page(i).send(.activate(path: "", line: nil, column: nil), doc: shown) }
            return
        }
        // A pane that moved on no longer answers to its old page.
        guard let doc, let pane = panes[doc], pane.page == i else { return }
        pane.handle(m)
    }
}
