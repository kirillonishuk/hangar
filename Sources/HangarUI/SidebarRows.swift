import AgentStatus
import AppKit
import ControlServer
import SwiftUI

/// One sidebar row. The marker (dot/icon) sits at `Theme.gutterMarkerX` in both expanded and rail mode;
/// collapsing only cross-fades the labels, so nothing moves (only the sidebar width animates).
struct GutterRow<Marker: View, Expanded: View, Rail: View>: View {
    let collapsed: Bool
    var height = Theme.railRowHeight
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
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .offset(x: Theme.gutterMarkerX - Theme.iconSize / 2 + indent, y: markerDY)
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
                Text(title).tracking(Theme.fontSize.section * Theme.fontSize.projectTracking)
                Spacer(minLength: 0)
                if let filter {
                    Button(action: filter) {
                        // Off: a `text3` ring; on: a filled `waiting` dot (redesign-v1.html `.att`).
                        Circle().strokeBorder(filterOn ? Theme.ui.waiting : Theme.ui.text3, lineWidth: Theme.sectionFilterRing)
                            .background(Circle().fill(filterOn ? Theme.ui.waiting : .clear))
                            .frame(width: Theme.statusDot, height: Theme.statusDot)
                            .frame(width: Theme.rowActionSize, height: Theme.rowActionSize)
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
                    RowActionButton(icon: .add, tint: Theme.ui.text3, help: plusHelp, action: plus)
                        .opacity(hover || plusAlwaysVisible ? 1 : 0)
                }
            }
            .font(.system(size: Theme.fontSize.section, weight: .semibold))
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.sectionHeaderX)
            .padding(.trailing, Theme.sectionHeaderTrailing)
            .frame(height: collapsed ? Theme.railHeaderHeight : Theme.sectionHeaderHeight)
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
            : RailTileStyle(fill: Theme.ui.hover, border: Theme.ui.line2, text: Theme.ui.text1)
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
                StatusDot(state: state, size: Theme.railDot, border: Theme.ui.bg1, borderWidth: Theme.railDotBorder)
                    .offset(x: Theme.railDotOffset, y: -Theme.railDotOffset)
            }
            .animation(Motion.ease(Theme.selectionFade), value: selected)
    }
}

/// Key hint at a row's end («⌘N», «⌘0», «⇧⌘N»: `Shortcut.label`): one size and color everywhere.
struct ShortcutHint: View {
    let text: String
    @Environment(\.rowSelectedText) private var onSelected

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: Theme.fontSize.footer).monospacedDigit())
            .foregroundStyle(onSelected ?? Theme.ui.text3)
    }
}

/// Empty-state buttons: `hover2` fill hugging the label. With `width` the box follows the visible sidebar width (content is laid out wider and clipped in rail mode),
/// `inset` from the sidebar's edge.
struct FilledRowStyle: ButtonStyle {
    var width: CGFloat?
    var inset = Theme.railInset
    var radius = Theme.railItemRadius

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed, width: width, inset: inset, radius: radius)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        let width: CGFloat?
        let inset: CGFloat
        let radius: CGFloat
        @State private var hover = false

        var body: some View {
            label
                .background(alignment: .leading) {
                    let shape = RoundedRectangle(cornerRadius: radius)
                    let box = Group {
                        shape.fill(Theme.ui.hover2).brightness(pressed ? -0.03 : hover ? 0.04 : 0)
                    }
                    if let width {
                        box.frame(width: max(0, width)).padding(.leading, inset)
                    } else {
                        box
                    }
                }
                .contentShape(Rectangle())
                .pointingHand()
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}

/// Terminal area while there are no projects: "+ Добавить проект" (style of "+ Новая сессия") and the ⇧⌘N hint.
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
                    Text(L10n.addProject).foregroundStyle(Theme.ui.text0)
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

/// `+N −M` of a session's worktree (redesign-v1.html `.badge`): mono 12 in A / D colours, `line2` border.
struct DiffBadgeView: View {
    let badge: DiffBadge

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.diffBadgeRadius)
        HStack(spacing: Theme.diffBadgeGap) {
            Text(verbatim: badge.added).foregroundStyle(Theme.Diff.addMarker)
            Text(verbatim: badge.deleted).foregroundStyle(Theme.Diff.delMarker)
        }
        .font(.system(size: Theme.diffBadgeFont, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.diffBadgePaddingH)
        .frame(height: Theme.diffBadgeHeight)
        .background(shape.fill(Theme.ui.diffBadgeFill))
        .overlay(shape.strokeBorder(Theme.ui.line2, lineWidth: 1))
    }
}

/// A session row's second line: ⎇ (worktree) and «ждёт · 1 агент», the state word coloured for waiting / failed.
struct SessionStatusLine: View {
    let status: SessionStatus
    let worktree: Bool
    /// Notifications of the session are off: a crossed-out bell after the text.
    var muted = false
    @Environment(\.rowSelectedText) private var onSelected

    var body: some View {
        HStack(spacing: Theme.rowStatusGap) {
            if worktree { IconView(icon: .branch, size: Theme.rowStatusIcon, tint: Theme.ui.text3) }
            HStack(spacing: 0) {
                Text(verbatim: status.head).foregroundStyle(headColor)
                Text(verbatim: " · " + status.tail)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            if muted { IconView(icon: .bellSlash, size: Theme.rowStatusIcon, tint: Theme.ui.text3).help(L10n.mutedSessionHelp) }
        }
        .font(.system(size: Theme.rowStatusFont))
        .foregroundStyle(onSelected ?? Theme.ui.text2)
        .frame(height: Theme.sessionStatusLine)
    }

    private var headColor: Color {
        if let onSelected { return onSelected }
        return switch status.tone {
        case .normal: Theme.ui.text2
        case .waiting: Theme.ui.waiting
        case .failed: Theme.ui.failedText
        }
    }
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
