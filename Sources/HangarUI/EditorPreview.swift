import AppKit
import SwiftUI
import Workspace

/// The preview's samples (#108): static token markup, so every group shows without tsserver. `«group|text»` is a
/// token (`group@mark` adds the selection, a find match, or diff's added / removed text); `«caret|»` is the cursor.
enum EditorPreviewSample: CaseIterable {
    case typescript, json, diff

    var title: String {
        switch self {
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .diff: "Diff"
        }
    }

    var lines: [EditorPreviewLine] {
        switch self {
        case .typescript: Self.ts
        case .json: Self.jsonLines
        case .diff: Self.diffLines
        }
    }

    /// The sample has something of this color to show (rows of other samples switch the preview).
    func shows(_ color: EditorColor) -> Bool {
        switch color {
        case .background, .gutter, .text, .whitespace: return true
        case .line, .gutterActive, .cursor, .selection, .find, .indentActive: return self == .typescript
        case .indent: return self != .diff
        case .diffAddedLine, .diffRemovedLine, .diffAddedText, .diffRemovedText: return self == .diff
        default: return lines.contains { $0.runs.contains { $0.color == color } }
        }
    }

    /// The line that shows `color` (where a hovered row scrolls the preview).
    func line(showing color: EditorColor) -> Int? {
        let line: EditorPreviewLine? = switch color {
        case .line, .cursor, .gutterActive, .indentActive: lines.first { $0.current }
        case .selection: lines.first { $0.runs.contains { $0.mark == .selection } }
        case .find: lines.first { $0.runs.contains { $0.mark == .find } }
        case .diffAddedLine, .diffAddedText: lines.first { $0.change == .added }
        case .diffRemovedLine, .diffRemovedText: lines.first { $0.change == .removed }
        case .indent: lines.first { $0.indent >= 4 }
        default: lines.first { $0.runs.contains { $0.color == color } }
        }
        return line?.id
    }

    #if DEBUG
    /// The popover anchor of the first token of `color` in `sample` (debug `edtheme color <id> preview`).
    static func anchor(of color: EditorColor, in sample: Self) -> String? {
        sample.lines.lazy.flatMap(\.runs).first { $0.color == color }?.id
    }
    #endif

    private static let ts = parse([
        #"«control|import» «bracket1|{» «function|readFile» «bracket1|}» «control|from» «string|"node:fs/promises"»«punctuation|;»"#,
        #"«control|import» «keyword|type» «bracket1|{» «type|Session» «bracket1|}» «control|from» «string|"./model"»«punctuation|;»"#,
        #"«keyword|const» «constant|NAME» «operator|=» «regexp|/^[a-z-]+$/»«punctuation|;» «comment|// session id»"#,
        #"«control|export» «keyword|async» «keyword|function» «function|load»«bracket1|(»«variable|path»«punctuation|:» «type|string»«bracket1|)» «bracket1|{»"#,
        #"  «keyword|const» «constant|MAX_TABS» «operator|=» «number|12»«punctuation|;»«caret|»"#,
        #"  «keyword|const» «variable@selection|raw» «operator|=» «control|await» «function|readFile»«bracket2|(»«variable|path»«punctuation|,» «string|"utf8"»«bracket2|)»«punctuation|;»"#,
        #"  «keyword|const» «variable|data» «operator|=» «type|JSON»«punctuation|.»«function|parse»«bracket2|(»«variable|raw»«bracket2|)» «keyword|as» «type|Session»«punctuation|;»"#,
        #"  «control|if» «bracket2|(»«variable|data»«punctuation|.»«variable|tabs»«punctuation|.»«variable|length» «operator|>» «constant@find|MAX_TABS»«bracket2|)» «bracket2|{»"#,
        #"    «control|return» «bracket3|[»«variable|data»«bracket3|]»«punctuation|;»"#,
        #"  «bracket2|}»"#,
        #"  «control|return» «variable|data»«punctuation|.»«variable|name»«punctuation|.»«function|split»«bracket2|(»«string|"»«escape|\t»«string|"»«bracket2|)»«punctuation|;»"#,
        #"«bracket1|}»"#,
    ], current: 5, activeIndent: true)

    private static let jsonLines = parse([
        #"«bracket1|{»"#,
        #"  «jsonKey|"name"»«punctuation|:» «string|"hangar"»«punctuation|,»"#,
        #"  «jsonKey|"version"»«punctuation|:» «string|"0.42.0"»«punctuation|,»"#,
        #"  «jsonKey|"private"»«punctuation|:» «keyword|true»«punctuation|,»"#,
        #"  «jsonKey|"tabs"»«punctuation|:» «number|3»«punctuation|,»"#,
        #"  «jsonKey|"theme"»«punctuation|:» «keyword|null»«punctuation|,»"#,
        #"  «jsonKey|"agents"»«punctuation|:» «bracket2|[»«string|"claude"»«punctuation|,» «string|"codex"»«bracket2|]»"#,
        #"«bracket1|}»"#,
    ])

    private static let diffLines: [EditorPreviewLine] = {
        let rows: [(Int?, Int?, EditorPreviewLine.Change?, String)] = [
            (5, 5, nil, #"  «keyword|const» «constant|MAX_TABS» «operator|=» «number|12»«punctuation|;»"#),
            (6, 6, nil, #"  «keyword|const» «variable|raw» «operator|=» «control|await» «function|readFile»«bracket2|(»«variable|path»«punctuation|,» «string|"utf8"»«bracket2|)»«punctuation|;»"#),
            (7, nil, .removed, #"  «keyword|const» «variable|data» «operator|=» «type|JSON»«punctuation|.»«function|parse»«bracket2|(»«variable|raw»«bracket2|)» «keyword|as» «keyword@removed|any»«punctuation|;»"#),
            (nil, 7, .added, #"  «keyword|const» «variable|data» «operator|=» «type|JSON»«punctuation|.»«function|parse»«bracket2|(»«variable|raw»«bracket2|)» «keyword|as» «type@added|Session»«punctuation|;»"#),
            (8, 8, nil, #"  «control|if» «bracket2|(»«variable|data»«punctuation|.»«variable|tabs»«punctuation|.»«variable|length» «operator|>» «constant|MAX_TABS»«bracket2|)» «bracket2|{»"#),
        ]
        return rows.enumerated().map { i, row in
            var line = parse([row.3])[0]
            line.id = i
            line.number = row.1
            line.old = row.0
            line.change = row.2
            return line
        }
    }()

    private static func parse(_ source: [String], current: Int? = nil, activeIndent: Bool = false) -> [EditorPreviewLine] {
        source.enumerated().map { i, text in
            let indent = text.prefix { $0 == " " }.count
            var runs: [EditorPreviewRun] = []
            var col = indent
            var rest = Substring(text.dropFirst(indent))
            func plain(_ s: Substring) {
                guard !s.isEmpty else { return }
                runs.append(EditorPreviewRun(id: "\(i)-\(col)", text: String(s), col: col, color: .text, mark: nil))
                col += s.count
            }
            while let open = rest.range(of: "«") {
                plain(rest[..<open.lowerBound])
                guard let bar = rest[open.upperBound...].firstIndex(of: "|"),
                      let close = rest[bar...].firstIndex(of: "»") else { break }
                let tag = rest[open.upperBound..<bar].split(separator: "@")
                let body = String(rest[rest.index(after: bar)..<close])
                if tag.first == "caret" {
                    runs.append(EditorPreviewRun(id: "\(i)-caret", text: "", col: col, color: .cursor, mark: .caret))
                } else {
                    let color = EditorColor.allCases.first { "\($0)" == tag[0] } ?? .text
                    let mark = tag.count > 1 ? EditorPreviewRun.Mark(rawValue: String(tag[1])) : nil
                    runs.append(EditorPreviewRun(id: "\(i)-\(col)", text: body, col: col, color: color, mark: mark))
                    col += body.count
                }
                rest = rest[rest.index(after: close)...]
            }
            plain(rest)
            return EditorPreviewLine(id: i, number: i + 1, runs: runs, indent: indent, current: current == i + 1,
                                     activeIndent: activeIndent && i + 1 > 4 && i + 1 < 12)
        }
    }
}

struct EditorPreviewRun: Identifiable {
    enum Mark: String { case selection, find, added, removed, caret }
    let id: String
    let text: String
    let col: Int
    let color: EditorColor
    let mark: Mark?
}

struct EditorPreviewLine: Identifiable {
    enum Change { case added, removed }
    var id: Int
    var number: Int?
    var old: Int?
    var change: Change?
    var runs: [EditorPreviewRun]
    /// Leading spaces: guides every two.
    var indent: Int
    var current: Bool
    /// The cursor's block: its first guide is the active one.
    var activeIndent: Bool

    init(id: Int, number: Int?, runs: [EditorPreviewRun], indent: Int, current: Bool, activeIndent: Bool) {
        self.id = id
        self.number = number
        self.runs = runs
        self.indent = indent
        self.current = current
        self.activeIndent = activeIndent
    }
}

/// The preview box: the sample in the theme's colors and the editor's font; hovering a list row dims everything but
/// that color (or outlines its area), a click on a token opens its color.
struct EditorPreview: View {
    @Bindable var model: EditorSettingsModel
    let options: EditorOptions

    private typealias S = Theme.EditorSettings

    var body: some View {
        let theme = model.theme
        let font = Self.font(options.fontFamily)
        let cw = Self.charWidth(font)
        let lines = model.sample.lines
        let diff = model.sample == .diff
        let gutter = diff ? 2 * S.previewDiffGutter + S.previewDiffMarker : S.previewGutter
        // A short window shows fewer lines (the list under the pinned preview stays usable); the rest scrolls, and a
        // hovered row brings its line into view.
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        row(line, theme: theme, cw: cw, gutter: gutter)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.hovered) { _, color in
                guard let color, let id = model.sample.line(showing: color) else { return }
                withAnimation(Motion.ease(Theme.selectionFade)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .font(Font(font))
        // Padding outside the scroll view: the box shows whole lines only.
        .frame(height: CGFloat(Self.visibleLines(model.pageHeight)) * S.previewLineHeight)
        .padding(.vertical, S.previewPaddingV)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.ui.editor(theme.hex(.background)))
        .overlay { if model.hovered == .background { outline() } }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.background, anchor: "background") }
        .popover(isPresented: presented("background"), arrowEdge: .top) { popover }
        .clipped()
    }

    // MARK: Lines

    private func row(_ line: EditorPreviewLine, theme t: EditorTheme, cw: CGFloat, gutter: CGFloat) -> some View {
        let lineColor: EditorColor? = line.change == .added ? .diffAddedLine : line.change == .removed ? .diffRemovedLine : nil
        let showLine = line.current && (options.lineHighlight == .line || options.lineHighlight == .all)
        return HStack(spacing: 0) {
            numbers(line, theme: t, gutter: gutter)
            ZStack(alignment: .topLeading) {
                guides(line, theme: t, cw: cw)
                ForEach(line.runs) { run in token(run, theme: t, cw: cw) }
            }
            .padding(.leading, S.previewCodeGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: S.previewLineHeight)
        .background {
            if let lineColor { Theme.ui.editor(t.hex(lineColor)) }
            else if showLine {
                if t.lineFilled { Theme.ui.editor(t.hex(.line)) }
                else { Rectangle().strokeBorder(Theme.ui.editor(t.hex(.line)), lineWidth: 2) }
            }
        }
        .overlay {
            if let lineColor, model.hovered == lineColor { outline() }
            if line.current, model.hovered == .line { outline() }
        }
    }

    @ViewBuilder private func numbers(_ line: EditorPreviewLine, theme t: EditorTheme, gutter: CGFloat) -> some View {
        let color: EditorColor = line.current ? .gutterActive : .gutter
        let lit = model.hovered == nil || model.hovered == color || model.hovered == .gutter && color == .gutterActive
        HStack(spacing: 0) {
            if model.sample == .diff {
                number(line.old, width: S.previewDiffGutter)
                number(line.number, width: S.previewDiffGutter)
                Text(verbatim: line.change == .added ? "+" : line.change == .removed ? "−" : "")
                    .frame(width: S.previewDiffMarker)
            } else {
                number(line.number, width: gutter)
            }
        }
        .foregroundStyle(Theme.ui.editor(t.hex(color)))
        .opacity(lit ? 1 : Theme.Opacity.inactive)
        .overlay { if model.hovered == color { outline() } }
        .contentShape(Rectangle())
        .onTapGesture { model.open(color, anchor: "gutter-\(line.id)") }
        .popover(isPresented: presented("gutter-\(line.id)"), arrowEdge: .top) { popover }
        .pointingHand()
    }

    private func number(_ n: Int?, width: CGFloat) -> some View {
        Text(verbatim: n.map(String.init) ?? "").frame(width: width, alignment: .trailing)
    }

    /// Indent guides (one per two spaces) and, when shown, the whitespace dots.
    @ViewBuilder private func guides(_ line: EditorPreviewLine, theme t: EditorTheme, cw: CGFloat) -> some View {
        let levels = line.indent / 2
        if options.indentGuides {
            ForEach(0..<levels, id: \.self) { level in
                let color: EditorColor = level == 0 && line.activeIndent ? .indentActive : .indent
                Rectangle().fill(Theme.ui.editor(t.hex(color)))
                    .frame(width: S.guideWidth, height: S.previewLineHeight)
                    .offset(x: CGFloat(level * 2) * cw)
            }
        }
        if options.whitespace == .all || model.hovered == .whitespace || model.editing == .whitespace {
            ForEach(0..<line.indent, id: \.self) { col in
                Text(verbatim: "·").foregroundStyle(Theme.ui.editor(t.hex(.whitespace)))
                    .frame(width: cw, height: S.previewLineHeight)
                    .offset(x: CGFloat(col) * cw)
            }
        }
    }

    // MARK: Tokens

    @ViewBuilder private func token(_ run: EditorPreviewRun, theme t: EditorTheme, cw: CGFloat) -> some View {
        if run.mark == .caret {
            caret(t, cw: cw).offset(x: CGFloat(run.col) * cw)
        } else {
            let color = Self.shown(run.color, options)
            let markColor: EditorColor? = switch run.mark {
            case .selection: .selection
            case .find: .find
            case .added: .diffAddedText
            case .removed: .diffRemovedText
            default: nil
            }
            // The list's bracket row (hovered as `bracket1`) lights all three depths.
            let lit = model.hovered == nil || model.hovered == color || model.hovered == .bracket1 && [.bracket2, .bracket3].contains(color)
            Text(verbatim: run.text)
                .foregroundStyle(Theme.ui.editor(t.hex(color)))
                .italic(color == .comment && t.italicComments)
                .fixedSize()
                .frame(height: S.previewLineHeight)
                .opacity(lit ? 1 : Theme.Opacity.inactive)
                .background { if let markColor { Theme.ui.editor(t.hex(markColor)) } }
                .overlay { if let markColor, model.hovered == markColor { outline() } }
                .contentShape(Rectangle())
                .onTapGesture { model.open(color, anchor: run.id) }
                .popover(isPresented: presented(run.id), arrowEdge: .top) { popover }
                .pointingHand()
                .offset(x: CGFloat(run.col) * cw)
        }
    }

    private func caret(_ t: EditorTheme, cw: CGFloat) -> some View {
        let c = Theme.ui.editor(t.hex(.cursor))
        return ZStack(alignment: .bottomLeading) {
            switch options.cursorStyle {
            case .line: c.frame(width: S.cursorWidth, height: S.previewLineHeight)
            case .block: c.opacity(Theme.Opacity.inactive).frame(width: cw, height: S.previewLineHeight)
            case .underline: c.frame(width: cw, height: S.cursorWidth)
            }
        }
        .frame(width: max(cw, S.cursorWidth), height: S.previewLineHeight, alignment: .bottomLeading)
        .overlay { if model.hovered == .cursor { outline() } }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.cursor, anchor: "caret") }
        .popover(isPresented: presented("caret"), arrowEdge: .top) { popover }
        .pointingHand()
    }

    private func outline() -> some View {
        RoundedRectangle(cornerRadius: S.outlineRadius).strokeBorder(Theme.ui.accent, lineWidth: S.outlineWidth)
    }

    private var popover: some View { EditorColorPopover(model: model) }

    private func presented(_ anchor: String) -> Binding<Bool> {
        Binding(get: { model.editing != nil && model.anchor == anchor }, set: { if !$0, model.anchor == anchor { model.close() } })
    }

    /// Lines the preview shows for a settings page this tall: all 12 at the default size, 6 at the minimum.
    static func visibleLines(_ pageHeight: CGFloat) -> Int {
        guard pageHeight > 0 else { return Theme.EditorSettings.previewLines }
        let fit = Int(((pageHeight - Theme.EditorSettings.previewReserve) / Theme.EditorSettings.previewLineHeight).rounded(.down))
        return min(Theme.EditorSettings.previewLines, max(Theme.EditorSettings.previewMinLines, fit))
    }

    /// Brackets take the punctuation color when depth colors are off (as in Monaco).
    static func shown(_ color: EditorColor, _ options: EditorOptions) -> EditorColor {
        [.bracket1, .bracket2, .bracket3].contains(color) && !options.bracketColors ? .punctuation : color
    }

    /// The editor's font at the preview's size: the chosen family, else the system monospace (SF Mono).
    static func font(_ family: String?) -> NSFont {
        let size = Theme.EditorSettings.previewFont
        if let family, let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func charWidth(_ font: NSFont) -> CGFloat {
        ("M" as NSString).size(withAttributes: [.font: font]).width
    }
}
