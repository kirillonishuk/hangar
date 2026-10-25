import AgentStatus
import AppKit
import SwiftUI
import Workspace

/// Every icon in the UI (icons-v2.html, decision #56): line glyphs drawn in code on a 16 grid, 1.5 pt stroke at every
/// size, round caps and joins; only the agents keep their brand logos. No glyph data outside this file.
enum Icon: CaseIterable {
    case sidebarLeft, sidebarRight, add, project, branch, sshHost, editor, shell, diff, keepAwake, limits, settings
    case archive, splitRight, splitDown, close, pin, chevronDown, chevronUp, chevronRight, more
    case rename, finder, copy, openExternal, restore, trash, remove, refresh, reconnect, disconnect, checkServer
    case history
    case search
    case claude, codex

    /// The strokes in the mockup's 16×16 SVG space (y down); copied from its `<symbol id="g-…">` path data.
    var glyph: [Stroke] {
        switch self {
        case .sidebarLeft: [.frame, .line(p(6, 2.75), p(6, 13.25))]
        case .sidebarRight: [.frame, .line(p(10, 2.75), p(10, 13.25))]
        case .add: [.line(p(8, 3), p(8, 13)), .line(p(3, 8), p(13, 8))]
        case .project:
            [.shape(p(1.75, 2.75, r: 2), p(6.35, 2.75), p(7.95, 4.5), p(14.25, 4.5, r: 2), p(14.25, 13.25, r: 2), p(1.75, 13.25, r: 2))]
        case .branch:
            [.line(p(4, 2.25), p(4, 10.25)), .circle(p(4, 12), 1.75), .circle(p(12, 4), 1.75),
             .arc(from: p(12, 5.75), to: p(5.75, 12), r: 6.25, large: false, sweep: true)]
        case .sshHost:
            [.rect(1.75, 2.75, 12.5, 4.5, 2), .rect(1.75, 8.75, 12.5, 4.5, 2), .dot(p(4.75, 5)), .dot(p(4.75, 11))]
        case .editor:
            [.shape(p(10.5, 2.75), p(13.25, 5.5), p(5.5, 13.25), p(2.75, 13.25), p(2.75, 10.5)), .line(p(8.75, 4.5), p(11.5, 7.25))]
        case .shell: [.frame, .line(p(4.75, 6.25), p(6.75, 8), p(4.75, 9.75)), .line(p(8.75, 10), p(11.25, 10))]
        case .diff:
            [.line(p(4.75, 2.5), p(4.75, 7)), .line(p(2.5, 4.75), p(7, 4.75)), .line(p(9, 11.25), p(13.5, 11.25)),
             .line(p(12.5, 3.5), p(3.5, 12.5))]
        case .keepAwake:
            [.shape(p(2.75, 7), p(10.75, 7), p(10.75, 13.25, r: 3), p(2.75, 13.25, r: 3)),
             .line(p(10.75, 8), p(13.25, 8, r: 1.75), p(13.25, 11.5, r: 1.75), p(10.75, 11.5)),
             .line(p(5.25, 2.75), p(5.25, 4.5)), .line(p(8.25, 2.75), p(8.25, 4.5))]
        case .limits:
            [.arc(from: p(2.75, 12), to: p(13.25, 12), r: 5.75, large: true, sweep: true), .line(p(8, 9.65), p(10.9, 6.9)),
             .circle(p(8, 9.65), 0.6)]
        case .settings: [.shape(Self.gearTeeth.map { p($0.0, $0.1) }), .circle(p(8, 8), 2)]
        case .archive:
            [.rect(1.75, 2.75, 12.5, 3.25, 1), .line(p(3.25, 6), p(3.25, 13.25, r: 2), p(12.75, 13.25, r: 2), p(12.75, 6)),
             .line(p(6.5, 8.75), p(9.5, 8.75))]
        case .splitRight: [.frame, .line(p(8, 2.75), p(8, 13.25))]
        case .splitDown: [.frame, .line(p(1.75, 8), p(14.25, 8))]
        case .close: [.line(p(4, 4), p(12, 12)), .line(p(12, 4), p(4, 12))]
        case .pin:
            [.line(p(5.25, 2.75), p(10.75, 2.75)), .line(p(6.5, 2.75), p(6.5, 6.5), p(4.25, 9.25), p(11.75, 9.25), p(9.5, 6.5), p(9.5, 2.75)),
             .line(p(8, 9.25), p(8, 13.25))]
        case .chevronDown: [.line(p(4.5, 6.25), p(8, 9.75), p(11.5, 6.25))]
        case .chevronUp: [.line(p(4.5, 9.75), p(8, 6.25), p(11.5, 9.75))]
        case .chevronRight: [.line(p(6.25, 4.5), p(9.75, 8), p(6.25, 11.5))]
        case .more: [.dot(p(3.5, 8)), .dot(p(8, 8)), .dot(p(12.5, 8))]
        case .rename:
            [.line(p(5.25, 4.75), p(1.75, 4.75, r: 2), p(1.75, 11.25, r: 2), p(5.25, 11.25)),
             .line(p(10.75, 4.75), p(14.25, 4.75, r: 2), p(14.25, 11.25, r: 2), p(10.75, 11.25)),
             .line(p(8, 2.75), p(8, 13.25)), .line(p(6.5, 2.75), p(9.5, 2.75)), .line(p(6.5, 13.25), p(9.5, 13.25))]
        case .finder:
            [.frame, .line(p(8.75, 2.75), p(7, 8.25), p(8.75, 8.25), p(8.25, 13.25)), .line(p(4.75, 5.75), p(4.75, 6.75)),
             .line(p(11.25, 5.75), p(11.25, 6.75)), .quad(p(4.5, 10.25), p(8, 11.75), p(11.5, 10.25))]
        case .copy:
            [.rect(5.75, 5.75, 8.5, 7.5, 2), .line(p(10.25, 5.75), p(10.25, 2.75, r: 2), p(1.75, 2.75, r: 2), p(1.75, 11.25, r: 2), p(5.75, 11.25))]
        case .openExternal:
            [.line(p(14.25, 9.25), p(14.25, 13.25, r: 2), p(1.75, 13.25, r: 2), p(1.75, 2.75, r: 2), p(7.25, 2.75)),
             .line(p(10.5, 2.75), p(14.25, 2.75), p(14.25, 6.5)), .line(p(14.25, 2.75), p(8.5, 8.5))]
        case .restore:
            [.line(p(5.5, 3.25), p(2.75, 6), p(5.5, 8.75)), .line(p(2.75, 6), p(13, 6, r: 3.5), p(13, 13, r: 3.5), p(6.5, 13))]
        case .trash:
            [.line(p(2.25, 4.25), p(13.75, 4.25)), .line(p(6, 4.25), p(6, 2.25, r: 1), p(10, 2.25, r: 1), p(10, 4.25)),
             .line(p(3.75, 4.25), p(3.75, 13.25, r: 2), p(12.25, 13.25, r: 2), p(12.25, 4.25)),
             .line(p(6.75, 7), p(6.75, 10.5)), .line(p(9.25, 7), p(9.25, 10.5))]
        case .remove: [.circle(p(8, 8), 6.25), .line(p(5.25, 8), p(10.75, 8))]
        case .refresh:
            [.arc(from: p(14, 8), to: p(8, 2), r: 6, large: true, sweep: true),
             .curve(p(8, 2), p(9.68, 2), p(11.29, 2.67), p(12.5, 3.83)), .line(p(12.5, 3.83), p(14, 5.33)),
             .line(p(14, 2), p(14, 5.33), p(10.67, 5.33))]
        case .reconnect:
            [.line(p(5.75, 2.75), p(5.75, 5.75)), .line(p(10.25, 2.75), p(10.25, 5.75)),
             .shape(p(3.75, 5.75), p(12.25, 5.75), p(12.25, 12, r: 4.25), p(3.75, 12, r: 4.25)), .line(p(8, 12), p(8, 13.25))]
        case .disconnect: [.line(p(8, 2.75), p(8, 7.75)), .arc(from: p(4.5, 4.75), to: p(11.5, 4.75), r: 5, large: true, sweep: false)]
        case .checkServer: [.circle(p(8, 8), 6.25), .line(p(5.25, 8.25), p(7.1, 10.1), p(10.75, 6.25))]
        // redesign-v1.html `g-history`
        case .history:
            [.arc(from: p(1.75, 8), to: p(3.58, 3.58), r: 6.25, large: true, sweep: false), .line(p(3.58, 3.58), p(1.75, 5.4)),
             .line(p(1.75, 2.25), p(1.75, 5.4), p(4.9, 5.4)), .line(p(8, 4.75), p(8, 8), p(10.25, 9.5))]
        case .search: [.circle(p(7, 7), 4.75), .line(p(10.5, 10.5), p(13.75, 13.75))]  // redesign-v1.html g-search
        case .claude, .codex: []  // brand logos
        }
    }

    /// The approved symmetric gear of icons-sidebar.html: 8 teeth, outer r 6.31, inner r 4.62.
    private static let gearTeeth: [(CGFloat, CGFloat)] = [
        (12.59, 6.58), (14.31, 6.92), (14.31, 9.08), (12.59, 9.42), (12.25, 10.24), (13.23, 11.69), (11.69, 13.23), (10.24, 12.25),
        (9.42, 12.59), (9.08, 14.31), (6.92, 14.31), (6.58, 12.59), (5.76, 12.25), (4.31, 13.23), (2.77, 11.69), (3.75, 10.24),
        (3.41, 9.42), (1.69, 9.08), (1.69, 6.92), (3.41, 6.58), (3.75, 5.76), (2.77, 4.31), (4.31, 2.77), (5.76, 3.75),
        (6.58, 3.41), (6.92, 1.69), (9.08, 1.69), (9.42, 3.41), (10.24, 3.75), (11.69, 2.77), (13.23, 4.31), (12.25, 5.76),
    ]

    /// All strokes as one path in the 16 grid (tests check the keylines on it).
    var outline: NSBezierPath { path(scale: 1) }

    private func path(scale: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for stroke in glyph { stroke.append(to: path, scale: scale) }
        return path
    }

    static func of(_ kind: LeafKind) -> Icon {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        case .editor: .editor
        case .shell: .shell
        }
    }

    /// Agents use their brand logos drawn from embedded path data (BrandLogos.swift, decision #33), pre-tinted.
    private var brand: (data: String, tint: NSColor)? {
        switch self {
        case .claude: (BrandLogo.claude, Theme.claudeBrand)
        case .codex: (BrandLogo.openai, Theme.textStrong)
        default: nil
        }
    }

    var isBrand: Bool { brand != nil }

    /// For menus and AppKit views: the glyph at `Theme.iconSize`.
    var image: NSImage { image(size: Theme.iconSize) }

    /// Glyphs are template images (tinted by the caller), drawn natively at `size` so the stroke stays 1.5 pt;
    /// brand logos come pre-tinted. Cached per icon and size.
    func image(size: CGFloat) -> NSImage {
        MainActor.assumeIsolated {
            let key = CacheKey(icon: self, size: size)
            if let cached = Self.images[key] { return cached }
            let image = render(size: size)
            Self.images[key] = image
            return image
        }
    }

    private func render(size: CGFloat) -> NSImage {
        if let brand {
            let path = BrandLogo.path(brand.data)
            return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
                let t = NSAffineTransform()
                t.scale(by: size / BrandLogo.viewBox)
                path.transform(using: t as AffineTransform)
                brand.tint.setFill()
                path.fill()
                return true
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let path = self.path(scale: size / Theme.iconGrid)
            path.lineWidth = Theme.iconStroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func color(active: Bool) -> NSColor { active ? Theme.textStrong : Theme.text2 }

    private struct CacheKey: Hashable {
        let icon: Icon
        let size: CGFloat
    }

    @MainActor private static var images: [CacheKey: NSImage] = [:]
}

/// A point of the 16 grid; `r` rounds the corner a polyline makes there (the SVG `a r r` corners).
struct GridPoint: Equatable {
    let x: CGFloat
    let y: CGFloat
    var r: CGFloat = 0
}

private func p(_ x: CGFloat, _ y: CGFloat, r: CGFloat = 0) -> GridPoint { GridPoint(x: x, y: y, r: r) }

/// One stroke of a glyph (the primitives the mockup's paths use; no SVG parser).
enum Stroke: Equatable {
    case poly([GridPoint], closed: Bool)
    case rect(CGFloat, CGFloat, CGFloat, CGFloat, radius: CGFloat)
    case circle(GridPoint, CGFloat)
    /// SVG `A r r 0 large sweep to`, starting at `from`.
    case arc(from: GridPoint, to: GridPoint, r: CGFloat, large: Bool, sweep: Bool)
    case curve(GridPoint, GridPoint, GridPoint, GridPoint)
    /// A round dot as wide as the stroke (the mockup's zero-length `h.01`).
    case dot(GridPoint)

    static func line(_ points: GridPoint...) -> Stroke { .poly(points, closed: false) }
    static func shape(_ points: GridPoint...) -> Stroke { .poly(points, closed: true) }
    static func shape(_ points: [GridPoint]) -> Stroke { .poly(points, closed: true) }
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Stroke { .rect(x, y, w, h, radius: r) }
    /// The window frame most glyphs share: 1.75…14.25 × 2.75…13.25, radius 2.
    static let frame = Stroke.rect(1.75, 2.75, 12.5, 10.5, 2)

    /// SVG `Q`, as the equivalent cubic.
    static func quad(_ a: GridPoint, _ c: GridPoint, _ b: GridPoint) -> Stroke {
        .curve(a, p(a.x + 2 * (c.x - a.x) / 3, a.y + 2 * (c.y - a.y) / 3), p(b.x + 2 * (c.x - b.x) / 3, b.y + 2 * (c.y - b.y) / 3), b)
    }

    func append(to path: NSBezierPath, scale s: CGFloat) {
        func pt(_ g: GridPoint) -> NSPoint { NSPoint(x: g.x * s, y: g.y * s) }
        switch self {
        case .poly(let points, let closed):
            guard let first = points.first, let last = points.last else { return }
            func corner(_ i: Int, next: GridPoint) {
                if points[i].r > 0 { path.appendArc(from: pt(points[i]), to: pt(next), radius: points[i].r * s) } else { path.line(to: pt(points[i])) }
            }
            if closed {
                // Start mid-edge so a rounded first corner is drawn like the others.
                path.move(to: NSPoint(x: (first.x + last.x) / 2 * s, y: (first.y + last.y) / 2 * s))
                for i in points.indices { corner(i, next: points[(i + 1) % points.count]) }
                path.close()
            } else {
                path.move(to: pt(first))
                for i in points.indices.dropFirst().dropLast() { corner(i, next: points[i + 1]) }
                path.line(to: pt(last))
            }
        case .rect(let x, let y, let w, let h, let r):
            path.append(NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s), xRadius: r * s, yRadius: r * s))
        case .circle(let c, let r):
            path.append(NSBezierPath(ovalIn: NSRect(x: (c.x - r) * s, y: (c.y - r) * s, width: 2 * r * s, height: 2 * r * s)))
        case .arc(let from, let to, let r, let large, let sweep):
            // SVG endpoint → centre parameterisation (circle, no rotation).
            let hx = (from.x - to.x) / 2, hy = (from.y - to.y) / 2
            let d2 = hx * hx + hy * hy
            let k = (large == sweep ? -1 : 1) * (max(0, r * r - d2) / d2).squareRoot()
            let cx = k * hy, cy = -k * hx
            let center = p(cx + (from.x + to.x) / 2, cy + (from.y + to.y) / 2)
            let start = atan2(hy - cy, hx - cx) * 180 / .pi
            let end = atan2(-hy - cy, -hx - cx) * 180 / .pi
            path.move(to: pt(from))
            // y points down here, so SVG's positive sweep is increasing angles (AppKit's counter-clockwise).
            path.appendArc(withCenter: pt(center), radius: max(r, d2.squareRoot()) * s, startAngle: start, endAngle: end, clockwise: !sweep)
        case .curve(let a, let c1, let c2, let b):
            path.move(to: pt(a))
            path.curve(to: pt(b), controlPoint1: pt(c1), controlPoint2: pt(c2))
        case .dot(let c):
            // A tiny circle stroked 1.5 wide is a round dot; a zero-length line may not draw.
            path.append(NSBezierPath(ovalIn: NSRect(x: c.x * s - 0.05, y: c.y * s - 0.05, width: 0.1, height: 0.1)))
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
        // Glyphs are drawn at `size` (no scaling, the stroke stays 1.5 pt).
        Image(nsImage: icon.image(size: size))
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
    static let sheet = HoverPalette(hover: Theme.ui.sheetHover, pressed: Theme.ui.pressed)
    static let strong = HoverPalette(hover: Theme.ui.hoverStrong, pressed: Theme.ui.pressed)

    /// Rows without an action (section headers, …) get no hover/press fill.
    func fill(selected: Bool, pressed: Bool, hover: Bool, interactive: Bool) -> Color {
        if selected { return Theme.ui.selection }
        guard interactive else { return .clear }
        if pressed { return self.pressed }
        return hover ? self.hover : .clear
    }

    /// The opaque color a row shows (its fill over `base`), for overlays that must blend into it.
    func background(selected: Bool, hover: Bool, base: Color) -> Color {
        selected ? Theme.ui.selection : hover ? self.hover : base
    }
}

/// Where a `HoverRow` draws its hover/selection fill: full width (default), or inset with rounded corners (sidebar).
struct RowHighlight: Sendable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var radius: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var hoverPalette = HoverPalette.standard
    @Entry var rowHighlight = RowHighlight()
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
    /// Drawn as hovered regardless of the pointer (debug snapshots).
    var forceHover = false
    @ViewBuilder var content: (_ hover: Bool) -> Content
    @Environment(\.hoverPalette) private var palette
    @Environment(\.rowHighlight) private var highlight
    @State private var hover = false
    @State private var pressed = false
    @State private var dragging = false

    private var interactive: Bool { action != nil || doubleAction != nil }

    var body: some View {
        let hover = self.hover || forceHover
        content(hover)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: highlight.radius)
                .fill(palette.fill(selected: selected, pressed: pressed, hover: hover, interactive: interactive))
                .padding(.leading, highlight.leading)
                .padding(.trailing, highlight.trailing))
            .pointingHand(interactive)
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { self.hover = h } }
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
