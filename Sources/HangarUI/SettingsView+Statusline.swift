import SwiftUI
import Workspace

/// Settings → Интеграции → Claude Code → «Строка состояния» (#105, #111): which line Claude shows, a live preview from the same
/// renderer as `hangar statusline`, its segments, and the projects whose own line Hangar overrides.
extension SettingsView {
    /// The status line row of the Claude Code card: the choice, the preview with its chips, the overridden projects.
    @ViewBuilder var statuslineRows: some View {
        let integration = app.integrations
        let mode = app.config.statusline
        FunctionRow(title: L10n.intStatuslineTitle, subtitle: L10n.intStatuslineSub) {
            Segment(selection: mode, options: [(.hangar, L10n.statuslineHangar), (.user, L10n.statuslineUser)],
                    disabled: integration.userStatusline == nil && mode != .user ? [.user] : []) { m in
                save { try app.setStatuslineMode(m) }
            }
            .help(mode == .hangar ? (integration.userStatusline == nil ? L10n.statuslineNoOwnHelp : L10n.statuslineHangarHelp)
                                  : integration.userStatusline.map(L10n.statuslineUserHelp) ?? L10n.statuslineNoOwnHelp)
        }
        // The hint under the choice, wrapped: beside it, it was cut to «Появится, когда…» (#110).
        if !integration.statuslineIsHangar {
            wideRow(divider: false) {
                Text(verbatim: L10n.statuslineNeedsIntegration).foregroundStyle(Theme.ui.text3)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
        }
        // The preview and the parts take the card's whole width: the line is ~60 columns.
        wideRow(divider: false) {
            StatuslineParts(mode: mode, chips: app.config.statuslineChips, on: app.config.statuslineSegments,
                            own: integration.userStatusline, title: segmentTitle,
                            toggle: { s, on in save { try app.setStatuslineSegment(s, on: on) } },
                            move: { s, i in save { try app.moveStatuslineSegment(s, to: i) } })
        }
        if !app.statuslineNotes.isEmpty {
            wideRow {
                Text(verbatim: L10n.statuslineProjects).foregroundStyle(Theme.ui.text2)
                ForEach(app.statuslineNotes) { note in statuslineNoteRow(note) }
            }
            .help(L10n.statuslineProjectsHelp)
        }
    }

    /// A card row without the label column, with `CardRow`'s paddings and divider.
    /// `divider: false` continues the row above (the status line's preview under its choice).
    func wideRow(divider: Bool = true, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.cardRowPaddingV) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, divider ? Theme.cardRowPaddingV : 0)
            .padding(.bottom, Theme.cardRowPaddingV)
            .padding(.horizontal, Theme.cardRowPaddingH)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(divider ? 1 : 0) }
    }

    private func segmentTitle(_ s: StatuslineSegment) -> String {
        switch s {
        case .model: L10n.statuslineSegModel
        case .context: L10n.statuslineSegContext
        case .fiveHour: L10n.statuslineSegFiveHour
        case .week: L10n.statuslineSegWeek
        case .branch: L10n.statuslineSegBranch
        case .effort: L10n.statuslineSegEffort
        }
    }

    private func statuslineNoteRow(_ note: StatuslineNote) -> some View {
        let (text, color): (String, Color) = switch note.problem {
        case nil: (L10n.statuslineOverridden, Theme.ui.text3)
        case .notIgnored?: (L10n.statuslineNotIgnored, Theme.ui.waiting)
        case .failed(let why)?: (L10n.statuslineFailed(why), Theme.ui.failedText)
        }
        let path = (note.host.map { $0 + ":" } ?? "") + tildePath(note.path)
        return HStack(spacing: Theme.pickGap) {
            Text(verbatim: note.name).foregroundStyle(Theme.ui.text).lineLimit(1).layoutPriority(2)
            Text(verbatim: path)
                .font(.system(size: Theme.fontSize.counter, design: .monospaced))
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.cardRowGap)
            Text(verbatim: text).foregroundStyle(color).lineLimit(1).layoutPriority(1)
        }
        .help(path + " — " + text)
    }
}

/// The sample line in the terminal's font and colours: the renderer's ANSI turned into styled text (the terminal's
/// yellow and red from the theme palette, faint as half the foreground, like Ghostty draws it).
struct StatuslinePreview: View {
    let mode: StatuslineMode
    let segments: [StatuslineSegment]
    let own: String?

    var body: some View {
        Group {
            if mode == .hangar {
                let line = renderStatusline(.sample(now: Date()), segments: segments, now: Date())
                // An overlay: the line's width never widens the card (at the minimum window it is wider); the end fades.
                Color.clear.frame(height: Theme.statuslinePreviewHeight)
                    .overlay(alignment: .leading) { StatuslineCells(line: line) }
                    .clipped()
                    .mask(HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Theme.statuslinePreviewFade)
                    })
            } else {
                Text(verbatim: own ?? L10n.statuslineUserPreview).foregroundStyle(Theme.ui.text3)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: Theme.statuslinePreviewFont, design: .monospaced))
        .padding(.horizontal, Theme.statuslinePreviewPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.statuslinePreviewHeight, alignment: .leading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: Theme.segmentRadius).fill(Theme.ui.of(Theme.palette.termBg)))
        .overlay(RoundedRectangle(cornerRadius: Theme.segmentRadius).stroke(Theme.ui.control, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .hangar ? L10n.statuslinePreview : L10n.statuslineUserPreview)
    }
}

/// The line as a terminal draws it: text runs, and the bars `━`/`─` as lines across whole cells (Ghostty draws box
/// drawing itself; a UI font would leave gaps between the glyphs).
private struct StatuslineCells: View {
    let line: String

    var body: some View {
        let cell = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: Theme.statuslinePreviewFont, weight: .regular)]).width
        HStack(spacing: 0) {
            ForEach(Array(statuslinePieces(line).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case let .text(text, tone):
                    Text(verbatim: text).foregroundStyle(statuslineColor(tone))
                case let .bar(cells, heavy, tone):
                    Rectangle().fill(statuslineColor(tone))
                        .frame(width: cell * CGFloat(cells), height: heavy ? Theme.statuslineBarHeavy : 1)
                }
            }
        }
        .fixedSize()
    }
}

enum StatuslinePiece: Equatable {
    case text(String, AnsiSpan.Tone)
    case bar(cells: Int, heavy: Bool, AnsiSpan.Tone)
}

/// The renderer's ANSI split into text and bar runs for the preview.
func statuslinePieces(_ line: String) -> [StatuslinePiece] {
    var pieces: [StatuslinePiece] = []
    for span in ansiSpans(line) {
        var rest = Substring(span.text)
        while let c = rest.first {
            if c == "━" || c == "─" {
                let run = rest.prefix { $0 == c }
                pieces.append(.bar(cells: run.count, heavy: c == "━", span.tone))
                rest = rest.dropFirst(run.count)
            } else {
                let run = rest.prefix { $0 != "━" && $0 != "─" }
                pieces.append(.text(String(run), span.tone))
                rest = rest.dropFirst(run.count)
            }
        }
    }
    return pieces
}

@MainActor func statuslineColor(_ tone: AnsiSpan.Tone) -> Color {
    switch tone {
    case .normal: Theme.ui.text
    case .dim: Theme.ui.text.opacity(Theme.statuslineFaint)
    case .yellow: Theme.ui.of(Hex(Theme.palette.ansi[3]))
    case .red: Theme.ui.of(Hex(Theme.palette.ansi[1]))
    }
}

/// The preview over the parts' chips (#110): a click (or Space) turns a chip on or off, a drag, ←/→ on the focused chip or
/// «Левее»/«Правее» in its menu move it, the off ones too. While dragging, an accent line marks where the chip lands
/// and the preview already shows that order; the row itself does not reflow until the drop. Released outside the
/// row, Escape, or a cancelled gesture: nothing moves.
private struct StatuslineParts: View {
    let mode: StatuslineMode
    let chips: [StatuslineSegment]
    let on: [StatuslineSegment]
    let own: String?
    let title: (StatuslineSegment) -> String
    let toggle: (StatuslineSegment, Bool) -> Void
    let move: (StatuslineSegment, Int) -> Void
    @State private var frames: [StatuslineSegment: CGRect] = [:]
    @State private var row: CGRect = .zero
    /// Resets by itself when the gesture ends or the system cancels it.
    @GestureState private var gesture: ChipDrag?
    @State private var escape = ChipDragEscape()

    private struct ChipDrag: Equatable {
        var segment: StatuslineSegment
        var dx: CGFloat
        /// Insertion index into `chips`; nil while the drop would change nothing or the pointer is off the row.
        var target: Int?
    }

    private var drag: ChipDrag? { escape.cancelled ? nil : gesture }

    var body: some View {
        let editable = mode == .hangar
        let order = drag.flatMap { d in d.target.map { statuslineMove(chips, d.segment, to: $0) } } ?? chips
        VStack(alignment: .leading, spacing: Theme.cardRowPaddingV) {
            StatuslinePreview(mode: mode, segments: order.filter(on.contains), own: own)
            ChipFlow(spacing: Theme.pickGap) {  // wraps: the Russian row is wider than the card at the minimum window
                ForEach(Array(chips.enumerated()), id: \.element) { i, s in
                    let isOn = on.contains(s)
                    let lifted = drag?.segment == s
                    SegmentChip(title: title(s), on: isOn, dragging: lifted, dx: lifted ? drag?.dx ?? 0 : 0) { toggle(s, !isOn) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(chipSpace)) } action: { frames[s] = $0 }
                        .highPriorityGesture(dragGesture(s), including: editable ? .all : .subviews)
                        .zIndex(lifted ? 1 : 0)
                        .help(editable ? L10n.statuslineChipHelp : "")
                        .onMoveCommand { direction in
                            guard editable else { return }
                            if direction == .left, i > 0 { move(s, i - 1) }
                            if direction == .right, i < chips.count - 1 { move(s, i + 2) }
                        }
                        .popoverContextMenu {
                            guard editable else { return [] }
                            return [.item(PopoverMenuItem(title: L10n.statuslineMoveLeft, enabled: i > 0) { move(s, i - 1) }),
                                    .item(PopoverMenuItem(title: L10n.statuslineMoveRight, enabled: i < chips.count - 1) { move(s, i + 2) })]
                        }
                        .accessibilityAction(named: L10n.statuslineMoveLeft) { if editable, i > 0 { move(s, i - 1) } }
                        .accessibilityAction(named: L10n.statuslineMoveRight) { if editable, i < chips.count - 1 { move(s, i + 2) } }
                }
            }
            .coordinateSpace(name: chipSpace)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(chipSpace)) } action: { row = $0 }
            .overlay(alignment: .topLeading) { dropLine }
            .disabled(!editable)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.statuslineParts)
        }
        .onChange(of: gesture == nil) { _, ended in if ended { escape.stop() } }
        // Closed mid-drag (⌘W with the button held): the monitor must not keep eating Escape app-wide.
        .onDisappear { escape.stop() }
    }

    private func dragGesture(_ s: StatuslineSegment) -> some Gesture {
        DragGesture(minimumDistance: Theme.dragThreshold, coordinateSpace: .named(chipSpace))
            .updating($gesture) { value, state, _ in
                if state == nil { escape.start() }
                state = ChipDrag(segment: s, dx: value.translation.width, target: target(s, at: value.location))
            }
            .onEnded { value in
                defer { escape.stop() }
                guard !escape.cancelled, let t = target(s, at: value.location) else { return }
                move(s, t)
            }
    }

    private func target(_ s: StatuslineSegment, at p: CGPoint) -> Int? {
        chipDropTarget(chips: chips, frames: frames, row: row, dragged: s, at: p)
    }

    /// The accent line in the gap where the dragged chip would land (its middle, or just outside the row's ends).
    @ViewBuilder private var dropLine: some View {
        let rects = chips.compactMap { frames[$0] }
        if let target = drag?.target, rects.count == chips.count {
            let half = Theme.pickGap / 2
            // Between two chips of one line: the gap's middle; else before the target chip or after the last one.
            let (x, rect) = target == chips.count ? (rects[target - 1].maxX + half, rects[target - 1])
                : target > 0 && rects[target - 1].minY == rects[target].minY ? ((rects[target - 1].maxX + rects[target].minX) / 2, rects[target])
                : (rects[target].minX - half, rects[target])
            RoundedRectangle(cornerRadius: Theme.statuslineDropLine / 2).fill(Theme.ui.accent)
                .frame(width: Theme.statuslineDropLine, height: rect.height)
                .offset(x: x - Theme.statuslineDropLine / 2, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Where a chip dragged to `p` lands: the gap nearest the pointer (before the first chip whose middle is right of
/// it); nil off the row (with a chip's height of slack around it) or when the order would not change.
func chipDropTarget(chips: [StatuslineSegment], frames: [StatuslineSegment: CGRect], row: CGRect,
                    dragged s: StatuslineSegment, at p: CGPoint) -> Int? {
    let slack = frames[s]?.height ?? 0
    guard row.insetBy(dx: -slack, dy: -slack).contains(p) else { return nil }
    // Chips are in reading order over wrapped lines: a chip is after the pointer on a lower line, or right of it on its
    // line; a pointer in the slack above or below counts on the first or last line.
    let y = min(max(p.y, row.minY), row.maxY)
    let index = chips.firstIndex { c in
        guard let f = frames[c] else { return false }
        return f.minY > y || (f.maxY >= y && f.midX > p.x)
    } ?? chips.count
    return statuslineMove(chips, s, to: index) != chips ? index : nil
}

/// Chips left to right, wrapping onto a new line when the card is narrower than the row.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { r in r.reduce(0) { $0 + $1.width } + spacing * CGFloat(r.count - 1) }.max() ?? 0
        let height = rows.map { r in r.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, i = 0
        for row in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            for size in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                i += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]], used: CGFloat = 0
        for size in subviews.map({ $0.sizeThatFits(.unspecified) }) {
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width { rows.append([]); used = 0 }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}

/// Escape during a chip drag: a key monitor lives only while the drag does; `cancelled` hides the drag at once and
/// keeps its end from moving anything.
@MainActor @Observable private final class ChipDragEscape {
    private(set) var cancelled = false
    @ObservationIgnored private var monitor: Any?

    func start() {
        cancelled = false
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }  // Escape
            self.cancelled = true
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The chips' row space: a dragged chip moves itself, so its own space would feed back.
private let chipSpace = "statuslineChips"

/// A segment's on/off chip: on like a chosen `Segment` item, off only outlined; any number on at once. A button (click,
/// Tab + Space); while dragged it follows the pointer sideways with an accent outline.
struct SegmentChip: View {
    let title: String
    let on: Bool
    var dragging = false
    var dx: CGFloat = 0
    let toggle: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: toggle) {
            Text(verbatim: title)
                .foregroundStyle(on ? Theme.ui.textStrong : hover || dragging ? Theme.ui.text : Theme.ui.text3)
                .padding(.vertical, Theme.segmentItemPaddingV)
                .padding(.horizontal, Theme.segmentItemPaddingH)
                .background(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                    .fill(on ? Theme.ui.control : hover || dragging ? Theme.ui.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                    .stroke(dragging ? Theme.ui.accent : Theme.ui.control, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .offset(x: dx)
        .opacity(enabled ? 1 : Theme.disabledButtonOpacity)
        .chipCursor(enabled: enabled, grabbing: dragging)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// The hand over a chip; a closed hand while it is dragged (macOS 15+; older systems keep the hand).
    @ViewBuilder func chipCursor(enabled: Bool, grabbing: Bool) -> some View {
        if #available(macOS 15, *) { pointerStyle(!enabled ? nil : grabbing ? .grabActive : .link) } else { pointingHand(enabled) }
    }
}
