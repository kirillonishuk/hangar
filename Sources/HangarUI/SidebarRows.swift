import AgentStatus
import AppKit
import ControlServer
import SwiftUI

/// One sidebar row. The marker (dot/icon) sits at `Theme.gutterMarkerX` in both expanded and rail mode;
/// collapsing only cross-fades the labels, so nothing moves (only the sidebar width animates).
struct GutterRow<Marker: View, Expanded: View, Rail: View>: View {
    let collapsed: Bool
    var height = Theme.Height.rowSidebar
    var textX = Theme.gutterTextX
    /// Nested rows (sessions under their project): marker and text shift right; the rail content stays centred.
    var indent: CGFloat = 0
    var trailing = Theme.rowPaddingH
    /// The rail content replaces the marker (task rows: one dot, on the monogram tile).
    var railReplacesMarker = false
    /// Two-line rows: the marker sits on the first line, this far above the row's centre.
    var markerDY: CGFloat = 0
    @ViewBuilder var marker: Marker
    @ViewBuilder var expanded: Expanded
    @ViewBuilder var rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            marker
                .frame(width: Theme.Icon.toolbar, height: Theme.Icon.toolbar)
                .offset(x: Theme.gutterMarkerX - Theme.Icon.toolbar / 2 + indent, y: markerDY)
                .opacity(railReplacesMarker && collapsed ? 0 : 1)
            // Centred in the rail, like the project tile.
            rail
                .frame(width: Theme.sidebarRailWidth)
                .opacity(collapsed ? 1 : 0)
            expanded
                .padding(.leading, textX + indent)
                .padding(.trailing, trailing)
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
    /// «Только ждущие» toggle (#67): a status dot, `waiting`-coloured and always shown while on.
    var filterOn = false
    var filterHelp = ""
    var filter: (() -> Void)?

    var body: some View {
        // No action → no hover fill; `hover` only reveals `+`.
        HoverRow { hover in
            HStack(spacing: Theme.sectionActionGap) {
                Text(title)
                Spacer(minLength: 0)
                if let filter {
                    Button(action: filter) {
                        // Off: a `text3` ring; on: a filled `waiting` dot (redesign-v1.html `.att`).
                        Circle().strokeBorder(filterOn ? Theme.ui.waiting : Theme.ui.text3, lineWidth: Theme.sectionFilterRing)
                            .background(Circle().fill(filterOn ? Theme.ui.waiting : .clear))
                            .frame(width: Theme.Icon.statusDot, height: Theme.Icon.statusDot)
                            .frame(width: Theme.Height.controlSmall, height: Theme.Height.controlSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .opacity(hover || filterOn ? 1 : 0)
                    .help(filterHelp)
                    .accessibilityLabel(filterHelp)
                    .accessibilityAddTraits(filterOn ? .isSelected : [])
                }
                if let plus {
                    IconButton(icon: .add, tint: Theme.ui.text3, help: plusHelp, action: plus)
                        .opacity(hover || plusAlwaysVisible ? 1 : 0)
                }
            }
            .font(Theme.Typography.caption.font(.semibold))
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.sectionHeaderX)
            .padding(.trailing, Theme.sectionHeaderTrailing)
            .frame(height: collapsed ? Theme.railHeaderHeight : Theme.Height.barPane)
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
        .padding(.top, collapsed ? 0 : Theme.sectionHeaderTop)
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
            ? RailTileStyle(fill: Theme.ui.railTileSelected, border: Theme.ui.railTileSelectedBorder, text: Theme.ui.text0)
            : RailTileStyle(fill: Theme.ui.hover2, border: .clear, text: Theme.ui.text1)
    }

    /// A project: outlined, no fill — calmer than its chats' filled tiles.
    static var project: RailTileStyle { RailTileStyle(fill: .clear, border: Theme.ui.line2, text: Theme.ui.text3) }

    /// What the corner dot's ring blends into: the rail square's fill under the tile's corner.
    static func ring(selected: Bool, hover: Bool) -> Color {
        HoverPalette.standard.background(selected: selected, hover: hover, base: Theme.ui.bg1)
    }
}

/// Rail tile: 20×20 monogram centred in the rail, status dot on its top-right corner ringed in what is under it
/// (icons-sidebar.html `.mono`). Chats are filled, projects outlined (`RailTileStyle.project`).
struct RailTile: View {
    let text: String
    let state: AgentState?
    let selected: Bool
    var hover = false
    var style: RailTileStyle?

    var body: some View {
        let style = self.style ?? RailTileStyle(selected: selected)
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        Text(text)
            .font(Theme.Typography.caption.font(.semibold))
            .foregroundStyle(style.text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: Theme.railTileSize, height: Theme.railTileSize)
            .background(shape.fill(style.fill))
            .overlay(shape.strokeBorder(style.border, lineWidth: Theme.railTileBorderWidth))
            .overlay(alignment: .topTrailing) {
                if let state {
                    StatusDot(state: state, size: Theme.railDot, border: RailTileStyle.ring(selected: selected, hover: hover),
                              borderWidth: Theme.railDotBorder)
                        .offset(x: Theme.railDotOffset, y: -Theme.railDotOffset)
                }
            }
    }
}

/// Key hint at a row's end («⌘N», «⌘0», «⇧⌘N»: `Shortcut.label`): one size and color everywhere.
struct ShortcutHint: View {
    let text: String
    @Environment(\.rowSelectedText) private var onSelected

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.secondary.font().monospacedDigit())
            .foregroundStyle(onSelected ?? Theme.ui.text3)
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

/// Host row: «Открыть терминал» (a plain ssh shell, #64); a host of remote projects also «Переподключиться»
/// (while not connected), «Проверить сервер» (connected), «Отключиться».
@MainActor func hostMenuItems(_ host: String, app: AppState, ctx: ActionContext) -> [MenuEntry] {
    let terminal = MenuEntry(title: L10n.openTerminal, icon: .shell) { app.openHostShell(host) }
    // `hangar://host/…` (#88): only for names a link carries as is.
    let link = HangarLink.isLinkableHost(host) ? [MenuEntry(title: L10n.copyLink, icon: .copy) {
        ctx.pasteboard.clearContents()
        ctx.pasteboard.setString(LinkTarget.host(host).link.url.absoluteString, forType: .string)
    }] : []
    guard app.sshHosts.contains(host) else { return [terminal] + link }
    let state = app.remote.hosts[host]?.state ?? .disconnected
    let down = state == .disconnected || { if case .unreachable = state { true } else { false } }()
    return [
        terminal,
        MenuEntry(title: L10n.reconnect, icon: .reconnect, enabled: state != .connected) { app.reconnect(host: host) },
        MenuEntry(title: L10n.checkServer, icon: .checkServer, enabled: state == .connected) { ctx.checkServer(host) },
        MenuEntry(title: L10n.disconnect, icon: .disconnect, enabled: !down) { app.remote.disconnect(host) },
    ] + link
}

/// The custom menu at the pointer (a click on a whole row), or at `point` in `view` (keyboard: mid-window).
@MainActor func popUpMenu(_ items: [MenuEntry], at point: NSPoint = NSEvent.mouseLocation, in view: NSView? = nil) {
    var screen = point
    if let view, let window = view.window { screen = window.convertPoint(toScreen: view.convert(point, to: nil)) }
    PopoverMenu.show(popoverEntries(items), at: screen)
}
