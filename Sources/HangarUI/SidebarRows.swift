import AgentStatus
import SwiftUI

/// One sidebar row. The marker (dot/icon) sits at `Theme.gutterMarkerX` in both expanded and rail mode;
/// collapsing only cross-fades the labels, so nothing moves (only the sidebar width animates).
struct GutterRow<Marker: View, Expanded: View, Rail: View>: View {
    let collapsed: Bool
    var height = Theme.railRowHeight
    var textX = Theme.gutterTextX
    /// The rail content replaces the marker (task rows: one dot, on the monogram tile).
    var railReplacesMarker = false
    @ViewBuilder var marker: Marker
    @ViewBuilder var expanded: Expanded
    @ViewBuilder var rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            marker
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .offset(x: Theme.gutterMarkerX - Theme.iconSize / 2)
                .opacity(railReplacesMarker && collapsed ? 0 : 1)
            // Centred in the rail, like the project tile.
            rail
                .frame(width: Theme.sidebarRailWidth)
                .opacity(collapsed ? 1 : 0)
            expanded
                .padding(.leading, textX)
                .padding(.trailing, Theme.rowPaddingH)
                .opacity(collapsed ? 0 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
    }
}

/// Section header (caps, `text3`, 11.5 semibold, tracked). In the rail it becomes a short `line` separator 12 high;
/// the height animates together with the sidebar width, so rows glide instead of jumping.
struct SectionHeader: View {
    let title: String
    let collapsed: Bool
    var plusHelp = ""
    /// `+` without hover (empty state: nothing else says how to add the first project).
    var plusAlwaysVisible = false
    var plus: (() -> Void)?

    var body: some View {
        // No action → no hover fill; `hover` only reveals `+`.
        HoverRow { hover in
            HStack(spacing: 0) {
                Text(title).tracking(Theme.fontSize.section * Theme.fontSize.projectTracking)
                Spacer(minLength: 0)
                if let plus {
                    Button(action: plus) { IconView(icon: .add, size: Theme.smallIconSize).padding(Theme.railInset) }
                        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                        .opacity(hover || plusAlwaysVisible ? 1 : 0)
                        .help(plusHelp)
                }
            }
            .font(.system(size: Theme.fontSize.section, weight: .semibold))
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.sectionTextX)
            .padding(.trailing, Theme.rowPaddingH - Theme.railInset)
            .frame(height: collapsed ? Theme.railHeaderHeight : Theme.projectRowHeight)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.ui.line)
                    .frame(width: Theme.railHeaderLine, height: Theme.railHeaderLineWidth)
                    .padding(.leading, (Theme.sidebarRailWidth - Theme.railHeaderLine) / 2)
                    .opacity(collapsed ? 1 : 0)
            }
        }
        .allowsHitTesting(!collapsed)
        .padding(.top, collapsed ? 0 : Theme.sectionGap)
        .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
    }
}

/// Fill, border and text of a rail monogram tile.
struct RailTileStyle: Equatable {
    let fill: Color
    let border: Color
    let text: Color

    init(fill: Color, border: Color, text: Color) {
        self.fill = fill
        self.border = border
        self.text = text
    }

    init(selected: Bool) {
        self = selected
            ? RailTileStyle(fill: Theme.ui.railTileSelected, border: Theme.ui.railTileSelectedBorder, text: Theme.ui.selectionText)
            : RailTileStyle(fill: Theme.ui.railTile, border: Theme.ui.railTileBorder, text: Theme.ui.textRow)
    }
}

/// Rail task tile: 22×22 monogram centred in the rail, status dot in its top-right corner (icons-sidebar.html `.mono`).
struct RailTile: View {
    let text: String
    let state: AgentState
    let selected: Bool

    var body: some View {
        let style = RailTileStyle(selected: selected)
        let shape = RoundedRectangle(cornerRadius: Theme.projectTileRadius)
        Text(text)
            .font(.system(size: Theme.fontSize.small, weight: .semibold))
            .foregroundStyle(style.text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: Theme.railTileSize, height: Theme.railTileSize)
            .background(shape.fill(style.fill))
            .overlay(shape.strokeBorder(style.border, lineWidth: Theme.railTileBorderWidth))
            .overlay(alignment: .topTrailing) {
                StatusDot(state: state, size: Theme.railDot, border: Theme.ui.sidebar, borderWidth: Theme.railDotBorder)
                    .offset(x: Theme.railDotOffset, y: -Theme.railDotOffset)
            }
            .animation(Motion.ease(Theme.selectionFade), value: selected)
    }
}

/// Key hint at a row's end («⌘N», «⌘0», «⇧⌘N»: `Shortcut.label`): one size and color everywhere.
struct ShortcutHint: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: Theme.fontSize.footer).monospacedDigit())
            .foregroundStyle(Theme.ui.text3)
    }
}

/// "+ Новая задача" fill (`hoverStrong`). With `width` the fill follows the visible sidebar width (content is laid
/// out wider and clipped in rail mode); without it the fill hugs the label (empty-state button).
struct FilledRowStyle: ButtonStyle {
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed, width: width)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        let width: CGFloat?
        @State private var hover = false

        var body: some View {
            label
                .background(alignment: .leading) {
                    let fill = RoundedRectangle(cornerRadius: Theme.railItemRadius)
                        .fill(Theme.ui.hoverStrong)
                        .brightness(pressed ? -0.03 : hover ? 0.04 : 0)
                    if let width {
                        fill.frame(width: max(0, width)).padding(.leading, Theme.railInset)
                    } else {
                        fill
                    }
                }
                .contentShape(Rectangle())
                .pointingHand()
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// Terminal area while there are no projects: "+ Добавить проект" (style of "+ Новая задача") and the ⇧⌘N hint.
struct EmptyStateView: View {
    let addProject: () -> Void

    /// For the AppKit terminal area (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
    @MainActor static func hosted(addProject: @escaping () -> Void) -> NSView {
        let view = NSHostingView(rootView: EmptyStateView(addProject: addProject))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        VStack(spacing: Theme.sheetGap) {
            Button(action: addProject) {
                HStack(spacing: Theme.iconGap) {
                    IconView(icon: .add, active: true)
                    Text(L10n.addProject).foregroundStyle(Theme.ui.textStrong)
                }
                .padding(.vertical, Theme.tabPaddingV)
                .padding(.horizontal, Theme.buttonPaddingH)
            }
            .buttonStyle(FilledRowStyle())
            ShortcutHint(text: Shortcut.addProject.label)
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One item of a small fixed menu (host row, «+ проект»): shown as an NSMenu at the pointer on click, and as
/// SwiftUI items in the context / `…` menus.
struct MenuEntry {
    let title: String
    let icon: Icon
    var enabled = true
    let action: () -> Void
}

/// Host row: «Открыть терминал» (a plain ssh shell, #NN-ssh-shell); a host of remote projects also «Переподключиться»
/// (while not connected), «Проверить сервер» (connected), «Отключиться».
@MainActor func hostMenuItems(_ host: String, app: AppState, ctx: ActionContext) -> [MenuEntry] {
    let terminal = MenuEntry(title: L10n.openTerminal, icon: .shell) { app.openHostShell(host) }
    guard app.sshHosts.contains(host) else { return [terminal] }
    let state = app.remote.hosts[host]?.state ?? .disconnected
    let down = state == .disconnected || { if case .unreachable = state { true } else { false } }()
    return [
        terminal,
        MenuEntry(title: L10n.reconnect, icon: .reconnect, enabled: state != .connected) { app.reconnect(host: host) },
        MenuEntry(title: L10n.checkServer, icon: .checkServer, enabled: state == .connected) { ctx.checkServer(host) },
        MenuEntry(title: L10n.disconnect, icon: .disconnect, enabled: !down) { app.remote.disconnect(host) },
    ]
}

/// The menu at the pointer (a click on a whole row; SwiftUI's `Menu` can't take a row as its label).
@MainActor func popUpMenu(_ items: [MenuEntry], at point: NSPoint = NSEvent.mouseLocation, in view: NSView? = nil) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in items {
        let item = ClosureMenuItem(title: entry.title, handler: entry.action)
        item.image = entry.icon.image
        item.isEnabled = entry.enabled
        menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: point, in: view)
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

struct MenuItemsView: View {
    let items: [MenuEntry]

    var body: some View {
        ForEach(items, id: \.title) { item in
            Button { item.action() } label: {
                Label { Text(verbatim: item.title) } icon: { Image(nsImage: item.icon.image) }
            }
            .disabled(!item.enabled)
        }
    }
}

/// The `…` menu of sidebar rows and the Settings row (also the tab bar `+` and the host ▾): hover fill and pointing hand.
/// `size` fixes a square hit box; otherwise `padding` surrounds the icon.
struct MoreButton<Items: View>: View {
    var icon: Icon = .more
    var radius = Theme.railItemRadius
    var padding = Theme.railInset
    var size: CGFloat?
    var help = L10n.more
    @ViewBuilder var items: Items
    @Environment(\.hoverPalette) private var palette
    @State private var hover = false

    var body: some View {
        Menu { items } label: { Image(nsImage: icon.image).renderingMode(.template) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: size, height: size)
            .padding(size == nil ? padding : 0)
            .background(RoundedRectangle(cornerRadius: radius)
                .fill(palette.fill(selected: false, pressed: false, hover: hover, interactive: true)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            .pointingHand()
            .help(help)
    }
}
