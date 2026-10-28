import SwiftUI
import Workspace

/// Settings → Интеграции → «Строка состояния Claude» (#103): which line Claude shows, a live preview from the same
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
                if !integration.statuslineIsHangar {
                    Text(verbatim: L10n.statuslineNeedsIntegration).foregroundStyle(Theme.ui.text3)
                        .lineLimit(1).truncationMode(.tail).help(L10n.statuslineNeedsIntegration)
                }
            }
            // The preview and the parts take the card's whole width: the line is ~60 columns.
            wideRow {
                StatuslinePreview(mode: mode, segments: app.config.statuslineSegments, own: integration.userStatusline)
                HStack(spacing: Theme.pickGap) {
                    ForEach(StatuslineSegment.allCases, id: \.self) { segment in
                        let on = app.config.statuslineSegments.contains(segment)
                        SegmentChip(title: segmentTitle(segment), on: on) { save { try app.setStatuslineSegment(segment, on: !on) } }
                    }
                }
                .disabled(mode != .hangar)
                .accessibilityLabel(L10n.statuslineParts)
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
                let line = renderStatusline(.sample(now: Date()), segments: segments,
                                            ru: L10n.resolve(L10n.language) == .ru, now: Date())
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

/// A segment's on/off chip: on like a chosen `Segment` item, off only outlined; any number on at once.
struct SegmentChip: View {
    let title: String
    let on: Bool
    let toggle: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: toggle) {
            Text(verbatim: title)
                .foregroundStyle(on ? Theme.ui.textStrong : hover ? Theme.ui.text : Theme.ui.text3)
                .padding(.vertical, Theme.segmentItemPaddingV)
                .padding(.horizontal, Theme.segmentItemPaddingH)
                .background(RoundedRectangle(cornerRadius: Theme.segmentItemRadius)
                    .fill(on ? Theme.ui.control : hover ? Theme.ui.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.segmentItemRadius).stroke(Theme.ui.control, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(enabled ? 1 : Theme.disabledButtonOpacity)
        .pointingHand(enabled)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
