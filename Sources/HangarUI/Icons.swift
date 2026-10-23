import AgentStatus
import AppKit
import SwiftUI
import Workspace

/// Every icon in the UI: SF Symbols, one weight, `Theme.iconSize`. No symbol names outside this file.
enum Icon {
    case sidebarToggle, newTask, project, worktree, sshHost, claude, codex, editor, shell, diff, files, changes
    case keepAwake, limits, settings, archive, search, splitRight, splitDown, close
    case pin, pinned, chevronUp, chevronDown, chevronRight, more, sidebarRight
    case rename, finder, copy, openExternal, restore, trash, remove, refresh

    private var symbol: String {
        switch self {
        case .sidebarToggle: "sidebar.left"
        case .newTask: "plus"
        case .project: "folder"
        case .worktree: "arrow.triangle.branch"
        case .sshHost: "server.rack"
        case .claude: "sparkle"  // fallback when the bundled logo is unavailable
        case .codex: "chevron.left.forwardslash.chevron.right"  // fallback
        case .editor: "pencil"
        case .shell: "terminal"
        case .diff, .changes: "plus.forwardslash.minus"
        case .files: "doc.text"
        case .keepAwake: "cup.and.saucer"
        case .limits: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        case .archive: "archivebox"
        case .search: "magnifyingglass"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .close: "xmark"
        case .pin: "pin"
        case .pinned: "pin.fill"
        case .chevronUp: "chevron.up"
        case .chevronDown: "chevron.down"
        case .chevronRight: "chevron.right"
        case .more: "ellipsis"
        case .sidebarRight: "sidebar.right"
        case .rename: "character.cursor.ibeam"
        case .finder: "macwindow.on.rectangle"
        case .copy: "doc.on.doc"
        case .openExternal: "arrow.up.forward.app"
        case .restore: "arrow.uturn.backward"
        case .trash: "trash"
        case .remove: "minus.circle"
        case .refresh: "arrow.clockwise"
        }
    }

    static func of(_ kind: LeafKind) -> Icon {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        case .editor: .editor
        case .shell: .shell
        }
    }

    /// Agents use their brand logos (Simple Icons SVGs in Contents/Resources/Icons, decision #33), tinted.
    private var brand: (file: String, tint: NSColor)? {
        switch self {
        case .claude: ("claude", Theme.claudeBrand)
        case .codex: ("openai", Theme.textStrong)
        default: nil
        }
    }

    /// Only when the logo loaded: the SF Symbol fallback (no bundle) stays a template, or it draws black.
    var isBrand: Bool { brand.map { Self.logo($0.file) != nil } ?? false }

    /// SF Symbols are template images (tinted by the caller); brand logos come pre-tinted.
    var image: NSImage {
        if let brand, let logo = Self.logo(brand.file) { return Self.tinted(logo, brand.tint) }
        let config = NSImage.SymbolConfiguration(pointSize: Theme.iconSize, weight: .regular)
        // Without the bundle (swift run / tests) brand icons fall back to their SF Symbol.
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        return base.withSymbolConfiguration(config) ?? base
    }

    static func color(active: Bool) -> NSColor { active ? Theme.textStrong : Theme.text2 }

    @MainActor private static var logos: [String: NSImage] = [:]

    private static func logo(_ name: String) -> NSImage? {
        MainActor.assumeIsolated {
            if let cached = logos[name] { return cached }
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).svg"),
                  let image = NSImage(contentsOf: url) else { return nil }
            logos[name] = image
            return image
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let size = NSSize(width: Theme.iconSize, height: Theme.iconSize)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// SwiftUI icon: template image tinted `text2`, or `textStrong` when active/selected.
struct IconView: View {
    let icon: Icon
    var active = false
    var size = Theme.iconSize
    var tint: Color?

    var body: some View {
        Image(nsImage: icon.image)
            .renderingMode(icon.isBrand ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint ?? (active ? Theme.ui.textStrong : Theme.ui.text2))
    }
}

/// Status dot; `waiting` has a halo and pulses once when it turns on (scale 1 → 1.6 → 1, 400 ms). Never loops.
struct StatusDot: View {
    var state: AgentState = .idle
    var size = Theme.statusDot
    /// Ring of this color around the dot (rail corner dot); the halo sits outside it.
    var border: Color?
    var borderWidth: CGFloat = 0
    @State private var scale: CGFloat = 1

    var body: some View {
        Circle().fill(Theme.ui.status(state))
            .frame(width: size, height: size)
            .background {
                if let border { Circle().fill(border).padding(-borderWidth) }
            }
            .background {
                if state == .waiting {
                    Circle().fill(Theme.ui.waiting.opacity(Theme.haloOpacity)).padding(-(borderWidth + Theme.haloWidth))
                }
            }
            .scaleEffect(scale)
            .accessibilityElement()
            .accessibilityLabel(L10n.statusLabel(state))
            // shortcut: no pulse on appear (it would repeat on every view re-creation); the static halo marks an already-waiting dot
            .onChange(of: state) { _, now in if now == .waiting { pulse() } }
    }

    private func pulse() {
        guard !Motion.reduced else { return }
        let half = Theme.pulseDuration / 2
        withAnimation(.easeOut(duration: half)) { scale = Theme.pulseScale } completion: {
            withAnimation(.easeIn(duration: half)) { scale = 1 }
        }
    }
}

/// Hover/pressed fills for the surface a control sits on: `standard` on `bg`, `sidebar` on `sidebar`/`sheet`
/// (there `hover` would be darker than the background).
struct HoverPalette: Sendable {
    let hover: Color
    let pressed: Color

    static let standard = HoverPalette(hover: Theme.ui.hover, pressed: Theme.ui.pressed)
    static let sidebar = HoverPalette(hover: Theme.ui.sidebarHover, pressed: Theme.ui.sidebarPressed)

    /// Rows without an action (section headers, …) get no hover/press fill.
    func fill(selected: Bool, pressed: Bool, hover: Bool, interactive: Bool) -> Color {
        if selected { return Theme.ui.selection }
        guard interactive else { return .clear }
        if pressed { return self.pressed }
        return hover ? self.hover : .clear
    }
}

extension EnvironmentValues {
    @Entry var hoverPalette = HoverPalette.standard
}

/// Rows, tabs and small buttons: hover (lighter, 120 ms fade), pressed slightly darker, selection fades in 150 ms.
struct HoverButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(label: configuration.label, pressed: configuration.isPressed, selected: selected, radius: radius)
    }

    private struct HoverBody<Label: View>: View {
        let label: Label
        let pressed: Bool
        let selected: Bool
        let radius: CGFloat
        @Environment(\.hoverPalette) private var palette
        @State private var hover = false

        var body: some View {
            label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: radius)
                    .fill(palette.fill(selected: selected, pressed: pressed, hover: hover, interactive: true)))
                .pointingHand()
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
                .animation(Motion.ease(Theme.selectionFade), value: selected)
        }
    }
}

/// Row container with hover (lighter, 120 ms) and pressed (darker) backgrounds — only when it has an action;
/// hands `hover` to the content so rows can reveal `+`/pin on hover. Tap fires on mouse up inside.
struct HoverRow<Content: View>: View {
    var selected = false
    var action: (() -> Void)?
    /// Second click of a double-click (the first click already ran `action`).
    var doubleAction: (() -> Void)?
    /// Vertical drag (reorder): live translation, then the final one. nil = not draggable.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: ((CGFloat) -> Void)?
    @ViewBuilder var content: (_ hover: Bool) -> Content
    @Environment(\.hoverPalette) private var palette
    @State private var hover = false
    @State private var pressed = false
    @State private var dragging = false

    private var interactive: Bool { action != nil || doubleAction != nil }

    var body: some View {
        content(hover)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(palette.fill(selected: selected, pressed: pressed, hover: hover, interactive: interactive))
            .pointingHand(interactive)
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            // Global space: the dragged row is offset while dragging, local translations would feed back.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !pressed { pressed = true }
                    let moved = abs(value.translation.width) >= Theme.dragThreshold || abs(value.translation.height) >= Theme.dragThreshold
                    if let onDrag, dragging || moved {
                        dragging = true
                        onDrag(value.translation.height)
                    }
                }
                .onEnded { value in
                    pressed = false
                    if dragging {
                        dragging = false
                        onDragEnd?(value.translation.height)
                    } else if abs(value.translation.width) < Theme.dragThreshold, abs(value.translation.height) < Theme.dragThreshold {
                        if let doubleAction, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { doubleAction() } else { action?() }
                    }
                })
            .animation(Motion.ease(Theme.selectionFade), value: selected)
    }
}

extension View {
    /// Pointing hand over everything clickable (DESIGN.md «Курсор»); text fields, terminals and dividers keep theirs.
    func pointingHand(_ enabled: Bool = true) -> some View { modifier(PointingHand(enabled: enabled)) }

    /// I-beam inside a clickable (pointing-hand) row, e.g. the inline rename field.
    @ViewBuilder func textCursor() -> some View {
        if #available(macOS 15, *) { pointerStyle(.horizontalText) } else { self }
    }
}

private struct PointingHand: ViewModifier {
    let enabled: Bool
    @State private var pushed = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            // Balanced push/pop; disappearing mid-hover or the window losing key pops, so the cursor never sticks.
            content
                .onHover { inside in
                    hovering = inside
                    set(inside && enabled)
                }
                .onChange(of: enabled) { set(hovering && enabled) }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in set(false) }
                .onDisappear { set(false) }
        }
    }

    private func set(_ on: Bool) {
        guard on != pushed else { return }
        pushed = on
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}
