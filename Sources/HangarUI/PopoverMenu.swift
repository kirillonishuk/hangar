import AppKit
import Observation
import SwiftUI

/// One clickable item of the custom menu (redesign-v1.html §3): icon, label, key hint (`Shortcut.label`).
struct PopoverMenuItem {
    var title: String
    var icon: Icon?
    var shortcut: String?
    /// Red, with a red hover: the last item, in its own group.
    var destructive = false
    var enabled = true
    let action: () -> Void

    init(title: String, icon: Icon? = nil, shortcut: String? = nil, destructive: Bool = false, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.destructive = destructive
        self.enabled = enabled
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
            x.title == y.title && x.icon == y.icon && x.shortcut == y.shortcut && x.destructive == y.destructive && x.enabled == y.enabled
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
private let destructiveActions: Set<Action> = [.archive, .deletePermanently, .removeProject, .closeTab]

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
        entries.append(.item(PopoverMenuItem(title: action.title(for: target, app: app), icon: action.icon, shortcut: action.shortcut?.label,
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

// MARK: Panel

/// The custom navy menu, one at a time: a borderless key panel; ↑/↓, ↩, Esc; closes on a pick, Esc or losing key
/// (a click anywhere else). Other tracks open it with `show(_:below:)` (a button) or `show(_:at:)` (the pointer).
@MainActor enum PopoverMenu {
    private static var panel: PopoverMenuPanel?

    static var isShown: Bool { panel != nil }

    /// Under `view` with a 4 pt gap, left edges aligned; moved left / above when the screen edge is near.
    static func show(_ entries: [PopoverMenuEntry], below view: NSView?) {
        guard let view, let window = view.window else { return show(entries, at: NSEvent.mouseLocation) }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        present(entries, topLeft: NSPoint(x: frame.minX, y: frame.minY - Theme.menuAnchorGap), flipAbove: frame.maxY + Theme.menuAnchorGap)
    }

    /// At a screen point (right-click, a whole-row click): its top-left corner there.
    static func show(_ entries: [PopoverMenuEntry], at point: NSPoint) {
        present(entries, topLeft: point, flipAbove: point.y)
    }

    static func close() {
        let p = panel
        panel = nil
        p?.orderOut(nil)
    }

    private static func present(_ entries: [PopoverMenuEntry], topLeft: NSPoint, flipAbove: CGFloat) {
        close()
        guard entries.contains(where: { $0.item != nil }) else { return }
        let p = PopoverMenuPanel(entries: entries)
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

    fileprivate static func panelResigned(_ p: PopoverMenuPanel) {
        if panel === p { close() }
    }
}

@MainActor @Observable final class PopoverMenuState {
    var highlighted: Int?
}

final class PopoverMenuPanel: NSPanel {
    let entries: [PopoverMenuEntry]
    let menuState = PopoverMenuState()

    init(entries: [PopoverMenuEntry]) {
        self.entries = entries
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        let state = menuState
        let host = NSHostingView(rootView: PopoverMenuView(entries: entries, state: state) { i in
            if let item = entries[i].item { PopoverMenu.pick(item) }
        })
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        PopoverMenu.panelResigned(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: menuState.highlighted = menuStep(entries, from: menuState.highlighted, by: 1)
        case 126: menuState.highlighted = menuStep(entries, from: menuState.highlighted, by: -1)
        case 36, 76:
            if let i = menuState.highlighted, let item = entries[i].item { PopoverMenu.pick(item) }
        case 53: PopoverMenu.close()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { PopoverMenu.close() }
}

struct PopoverMenuView: View {
    let entries: [PopoverMenuEntry]
    let state: PopoverMenuState
    let pick: (Int) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.menuRadius)
        VStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { i in
                switch entries[i] {
                case .item(let item): row(item, index: i)
                case .separator:
                    Rectangle().fill(Theme.ui.lineSheet).frame(height: 1)
                        .padding(.vertical, Theme.menuSeparatorPaddingV)
                        .padding(.horizontal, Theme.menuSeparatorPaddingH)
                case .header(let text):
                    Text(verbatim: text).lineLimit(1).truncationMode(.tail)
                        .font(.system(size: Theme.menuShortcutFont))
                        .foregroundStyle(Theme.ui.text3)
                        .padding(.horizontal, Theme.menuItemPaddingLeading)
                        .frame(maxWidth: .infinity, minHeight: Theme.menuHeaderHeight, maxHeight: Theme.menuHeaderHeight, alignment: .leading)
                }
            }
        }
        .padding(Theme.menuPadding)
        .frame(width: Theme.menuWidth)
        .background(shape.fill(Theme.ui.sheet))
        .overlay(shape.strokeBorder(Theme.ui.controlBorderStrong, lineWidth: 1))
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ item: PopoverMenuItem, index: Int) -> some View {
        let on = state.highlighted == index && item.enabled
        let text = item.destructive ? Theme.ui.danger : Theme.ui.text
        return HStack(spacing: Theme.menuIconGap) {
            if let icon = item.icon {
                IconView(icon: icon, tint: item.destructive ? Theme.ui.danger : on ? Theme.ui.textStrong : Theme.ui.text2)
            }
            Text(verbatim: item.title).lineLimit(1)
                .font(.system(size: Theme.menuFont))
                .foregroundStyle(text)
            Spacer(minLength: 0)
            if let key = item.shortcut {
                Text(verbatim: key)
                    .font(.system(size: Theme.menuShortcutFont))
                    .foregroundStyle(item.destructive ? Theme.ui.dangerShortcut : Theme.ui.text3)
            }
        }
        .padding(.leading, Theme.menuItemPaddingLeading)
        .padding(.trailing, Theme.menuItemPaddingTrailing)
        .frame(height: Theme.menuItemHeight)
        .background(RoundedRectangle(cornerRadius: Theme.menuItemRadius)
            .fill(on ? (item.destructive ? Theme.ui.dangerHover : Theme.ui.sidebarHover) : .clear))
        .opacity(item.enabled ? 1 : Theme.inactiveOpacity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, item.enabled { state.highlighted = index } else if state.highlighted == index { state.highlighted = nil }
        }
        .onTapGesture { pick(index) }
        .pointingHand(item.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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

/// «⋯» (or another icon) that opens the custom menu under itself: 24×24, icon 16, radius 6, `rowActionHover` under the pointer.
struct PopoverMenuButton: View {
    var icon: Icon = .more
    var help = L10n.more
    let entries: () -> [PopoverMenuEntry]
    @State private var anchor = MenuAnchor()

    var body: some View {
        RowActionButton(icon: icon, help: help) { PopoverMenu.show(entries(), below: anchor.view) }
            .background(MenuAnchorView(anchor: anchor))
    }
}

/// Inline row action: no box of its own, a soft white fill under the pointer; the icon brightens (or keeps `tint`).
struct RowActionButton: View {
    let icon: Icon
    var tint: Color?
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, tint: tint ?? (hover ? Theme.ui.textStrong : Theme.ui.text2))
                .frame(width: Theme.rowActionSize, height: Theme.rowActionSize)
                .background(RoundedRectangle(cornerRadius: Theme.rowActionRadius).fill(hover ? Theme.ui.rowActionHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .help(help)
        .accessibilityLabel(help)
    }
}
