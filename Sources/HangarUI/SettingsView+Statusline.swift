import SwiftUI
import Workspace

/// Settings → Интеграции → «Строка состояния Claude» (#105): which line Claude shows, a live preview from the same
/// renderer as `hangar statusline`, its segments, and the projects whose own line Hangar overrides.
extension SettingsView {
    var statusline: some View {
        let integration = model.integration
        let mode = app.config.statusline
        return CardSection(title: L10n.statuslineTitle) {
            row(L10n.statuslineShow, first: true) {
                Segment(selection: mode, options: [(.hangar, L10n.statuslineHangar), (.user, L10n.statuslineUser)],
                        disabled: integration.userStatusline == nil && mode != .user ? [.user] : []) { m in
                    save { try app.setStatuslineMode(m) }
                }
                .help(mode == .hangar ? (integration.userStatusline == nil ? L10n.statuslineNoOwnHelp : L10n.statuslineHangarHelp)
                                      : integration.userStatusline.map(L10n.statuslineUserHelp) ?? L10n.statuslineNoOwnHelp)
            }
            // The hint under the choice, wrapped: beside it, it was cut to «Появится, когда…» (#110).
            if !integration.statuslineIsHangar {
                wideRow {
                    Text(verbatim: L10n.statuslineNeedsIntegration).foregroundStyle(Theme.ui.text3)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
            }
            // The preview and the parts take the card's whole width: the line is ~60 columns.
            wideRow {
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
    }

    /// A card row without the label column, with `CardRow`'s paddings and divider.
    private func wideRow(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.cardRowPaddingV) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.cardRowPaddingV)
            .padding(.horizontal, Theme.cardRowPaddingH)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1) }
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
                StatuslineCells(line: line)
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

/// The preview over the parts' chips (#110): a click turns a chip on or off, a drag (or «Левее»/«Правее» in its menu)
/// moves it, the off ones too. While dragging, an accent line marks where the chip lands and the preview already shows
/// that order; the row itself does not reflow until the drop.
private struct StatuslineParts: View {
    let mode: StatuslineMode
    let chips: [StatuslineSegment]
    let on: [StatuslineSegment]
    let own: String?
    let title: (StatuslineSegment) -> String
    let toggle: (StatuslineSegment, Bool) -> Void
    let move: (StatuslineSegment, Int) -> Void
    @State private var frames: [StatuslineSegment: CGRect] = [:]
    @State private var drag: ChipDrag?

    private struct ChipDrag: Equatable {
        var segment: StatuslineSegment
        var dx: CGFloat = 0
        /// Insertion index into `chips`; nil while the drop would change nothing.
        var target: Int?
    }

    var body: some View {
        let editable = mode == .hangar
        let order = drag.flatMap { d in d.target.map { statuslineMove(chips, d.segment, to: $0) } } ?? chips
        VStack(alignment: .leading, spacing: Theme.cardRowPaddingV) {
            StatuslinePreview(mode: mode, segments: order.filter(on.contains), own: own)
            HStack(spacing: Theme.pickGap) {
                ForEach(Array(chips.enumerated()), id: \.element) { i, s in
                    let isOn = on.contains(s)
                    let lifted = drag?.segment == s
                    SegmentChip(title: title(s), on: isOn, dragging: lifted, dx: lifted ? drag?.dx ?? 0 : 0,
                                toggle: { toggle(s, !isOn) },
                                onDrag: editable ? { x, dx in dragged(s, x: x, dx: dx) } : nil,
                                onDragEnd: { dropped() })
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(chipSpace)) } action: { frames[s] = $0 }
                        .zIndex(lifted ? 1 : 0)
                        .help(editable ? L10n.statuslineChipHelp : "")
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
            .overlay(alignment: .topLeading) { dropLine }
            .disabled(!editable)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.statuslineParts)
        }
    }

    /// The accent line in the gap where the dragged chip would land (its middle, or just outside the row's ends).
    @ViewBuilder private var dropLine: some View {
        let rects = chips.compactMap { frames[$0] }
        if let target = drag?.target, rects.count == chips.count, let first = rects.first {
            let half = Theme.pickGap / 2
            let x = target == 0 ? first.minX - half : target == chips.count ? rects[target - 1].maxX + half
                : (rects[target - 1].maxX + rects[target].minX) / 2
            RoundedRectangle(cornerRadius: Theme.statuslineDropLine / 2).fill(Theme.ui.accent)
                .frame(width: Theme.statuslineDropLine, height: first.height)
                .offset(x: x - Theme.statuslineDropLine / 2, y: first.minY)
                .allowsHitTesting(false)
        }
    }

    private func dragged(_ s: StatuslineSegment, x: CGFloat, dx: CGFloat) {
        // The gap nearest the pointer: before the first chip whose middle is right of it.
        let index = chips.firstIndex { (frames[$0]?.midX ?? 0) > x } ?? chips.count
        drag = ChipDrag(segment: s, dx: dx, target: statuslineMove(chips, s, to: index) != chips ? index : nil)
    }

    private func dropped() {
        guard let d = drag else { return }
        drag = nil
        if let target = d.target { move(d.segment, target) }
    }
}

/// The chips' row space: a dragged chip moves itself, so its own space would feed back.
private let chipSpace = "statuslineChips"

/// A segment's on/off chip: on like a chosen `Segment` item, off only outlined; any number on at once. A click toggles;
/// with `onDrag` it follows the pointer sideways (pointer x in the row's space, translation).
struct SegmentChip: View {
    let title: String
    let on: Bool
    var dragging = false
    var dx: CGFloat = 0
    let toggle: () -> Void
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: () -> Void = {}
    @State private var hover = false
    @State private var moved = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Text(verbatim: title)
            .foregroundStyle(on ? Theme.ui.textStrong : hover || dragging ? Theme.ui.text : Theme.ui.text3)
            .padding(.vertical, Theme.segmentItemPaddingV)
            .padding(.horizontal, Theme.segmentItemPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                .fill(on ? Theme.ui.control : hover || dragging ? Theme.ui.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                .stroke(dragging ? Theme.ui.accent : Theme.ui.control, lineWidth: 1))
            .contentShape(Rectangle())
            .fixedSize()
            .offset(x: dx)
            .opacity(enabled ? 1 : Theme.disabledButtonOpacity)
            .chipCursor(enabled: enabled, grabbing: dragging)
            .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(chipSpace))
                .onChanged { value in
                    guard enabled, let onDrag else { return }
                    if !moved, abs(value.translation.width) < Theme.dragThreshold, abs(value.translation.height) < Theme.dragThreshold { return }
                    moved = true
                    onDrag(value.location.x, value.translation.width)
                }
                .onEnded { _ in
                    guard enabled else { return }
                    if moved { moved = false; onDragEnd() } else { toggle() }
                })
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { if enabled { toggle() } }
    }
}

private extension View {
    /// The hand over a chip; a closed hand while it is dragged (macOS 15+; older systems keep the hand).
    @ViewBuilder func chipCursor(enabled: Bool, grabbing: Bool) -> some View {
        if #available(macOS 15, *) { pointerStyle(!enabled ? nil : grabbing ? .grabActive : .link) } else { pointingHand(enabled) }
    }
}
