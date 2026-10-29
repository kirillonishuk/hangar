import AppKit
import SwiftUI
import Workspace

/// Settings → Editor (#84, #108, editor-theme.html): theme tiles, «Цвета» (the preview pinned above the list while the
/// list scrolls), the editor's options, then the language servers (#102). Everything fits the window's minimum width.
extension SettingsView {
    var editor: some View {
        let ed = model.editorTheme
        return VStack(alignment: .leading, spacing: Theme.settingsSectionGap) {
            editorThemes(ed)
            editorColors(ed)
            editorFont
            editorIndent
            editorView
            CardSection(title: L10n.s(.edEditSection)) {
                row(L10n.s(.edFormatOnSave), first: true) {
                    CardSwitch(on: options.formatOnSave) { on in setOption("editor_format_on_save", flag: on) { $0.formatOnSave = on } }
                        .help(L10n.s(.edFormatTip))
                }
            }
            languageServers
        }
        .sheet(isPresented: Binding(get: { ed.pendingReplace != nil }, set: { if !$0 { ed.cancelReplace() } })) {
            ConfirmSheet(message: L10n.s(.edReplaceTitle),
                         info: L10n.f(.edReplaceInfo, EditorSettingsModel.name(app.config.editorCustomBase),
                                      EditorSettingsModel.name(app.config.editorPalette)),
                         button: L10n.s(.edReplace), onConfirm: { _ in ed.confirmReplace() }, onCancel: { ed.cancelReplace() })
        }
    }

    private var options: EditorOptions { app.config.editorOptions }

    // MARK: Theme

    private func editorThemes(_ ed: EditorSettingsModel) -> some View {
        let config = app.config
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.themeTileGap), count: Theme.EditorSettings.tileColumns)
        return CardSection(title: L10n.themeTitle, card: false) {
            VStack(alignment: .leading, spacing: Theme.settingsHeaderGap) {
                LazyVGrid(columns: columns, spacing: Theme.themeTileGap) {
                    ForEach(EditorPalette.allCases, id: \.self) { palette in
                        EditorThemeTile(name: EditorSettingsModel.name(palette), theme: EditorTheme(config, palette: palette),
                                        selected: config.editorPalette == palette) { ed.choose(palette) }
                    }
                }
                themeHint(ed)
            }
        }
    }

    /// What the chosen theme is (two lines of room, so switching never moves the page) and «Сбросить всё» for «Своя».
    private func themeHint(_ ed: EditorSettingsModel) -> some View {
        let config = app.config
        let base = EditorSettingsModel.name(config.editorCustomBase)
        let text = switch config.editorPalette {
        case .darkModern: L10n.s(.edHintModern)
        case .darkPlus: L10n.s(.edHintPlus)
        case .hangar: L10n.s(.edHintHangar)
        case .custom: config.editorColors.isEmpty ? L10n.f(.edHintCustomSame, base) : L10n.f(.edHintCustom, config.editorColors.count, base)
        }
        return HStack(alignment: .top, spacing: Theme.cardRowGap) {
            Text(verbatim: text).foregroundStyle(Theme.ui.text2)
                .font(.system(size: Theme.fontSize.tab))
                .lineLimit(Theme.EditorSettings.hintLines, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if config.editorPalette == .custom, !config.editorColors.isEmpty {
                Button { ed.reset(nil) } label: { ActionLabel(title: L10n.s(.edResetAll), icon: .restore) }
                    .buttonStyle(HeaderActionStyle())
                    .font(.system(size: Theme.Control.font))
                    .fixedSize()
            }
        }
        .padding(.vertical, Theme.cardRowPaddingV)
        .padding(.horizontal, Theme.cardRowPaddingH)
        .sheetCard()
    }

    // MARK: Colors

    private func editorColors(_ ed: EditorSettingsModel) -> some View {
        CardSection(title: L10n.s(.edColors), card: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    EditorColorList(model: ed)
                } header: {
                    previewCard(ed)
                        .padding(.bottom, Theme.settingsHeaderGap)
                        .background(Theme.ui.sheet)
                }
            }
        }
    }

    private func previewCard(_ ed: EditorSettingsModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Segment(selection: ed.sample, options: EditorPreviewSample.allCases.map { ($0, $0.title) }) { ed.sample = $0 }
                    .font(.system(size: Theme.fontSize.segment))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.cardRowPaddingH)
            .frame(height: Theme.EditorSettings.headerHeight)
            Rectangle().fill(Theme.ui.lineSheet).frame(height: 1)
            EditorPreview(model: ed, options: options)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .sheetCard()
    }

    // MARK: Options

    private var editorFont: some View {
        CardSection(title: L10n.s(.edFontSection)) {
            row(L10n.s(.edFont), first: true) { FontPicker(family: options.fontFamily) { family in
                if let family { setOption("editor_font_family", family) { $0.fontFamily = family } }
                else { resetOption("editor_font_family") { $0.fontFamily = nil } }
            } }
            row(L10n.s(.edSize)) {
                SettingsStepper(value: L10n.f(.edPt, options.fontSize),
                                canDown: options.fontSize > EditorOptions.fontSizes.lowerBound,
                                canUp: options.fontSize < EditorOptions.fontSizes.upperBound) { step in
                    let size = options.fontSize + step
                    setOption("editor_font_size", String(size)) { $0.fontSize = size }
                }
            }
            row(L10n.s(.edLineHeight)) {
                let auto = options.lineHeight == 0
                SettingsStepper(value: auto ? L10n.f(.edLineAuto, options.resolvedLineHeight) : L10n.f(.edPt, options.lineHeight),
                                canDown: options.resolvedLineHeight > EditorOptions.lineHeights.lowerBound,
                                canUp: options.resolvedLineHeight < EditorOptions.lineHeights.upperBound) { step in
                    let height = options.resolvedLineHeight + step
                    setOption("editor_line_height", String(height)) { $0.lineHeight = height }
                }
                .help(L10n.s(.edLineHeightTip))
                if !auto {
                    Button(L10n.s(.edAuto)) { resetOption("editor_line_height") { $0.lineHeight = 0 } }
                        .buttonStyle(HeaderActionStyle())
                        .font(.system(size: Theme.Control.font))
                        .fixedSize()
                        .help(L10n.s(.edLineHeightTip))
                }
            }
            row(L10n.s(.edLigatures)) {
                CardSwitch(on: options.ligatures) { on in setOption("editor_ligatures", flag: on) { $0.ligatures = on } }
                    .help(L10n.s(.edLigaturesTip))
            }
        }
    }

    private var editorIndent: some View {
        CardSection(title: L10n.s(.edIndentSection)) {
            row(L10n.s(.edTabSize), first: true) {
                Segment(selection: options.tabSize, options: [(2, "2"), (4, "4"), (8, "8")]) { n in
                    setOption("editor_tab_size", String(n)) { $0.tabSize = n }
                }
            }
            row(L10n.s(.edDetect)) {
                CardSwitch(on: options.detectIndentation) { on in setOption("editor_detect_indentation", flag: on) { $0.detectIndentation = on } }
                    .help(L10n.s(.edDetectTip))
            }
            row(L10n.s(.edWrap)) {
                Segment(selection: options.wordWrap, options: [(false, L10n.s(.edWrapOff)), (true, L10n.s(.edWrapOn))]) { on in
                    setOption("editor_word_wrap", on ? "on" : "off") { $0.wordWrap = on }
                }
            }
        }
    }

    private var editorView: some View {
        CardSection(title: L10n.s(.edViewSection)) {
            row(L10n.s(.edLineHighlight), first: true) {
                PickMenu(selection: options.lineHighlight, options: [(.none, L10n.s(.edLhNone)), (.gutter, L10n.s(.edLhGutter)),
                                                                     (.line, L10n.s(.edLhLine)), (.all, L10n.s(.edLhAll))]) { v in
                    setOption("editor_line_highlight", v.rawValue) { $0.lineHighlight = v }
                }
            }
            row(L10n.s(.edCursor)) {
                PickMenu(selection: options.cursorStyle, options: [(.line, L10n.s(.edCursorLine)), (.block, L10n.s(.edCursorBlock)),
                                                                   (.underline, L10n.s(.edCursorUnderline))]) { v in
                    setOption("editor_cursor_style", v.rawValue) { $0.cursorStyle = v }
                }
            }
            row(L10n.s(.edBlink)) {
                PickMenu(selection: options.cursorBlinking, options: [(.blink, L10n.s(.edBlinkBlink)), (.smooth, L10n.s(.edBlinkSmooth)),
                                                                      (.solid, L10n.s(.edBlinkSolid))]) { v in
                    setOption("editor_cursor_blinking", v.rawValue) { $0.cursorBlinking = v }
                }
            }
            row(L10n.s(.edWhitespace)) {
                PickMenu(selection: options.whitespace, options: [(.none, L10n.s(.edWsNone)), (.selection, L10n.s(.edWsSelection)),
                                                                  (.all, L10n.s(.edWsAll))]) { v in
                    setOption("editor_whitespace", v.rawValue) { $0.whitespace = v }
                }
            }
            row(L10n.s(.edBracketColors)) {
                CardSwitch(on: options.bracketColors) { on in setOption("editor_bracket_colors", flag: on) { $0.bracketColors = on } }
            }
            row(L10n.s(.edBracketGuides)) {
                PickMenu(selection: options.bracketGuides, options: [(.none, L10n.s(.edGuidesNone)), (.active, L10n.s(.edGuidesActive)),
                                                                     (.all, L10n.s(.edGuidesAll))]) { v in
                    setOption("editor_bracket_guides", v.rawValue) { $0.bracketGuides = v }
                }
            }
            row(L10n.s(.edIndentGuides)) {
                CardSwitch(on: options.indentGuides) { on in setOption("editor_indent_guides", flag: on) { $0.indentGuides = on } }
            }
            row(L10n.editorRainbowTitle) {
                CardSwitch(on: app.config.editorRainbowIndent) { on in
                    save { try app.setEditorAppearance("editor_rainbow_indent", flag: on) { $0.editorRainbowIndent = on } }
                }
            }
            row(L10n.editorTodoTitle) {
                CardSwitch(on: app.config.editorTodoHighlight) { on in
                    save { try app.setEditorAppearance("editor_todo_highlight", flag: on) { $0.editorTodoHighlight = on } }
                }
            }
        }
    }

    private func setOption(_ key: String, _ value: String, apply: @escaping (inout EditorOptions) -> Void) {
        save { try app.setEditorAppearance(key, value) { apply(&$0.editorOptions) } }
    }

    private func setOption(_ key: String, flag: Bool, apply: @escaping (inout EditorOptions) -> Void) {
        save { try app.setEditorAppearance(key, flag: flag) { apply(&$0.editorOptions) } }
    }

    private func resetOption(_ key: String, apply: @escaping (inout EditorOptions) -> Void) {
        save { try app.resetEditorOption(key) { apply(&$0.editorOptions) } }
    }
}

// MARK: - Parts

/// A theme tile: a few lines of code in the theme's colors over its name; the chosen one is outlined in `accent`.
private struct EditorThemeTile: View {
    let name: String
    let theme: EditorTheme
    let selected: Bool
    let choose: () -> Void
    @State private var hover = false

    private typealias S = Theme.EditorSettings
    private static let code: [[(String, EditorColor)]] = [
        [("// session.ts", .comment)],
        [("export", .control), (" ", .text), ("function", .keyword), (" ", .text), ("load", .function), ("()", .bracket1),
         (" ", .text), ("{", .bracket1)],
        [("  ", .text), ("const", .keyword), (" ", .text), ("MAX", .constant), (" ", .text), ("=", .operator), (" ", .text),
         ("12", .number), (";", .punctuation)],
        [("  ", .text), ("return", .control), (" ", .text), ("\"utf8\"", .string), (";", .punctuation)],
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.themeTileRadius)
        Button { if !selected { choose() } } label: {
            VStack(alignment: .leading, spacing: Theme.settingsHeaderGap) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.code.indices, id: \.self) { i in
                        Self.code[i].reduce(Text(verbatim: "")) { text, part in
                            text + Text(verbatim: part.0).foregroundStyle(Theme.ui.editor(theme.hex(part.1)))
                                .italic(part.1 == .comment && theme.italicComments)
                        }
                        .frame(height: S.tileLineHeight)
                    }
                }
                .font(.system(size: S.tileFont, design: .monospaced))
                .lineLimit(1)
                .padding(S.tilePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ui.editor(theme.hex(.background)))
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? Theme.ui.accent : hover ? Theme.ui.controlBorderStrong : Theme.ui.control,
                                            lineWidth: selected ? Theme.themeTileBorder : 1))
                Text(verbatim: name).lineLimit(1)
                    .foregroundStyle(selected ? Theme.ui.textStrong : Theme.ui.text2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand(!selected)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The color list: «Синтаксис», «Редактор», «Diff», each folding; a row is a swatch, its name and the hex (a changed
/// one has a dot, and «Сбросить» under the pointer). Hover lights its tokens in the preview, a click opens the popover.
private struct EditorColorList: View {
    @Bindable var model: EditorSettingsModel
    private typealias S = Theme.EditorSettings

    private static let editorRows: [EditorColor] = [.background, .line, .selection, .find, .gutter, .gutterActive, .cursor, .indent,
                                                   .indentActive, .whitespace, .bracket1]

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            ForEach(EditorColorSection.allCases, id: \.self) { section in
                header(section, first: section == .syntax)
                if model.expanded.contains(section) {
                    ForEach(rows(section), id: \.self) { color in row(color, theme: theme) }
                }
            }
        }
        .padding(.bottom, Theme.pickPaddingV)
        .sheetCard()
    }

    private func rows(_ section: EditorColorSection) -> [EditorColor] {
        section == .editor ? Self.editorRows : EditorColor.allCases.filter { $0.section == section }
    }

    private func title(_ section: EditorColorSection) -> String {
        switch section {
        case .syntax: L10n.s(.edSyntax)
        case .editor: L10n.s(.editor)
        case .diff: "Diff"
        }
    }

    private func header(_ section: EditorColorSection, first: Bool) -> some View {
        let open = model.expanded.contains(section)
        return Button {
            withAnimation(Motion.ease(Theme.selectionFade)) {
                if open { model.expanded.remove(section) } else { model.expanded.insert(section) }
            }
        } label: {
            HStack(spacing: Theme.pickGap) {
                IconView(icon: open ? .chevronDown : .chevronRight, size: Theme.pickChevronSize, tint: Theme.ui.text3)
                Text(verbatim: title(section)).font(.system(size: Theme.fontSize.tab, weight: .semibold)).foregroundStyle(Theme.ui.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.cardRowPaddingH)
            .frame(height: S.groupHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.lineSheet).frame(height: 1).opacity(first ? 0 : 1) }
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    private func row(_ color: EditorColor, theme: EditorTheme) -> some View {
        let brackets = color == .bracket1
        let group: [EditorColor] = brackets ? [.bracket1, .bracket2, .bracket3] : [color]
        let changed = group.filter { theme.changed.contains($0) }
        let hovered = model.hovered == color
        return HStack(spacing: Theme.pickGap) {
            Circle().fill(Theme.ui.accentText).frame(width: S.modifiedDot, height: S.modifiedDot)
                .opacity(changed.isEmpty ? 0 : 1)
                .frame(width: S.dotSlot)
            HStack(spacing: S.swatchGap) {
                ForEach(group, id: \.self) { c in
                    EditorSwatch(hex: theme.hex(c))
                        .contentShape(Rectangle())
                        .onTapGesture { model.open(c, anchor: "row-\(c.rawValue)") }
                        .popover(isPresented: presented("row-\(c.rawValue)"), arrowEdge: .leading) { EditorColorPopover(model: model) }
                        .help(brackets ? c.title : "")
                }
            }
            Text(verbatim: brackets ? L10n.s(.edcBrackets) : color.title).foregroundStyle(Theme.ui.text).lineLimit(1)
            Spacer(minLength: Theme.cardRowGap)
            if hovered, !changed.isEmpty {
                RowActionButton(icon: .restore, help: L10n.f(.edResetTo, EditorSettingsModel.name(theme.base))) {
                    for c in changed { model.reset(c) }
                }
            } else if !brackets {
                Text(verbatim: theme.hex(color)).font(.system(size: S.hexFont, design: .monospaced)).foregroundStyle(Theme.ui.text3)
                    .fixedSize()
            }
        }
        .padding(.trailing, Theme.cardRowPaddingH)
        .frame(height: S.rowHeight)
        .background(hovered ? Theme.ui.hover : .clear)
        .contentShape(Rectangle())
        .onHover { h in
            if h { model.hover(color) } else if model.hovered == color { model.hover(nil) }
        }
        .onTapGesture { model.open(color, anchor: "row-\(color.rawValue)") }
        .pointingHand()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func presented(_ anchor: String) -> Binding<Bool> {
        Binding(get: { model.editing != nil && model.anchor == anchor }, set: { if !$0, model.anchor == anchor { model.close() } })
    }
}

/// `− value +` for the font size and line height.
private struct SettingsStepper: View {
    let value: String
    let canDown: Bool
    let canUp: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button("−") { step(-1) }.buttonStyle(HeaderActionStyle()).disabled(!canDown).help(L10n.s(.edSmaller))
            Text(verbatim: value).font(.system(size: Theme.fontSize.tab, design: .monospaced)).foregroundStyle(Theme.ui.text)
                .frame(minWidth: Theme.EditorSettings.stepperValueWidth)
            Button("+") { step(1) }.buttonStyle(HeaderActionStyle()).disabled(!canUp).help(L10n.s(.edLarger))
        }
        .font(.system(size: Theme.fontSize.sheetRow))
        .padding(Theme.segmentPadding)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: Theme.segmentRadius).fill(Theme.ui.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.segmentRadius).stroke(Theme.ui.control, lineWidth: 1))
    }
}

/// A drop-down for choices too wide for a segment at the window's minimum width: the value in a field with ▾, the
/// options in Hangar's menu.
struct PickMenu<Value: Equatable>: View {
    let selection: Value
    let options: [(Value, String)]
    let choose: (Value) -> Void
    @State private var anchor = MenuAnchor()

    var body: some View {
        PickField(title: options.first { $0.0 == selection }?.1 ?? "") {
            PopoverMenu.show(options.map { value, title in
                .item(PopoverMenuItem(title: title, icon: value == selection ? .check : nil) { if value != selection { choose(value) } })
            }, below: anchor.view)
        }
        .background(MenuAnchorView(anchor: anchor))
    }
}

/// The font: SF Mono (system) and the installed monospaced families, in a native menu (it scrolls when there are many).
private struct FontPicker: View {
    let family: String?
    let choose: (String?) -> Void
    @State private var anchor = MenuAnchor()

    var body: some View {
        PickField(title: family ?? L10n.s(.edSystemFont)) {
            guard let view = anchor.view else { return }
            let menu = NSMenu()
            let target = FontMenuTarget(choose)
            FontMenuTarget.shown = target  // menu items hold their target weakly
            for (title, value) in [(L10n.s(.edSystemFont), nil as String?)] + Self.families().map({ ($0, $0 as String?) }) {
                let item = NSMenuItem(title: title, action: #selector(FontMenuTarget.pick(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = value
                item.state = value == family ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
        .background(MenuAnchorView(anchor: anchor))
    }

    /// Fixed-pitch families a CSS font list can name as is (hidden `.`-families left out).
    static func families() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") && HangarConfig.isValidFontFamily($0) }.sorted()
    }
}

private final class FontMenuTarget: NSObject {
    @MainActor static var shown: FontMenuTarget?
    let choose: (String?) -> Void
    init(_ choose: @escaping (String?) -> Void) { self.choose = choose }
    @objc func pick(_ item: NSMenuItem) { choose(item.representedObject as? String) }
}

/// The drop-down's face (the branch picker's field): the value and ▾.
private struct PickField: View {
    let title: String
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.pickGap) {
                Text(verbatim: title)
                    .font(.system(size: Theme.fontSize.tab))
                    .foregroundStyle(Theme.ui.sheetText)
                    .lineLimit(1)
                IconView(icon: .chevronDown, size: Theme.pickChevronSize, tint: Theme.ui.text2)
            }
            .padding(.vertical, Theme.pickPaddingV)
            .padding(.horizontal, Theme.pickPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.pickRadius).fill(Theme.ui.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.pickRadius)
                .stroke(hover ? Theme.ui.accent : Theme.ui.controlBorderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .pointingHand()
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
    }
}
