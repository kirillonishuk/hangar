import AgentStatus
import AppKit
import Observation
import SwiftUI

/// One clickable item of the menu (spec §3.12): icon (or a check, or a file's icon), label, a key hint
/// (`Shortcut.label`) or a `text3` note on the right.
struct PopoverMenuItem {
    var title: String
    var icon: Icon?
    var shortcut: String?
    /// `failedText`: the last item, in its own group.
    var destructive = false
    var enabled = true
    /// The current choice of a drop-down: a check in the icon slot.
    var checked = false
    /// Right side, `caption` `text3` («текущая», «2 дня», a count).
    var note: String?
    /// Branches, paths: `mono`.
    var mono = false
    /// A status dot on the icon's corner (a tab in the overflow menu).
    var dot: AgentState?
    /// A file's own icon instead of `icon` (a path pick).
    var file: (name: String, isDir: Bool)?
    var help: String?
    let action: () -> Void

    init(title: String, icon: Icon? = nil, shortcut: String? = nil, destructive: Bool = false, enabled: Bool = true,
         checked: Bool = false, note: String? = nil, mono: Bool = false, dot: AgentState? = nil,
         file: (name: String, isDir: Bool)? = nil, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.destructive = destructive
        self.enabled = enabled
        self.checked = checked
        self.note = note
        self.mono = mono
        self.dot = dot
        self.file = file
        self.help = help
        self.action = action
    }

}

enum PopoverMenuEntry: Equatable {
    case item(PopoverMenuItem)
    case separator
    /// Not clickable, never highlighted («redesign-v1 · feat/redesign-v1»).
    case header(String)

    var item: PopoverMenuItem? { if case .item(let i) = self { i } else { nil } }

    /// Items compare by what they show (actions are closures).
    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.separator, .separator): true
        case (.header(let x), .header(let y)): x == y
        case (.item(let x), .item(let y)):
            x.title == y.title && x.icon == y.icon && x.shortcut == y.shortcut && x.destructive == y.destructive
                && x.enabled == y.enabled && x.checked == y.checked && x.note == y.note && x.mono == y.mono && x.dot == y.dot
                && x.file?.name == y.file?.name && x.file?.isDir == y.file?.isDir
        default: false
        }
    }
}

/// ↑/↓: the next enabled item `by` steps away (wrapping); from nil, the first (or last) one.
func menuStep(_ entries: [PopoverMenuEntry], from: Int?, by step: Int) -> Int? {
    let selectable = entries.indices.filter { entries[$0].item?.enabled == true }
    guard !selectable.isEmpty else { return nil }
    guard let from, let at = selectable.firstIndex(of: from) else { return step > 0 ? selectable.first : selectable.last }
    return selectable[(at + step % selectable.count + selectable.count) % selectable.count]
}

/// Actions that remove or close something: red, last.
private let destructiveActions: Set<Action> = [.archive, .deletePermanently, .removeProject, .closeTab, .closePane]

/// The «⋯» / right-click menu of a project, session or tab, from `Action` (the same list as the keyboard and the palette).
/// A session's menu opens with its name (and branch) as the header.
@MainActor func actionMenu(for target: ActionTarget, ctx: ActionContext) -> [PopoverMenuEntry] {
    let app = ctx.app
    let actions = Action.list(for: target, app: app)
    var entries: [PopoverMenuEntry] = []
    if case .task(let id) = target, !actions.isEmpty, let task = app.state.tasks.first(where: { $0.id == id }) {
        entries.append(.header(task.branch.map { "\(task.name) · \($0)" } ?? task.name))
    }
    for (i, action) in actions.enumerated() {
        if i > 0 && (action.startsGroup || actions[i - 1] == .reconnect) { entries.append(.separator) }
        entries.append(.item(PopoverMenuItem(title: action.title(for: target, app: app), icon: action.icon, shortcut: action.shortcut(for: target, app: app)?.label,
                                             destructive: destructiveActions.contains(action), enabled: action.isEnabled(for: target, app: app)) {
            action.perform(target, ctx)
        }))
    }
    return entries
}

/// A small fixed menu (host row, «+ проект») as menu entries.
func popoverEntries(_ items: [MenuEntry]) -> [PopoverMenuEntry] {
    items.map { .item(PopoverMenuItem(title: $0.title, icon: $0.icon, enabled: $0.enabled, action: $0.action)) }
}

/// A click on the anchor button while its menu is open: the mouseDown closes the menu (it loses key), and the same
/// click's mouseUp would fire the button and reopen it. Remembers that mouseDown so the reopen is skipped.
struct MenuReopenGuard {
    private var dismissed: (anchor: ObjectIdentifier, event: Int)?

    mutating func dismissed(anchor: ObjectIdentifier, byMouseDown event: Int) { dismissed = (anchor, event) }

    /// False only for the mouseUp of the very click that just closed this anchor's menu.
    mutating func allowsOpen(anchor: ObjectIdentifier, event: Int?) -> Bool {
        defer { dismissed = nil }
        guard let d = dismissed, let event else { return true }
        return !(d.anchor == anchor && d.event == event)
    }
}

// MARK: Content

/// What a menu shows: fixed entries, or entries that follow a search field above them (a branch list, Git filters).
struct PopoverMenuContent {
    var search: Search?
    var width = Theme.menuWidth
    /// The entries for the field's text ("" without a field).
    let entries: (String) -> [PopoverMenuEntry]

    struct Search {
        let placeholder: String
        var mono = false
        var text = ""
        /// ↩ picks the highlighted item; the highlight starts on the checked (or first) item and moves to the first
        /// match as you type. Otherwise nothing is highlighted until ↑/↓ or the pointer, and ↩ goes to `submit`.
        var highlightFirst = false
        /// ↩ with nothing highlighted: the typed text (an author's name, a path).
        var submit: ((String) -> Void)?
    }

    init(search: Search? = nil, width: CGFloat = Theme.menuWidth, entries: @escaping (String) -> [PopoverMenuEntry]) {
        self.search = search
        self.width = width
        self.entries = entries
    }

    init(_ entries: [PopoverMenuEntry], width: CGFloat = Theme.menuWidth) {
        self.init(width: width) { _ in entries }
    }
}

/// Where the highlight goes when a search menu opens or its text changes: the checked item on open, else the first
/// enabled one; nil when the menu doesn't highlight by itself.
func menuInitialHighlight(_ entries: [PopoverMenuEntry], highlightFirst: Bool, preferChecked: Bool) -> Int? {
    guard highlightFirst else { return nil }
    if preferChecked, let i = entries.indices.first(where: { entries[$0].item?.checked == true && entries[$0].item?.enabled == true }) { return i }
    return menuStep(entries, from: nil, by: 1)
}

/// The columns and height a menu's entries need, worked out once per open / text change (not per hover).
struct PopoverMenuLayout: Equatable {
    /// A column of checks before the icons: some item is checked and items have their own icons («все вкладки»,
    /// a path pick). Without icons the check takes the icon's place.
    var checkColumn = false
    var iconColumn = false
    /// The list's natural height (items and headers `row.list`, separators 1 + 6 + 6), before the scroll cap.
    var height: CGFloat = 0

    init(_ entries: [PopoverMenuEntry]) {
        let icons = entries.contains { $0.item.map { $0.icon != nil || $0.file != nil } == true }
        let checks = entries.contains { $0.item?.checked == true }
        checkColumn = checks && icons
        iconColumn = icons || checks
        height = entries.reduce(0) { sum, e in
            if case .separator = e { return sum + 1 + 2 * Theme.menuPadding }
            return sum + Theme.Height.rowList
        }
    }

    init() {}

    static let maxHeight = CGFloat(Theme.menuListMaxRows) * Theme.Height.rowList
}

// MARK: Panel

/// The one menu (spec §3.12), one at a time: a borderless key panel; ↑/↓, ↩, Esc; closes on a pick, Esc or losing key
/// (a click anywhere else). `show(_:below:)` opens it under a button, `show(_:at:)` at the pointer.
@MainActor enum PopoverMenu {
    private(set) static var panel: PopoverMenuPanel?
    private static weak var panelAnchor: NSView?
    private static var reopenGuard = MenuReopenGuard()

    static var isShown: Bool { panel != nil }

    static func show(_ entries: [PopoverMenuEntry], below view: NSView?) { show(PopoverMenuContent(entries), below: view) }
    static func show(_ entries: [PopoverMenuEntry], at point: NSPoint) { show(PopoverMenuContent(entries), at: point) }

    /// Under `view` with a 4 pt gap, left edges aligned; moved left / above when the screen edge is near.
    static func show(_ content: PopoverMenuContent, below view: NSView?) {
        guard let view, let window = view.window else { return show(content, at: NSEvent.mouseLocation) }
        // Clicking the anchor of the open menu toggles it shut.
        if panel != nil, panelAnchor === view { return close() }
        let event = NSApp.currentEvent
        guard reopenGuard.allowsOpen(anchor: ObjectIdentifier(view), event: event.map { $0.eventNumber }) else { return }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        present(content, topLeft: NSPoint(x: frame.minX, y: frame.minY - Theme.menuAnchorGap), flipAbove: frame.maxY + Theme.menuAnchorGap)
        panelAnchor = view
    }

    /// At a screen point (right-click, a whole-row click): its top-left corner there.
    static func show(_ content: PopoverMenuContent, at point: NSPoint) {
        present(content, topLeft: point, flipAbove: point.y)
    }

    static func close() {
        let p = panel
        panel = nil
        panelAnchor = nil
        p?.orderOut(nil)
    }

    private static func present(_ content: PopoverMenuContent, topLeft: NSPoint, flipAbove: CGFloat) {
        close()
        guard content.search != nil || content.entries("").contains(where: { $0.item != nil }) else { return }
        let p = PopoverMenuPanel(content: content)
        let size = p.contentView?.fittingSize ?? .zero
        let screen = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
        if origin.x + size.width > screen.maxX { origin.x = screen.maxX - size.width }
        origin.x = max(origin.x, screen.minX)
        if origin.y < screen.minY { origin.y = min(flipAbove, screen.maxY - size.height) }
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
    }

    /// Closes first, then runs the item (its sheet or alert must not meet the menu).
    fileprivate static func pick(_ item: PopoverMenuItem) {
        guard item.enabled else { return }
        close()
        DispatchQueue.main.async { item.action() }
    }

    fileprivate static func submit(_ text: String, _ submit: @escaping (String) -> Void) {
        close()
        DispatchQueue.main.async { submit(text) }
    }

    fileprivate static func panelResigned(_ p: PopoverMenuPanel) {
        guard panel === p else { return }
        if let anchor = panelAnchor, let e = NSApp.currentEvent, e.type == .leftMouseDown {
            reopenGuard.dismissed(anchor: ObjectIdentifier(anchor), byMouseDown: e.eventNumber)
        }
        close()
    }
}

@MainActor @Observable final class PopoverMenuState {
    var highlighted: Int?
    var query = ""
    /// The entries for `query`, built once per change (and again when the data they read changes).
    private(set) var entries: [PopoverMenuEntry] = []
    private(set) var layout = PopoverMenuLayout()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var content: PopoverMenuContent?
    /// After each rebuild (the panel refits itself).
    @ObservationIgnored var changed: () -> Void = {}

    /// Rebuilds the entries, watching what they read (authors arriving, a branch list) to rebuild once more.
    func refresh(_ content: PopoverMenuContent) {
        self.content = content
        rebuild()
    }

    private func rebuild() {
        guard let content else { return }
        generation += 1
        let mine = generation
        let entries = withObservationTracking { content.entries(query) } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    self.rebuild()
                }
            }
        }
        self.entries = entries
        layout = PopoverMenuLayout(entries)
        if let h = highlighted, !entries.indices.contains(h) || entries[h].item?.enabled != true { highlighted = nil }
        changed()
    }
}

final class PopoverMenuPanel: NSPanel {
    let content: PopoverMenuContent
    let menuState = PopoverMenuState()

    init(content: PopoverMenuContent) {
        self.content = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        menuState.query = content.search?.text ?? ""
        menuState.refresh(content)
        if let search = content.search {
            menuState.highlighted = menuInitialHighlight(entries, highlightFirst: search.highlightFirst, preferChecked: true)
        }
        let host = NSHostingView(rootView: PopoverMenuView(content: content, state: menuState, panel: self))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
        menuState.changed = { [weak self] in self?.fitContent() }
    }

    var entries: [PopoverMenuEntry] { menuState.entries }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        PopoverMenu.panelResigned(self)
    }

    /// The list grows and shrinks with the text: the top edge stays where it opened. Measured only when the entries
    /// change, never on hover.
    private func fitContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.contentView?.fittingSize, size != self.frame.size else { return }
            self.setFrame(NSRect(x: self.frame.minX, y: self.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            self.invalidateShadow()
        }
    }

    func move(_ step: Int) { menuState.highlighted = menuStep(entries, from: menuState.highlighted, by: step) }

    func submit() {
        if let i = menuState.highlighted, entries.indices.contains(i), let item = entries[i].item {
            PopoverMenu.pick(item)
        } else if let submit = content.search?.submit {
            PopoverMenu.submit(menuState.query, submit)
        }
    }

    func queryChanged() {
        guard let search = content.search else { return }
        menuState.refresh(content)
        menuState.highlighted = menuInitialHighlight(entries, highlightFirst: search.highlightFirst, preferChecked: false)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76: submit()
        case 53: PopoverMenu.close()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { PopoverMenu.close() }
}

/// `bg2`, a `line2` edge, `radius.popover`, padding 6; items 24 (`row.list`, padding 8, radius 6, icon 14, `body`),
/// the key `secondary` `text3` on the right; under the pointer or the keys `selectedFocus` + `onAccent`; a group
/// header 24 `caption` 600 `text3`; separators `line2` with 6 around.
struct PopoverMenuView: View {
    let content: PopoverMenuContent
    let state: PopoverMenuState
    let panel: PopoverMenuPanel?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.popover)
        let entries = state.entries
        let layout = state.layout
        VStack(spacing: 0) {
            if let search = content.search {
                PickerSearchField(text: Binding(get: { state.query }, set: { state.query = $0; panel?.queryChanged() }),
                                  placeholder: search.placeholder, font: search.mono ? Theme.Typography.mono.nsFont() : Theme.Typography.body.nsFont(),
                                  onMove: { panel?.move($0) }, onSubmit: { panel?.submit() }, onCancel: { PopoverMenu.close() })
                    .inputField(focused: true, icon: .search)  // the list's keys go through it: always the focused one
                    .padding(.bottom, entries.isEmpty ? 0 : Theme.menuPadding)
            }
            if !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        // Lazy: a thousand branches build only the rows on screen.
                        LazyVStack(spacing: 0) {
                            ForEach(entries.indices, id: \.self) { i in entry(entries[i], index: i, layout: layout).id(i) }
                        }
                    }
                    .frame(height: min(layout.height, PopoverMenuLayout.maxHeight))
                    .scrollIndicators(.automatic)
                    // On open the checked / highlighted item is in view; then the keys keep theirs in view.
                    .onChange(of: state.highlighted, initial: true) { _, i in
                        if let i { proxy.scrollTo(i) } else if let c = entries.firstIndex(where: { $0.item?.checked == true }) { proxy.scrollTo(c) }
                    }
                }
            }
        }
        .padding(Theme.menuPadding)
        .frame(width: content.width)
        .background(shape.fill(Theme.ui.bg2))
        .overlay(shape.strokeBorder(Theme.ui.line2, lineWidth: 1))
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func entry(_ entry: PopoverMenuEntry, index: Int, layout: PopoverMenuLayout) -> some View {
        switch entry {
        case .item(let item): row(item, index: index, layout: layout)
        case .separator:
            Rectangle().fill(Theme.ui.line2).frame(height: 1).padding(.vertical, Theme.menuPadding)
        case .header(let text):
            Text(verbatim: text).lineLimit(1).truncationMode(.tail)
                .font(Theme.Typography.caption.font(.semibold))
                .foregroundStyle(Theme.ui.text3)
                .padding(.horizontal, Theme.Space.s2)
                .frame(maxWidth: .infinity, minHeight: Theme.Height.rowList, maxHeight: Theme.Height.rowList, alignment: .leading)
        }
    }

    private func row(_ item: PopoverMenuItem, index: Int, layout: PopoverMenuLayout) -> some View {
        let on = state.highlighted == index && item.enabled
        let text = item.destructive ? Theme.ui.failedText : on ? Theme.ui.onAccent : Theme.ui.text1
        let side = item.destructive ? Theme.ui.failedText : on ? Theme.ui.onAccent : Theme.ui.text3
        let icon = item.destructive ? Theme.ui.failedText : on ? Theme.ui.onAccent : Theme.ui.text2
        return HStack(spacing: Theme.Space.s2) {
            if layout.checkColumn {
                slot { if item.checked { IconView(icon: .check, size: Theme.Icon.row, tint: icon) } }
            }
            if layout.iconColumn {
                slot {
                    if item.checked && !layout.checkColumn {
                        IconView(icon: .check, size: Theme.Icon.row, tint: icon)
                    } else if let file = item.file {
                        FileIconView(name: file.name, isDir: file.isDir).frame(width: Theme.Icon.row, height: Theme.Icon.row)
                    } else if let glyph = item.icon {
                        IconView(icon: glyph, size: Theme.Icon.row, tint: icon)
                            .overlay(alignment: .bottomTrailing) {
                                if let dot = item.dot { StatusDot(state: dot, size: Theme.Icon.tabDot) }
                            }
                    }
                }
            }
            Text(verbatim: item.title).lineLimit(1).truncationMode(.middle)
                .font(item.mono ? Theme.Typography.mono.font() : Theme.Typography.body.font())
                .foregroundStyle(text)
            Spacer(minLength: 0)
            if let key = item.shortcut {
                Text(verbatim: key).font(Theme.Typography.secondary.font()).foregroundStyle(side)
            } else if let note = item.note {
                Text(verbatim: note).font(Theme.Typography.caption.font()).foregroundStyle(side).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.s2)
        .frame(height: Theme.Height.rowList)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .fill(on ? (item.destructive ? Theme.ui.failed.opacity(Theme.Opacity.fill) : Theme.ui.selectedFocus) : .clear))
        .opacity(item.enabled ? 1 : Theme.Opacity.inactive)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, item.enabled { state.highlighted = index } else if state.highlighted == index { state.highlighted = nil }
        }
        .onTapGesture { if item.enabled { PopoverMenu.pick(item) } }
        .pointingHand(item.enabled)
        .help(item.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.checked ? [.isButton, .isSelected] : .isButton)
    }

    /// A 14 pt column that keeps its width when empty.
    private func slot<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ZStack { Color.clear; content() }.frame(width: Theme.Icon.row, height: Theme.Icon.row)
    }
}

// MARK: SwiftUI glue

/// The NSView under a SwiftUI control, so the menu can open at its frame.
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    /// Never takes a click from the control it sits behind.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Right-click (and ⌃-click) opens the custom menu at the pointer; every other event goes to the row underneath.
private struct PopoverContextMenu: NSViewRepresentable {
    let entries: () -> [PopoverMenuEntry]

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) { view.entries = entries }

    final class CatcherView: NSView {
        var entries: (() -> [PopoverMenuEntry])?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || e.type == .rightMouseUp
                || ((e.type == .leftMouseDown || e.type == .leftMouseUp) && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { open() }
        override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { open() } }
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        private func open() {
            guard let entries else { return }
            MainActor.assumeIsolated { PopoverMenu.show(entries(), at: NSEvent.mouseLocation) }
        }
    }
}

extension View {
    /// Replaces `.contextMenu` with the custom menu.
    func popoverContextMenu(_ entries: @escaping () -> [PopoverMenuEntry]) -> some View {
        overlay(PopoverContextMenu(entries: entries))
    }
}

/// «⋯» (or another icon) that opens the menu under itself: an `IconButton` (22, or 28 in the tab bar).
struct PopoverMenuButton: View {
    var icon: Icon = .more
    var size: ControlSize = .small
    var help = L10n.more
    let entries: () -> [PopoverMenuEntry]
    @State private var anchor = MenuAnchor()

    var body: some View {
        IconButton(icon: icon, size: size, help: help) { PopoverMenu.show(entries(), below: anchor.view) }
            .background(MenuAnchorView(anchor: anchor))
    }
}
