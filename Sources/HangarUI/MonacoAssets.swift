import AppKit
import WebKit
import Workspace

extension Theme {
    /// The Monaco editor and diff (#80): code font and the page's own chrome (bars, buttons).
    enum Editor {
        static let fontSize: CGFloat = 13
        static let lineHeight: CGFloat = 20
        /// The diff's header row: as tall as the tab bar above it.
        static let headerHeight: CGFloat = Theme.tabBarHeight
        static let buttonFont: CGFloat = Theme.fontSize.tab
        /// The conflict / notice bar above the text.
        static let barHeight: CGFloat = 30
        static let barFont: CGFloat = Theme.fontSize.base
        static let radius: CGFloat = 6
    }
}

/// `#rrggbb` (+ `aa`) of a Theme color, for the page.
func cssHex(_ color: NSColor, alpha: Double? = nil) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    func h(_ v: CGFloat) -> String { String(format: "%02x", Int((v * 255).rounded())) }
    return "#" + h(c.redComponent) + h(c.greenComponent) + h(c.blueComponent) + (alpha.map { h(CGFloat($0)) } ?? "")
}

/// Hangar's Monaco theme: the app theme's editor chrome (themes-v1.html: background, gutter, current line, selection,
/// indent guides, diff tints) with the chosen syntax palette (#84) — VS Code Dark+ (default, the same in every app theme)
/// or the diff's muted colors. Rules cover Monarch tokens and tsserver's semantic types (class, function, variable …).
enum MonacoTheme {
    static func json(_ palette: HangarConfig.EditorPalette, theme p: ThemePalette = Theme.palette) -> [String: Any] {
        ["base": "vs-dark", "inherit": true, "rules": rules(palette, p), "colors": colors(p)]
    }

    /// Both syntax palettes in the current app theme; the page redefines them when the app theme changes.
    static func all(_ p: ThemePalette = Theme.palette) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: HangarConfig.EditorPalette.allCases.map { ($0.rawValue, json($0, theme: p)) })
    }

    /// `#rrggbb`, plus `aa` for `alpha` or a translucent token.
    private static func h(_ x: Hex, alpha: Double? = nil) -> String {
        "#" + x.bare + ((alpha ?? (x.alpha < 1 ? x.alpha : nil)).map { String(format: "%02x", Int(($0 * 255).rounded())) } ?? "")
    }

    private static func rules(_ palette: HangarConfig.EditorPalette, _ p: ThemePalette) -> [[String: String]] {
        let token: [(String, String)]
        switch palette {
        case .darkPlus:
            let keyword = "569CD6", control = "C586C0", variable = "9CDCFE", type = "4EC9B0", function = "DCDCAA"
            token = [
                ("keyword", keyword), ("keyword.control", control), ("identifier", variable), ("type.identifier", type),
                ("type", type), ("class", type), ("interface", type), ("enum", type), ("namespace", type), ("typeParameter", type),
                ("variable", variable), ("parameter", variable), ("property", variable), ("enumMember", "4FC1FF"),
                ("function", function), ("member", function), ("string", "CE9178"), ("string.escape", "D7BA7D"),
                ("regexp", "D16969"), ("number", "B5CEA8"), ("comment", "6A9955"), ("comment.doc", "6A9955"),
                ("constant", "4FC1FF"), ("delimiter", "D4D4D4"), ("delimiter.bracket", "D4D4D4"), ("operator", "D4D4D4"),
                ("tag", keyword), ("metatag", keyword), ("attribute.name", variable), ("attribute.value", "CE9178"),
                ("string.key.json", variable), ("annotation", type), ("predefined", function), ("", "D4D4D4"),
            ]
        case .hangar:
            func hex(_ kind: SyntaxKind) -> String { String(format: "%06x", Theme.Diff.syntaxHex(kind)) }
            let pairs: [(String, SyntaxKind)] = [
                ("keyword", .keyword), ("keyword.control", .keyword), ("tag", .keyword), ("metatag", .keyword), ("string", .string),
                ("string.key.json", .type), ("attribute.value", .string), ("regexp", .string), ("comment", .comment),
                ("comment.doc", .comment), ("number", .number), ("constant", .number), ("enumMember", .number), ("type", .type),
                ("type.identifier", .type), ("class", .type), ("interface", .type), ("enum", .type), ("namespace", .type),
                ("typeParameter", .type), ("attribute.name", .type), ("annotation", .type), ("predefined", .type),
            ]
            token = pairs.map { ($0.0, hex($0.1)) } + [("", p.tx.bare)]
        }
        var rules = token.map { ["token": $0.0, "foreground": $0.1] }
        if palette == .hangar { rules[rules.firstIndex { $0["token"] == "comment" }!]["fontStyle"] = "italic" }
        return rules
    }

    private static func colors(_ p: ThemePalette) -> [String: String] {
        // Bracket pairs as in VS Code: gold, orchid, blue by depth.
        let brackets = ["#FFD700", "#DA70D6", "#179FFF"]
        return [
            "editor.background": h(p.editorBg), "editor.foreground": h(p.tx),
            "editorLineNumber.foreground": h(p.edGutter), "editorLineNumber.activeForeground": h(p.edGutterActive),
            "editorCursor.foreground": h(p.accent), "editor.selectionBackground": h(p.edSel),
            "editor.inactiveSelectionBackground": h(p.edSel, alpha: 0.6),
            "editor.lineHighlightBackground": h(p.edLine), "editor.lineHighlightBorder": h(p.edLine),
            "editor.wordHighlightBackground": h(p.selected, alpha: 0.7),
            "editor.findMatchBackground": h(p.waiting, alpha: 0.35),
            "editor.findMatchHighlightBackground": h(p.waiting, alpha: 0.18),
            "editorBracketMatch.background": h(p.selected), "editorBracketMatch.border": h(p.controlStrong),
            "editorIndentGuide.background1": h(p.edIndent), "editorIndentGuide.activeBackground1": h(p.controlStrong),
            "editorWhitespace.foreground": h(p.control), "editorGutter.background": h(p.editorBg),
            "editorWidget.background": h(p.sheet), "editorWidget.border": h(p.winBorder),
            "editorWidget.foreground": h(p.tx), "widget.shadow": "#00000066",
            "input.background": h(p.field), "input.border": h(p.controlStrong),
            "input.foreground": h(p.tx), "input.placeholderForeground": h(p.tx3),
            "inputOption.activeBorder": h(p.accent), "inputOption.activeBackground": h(p.accent, alpha: 0.2),
            "focusBorder": h(p.accent, alpha: 0.6),
            "editorSuggestWidget.background": h(p.sheet), "editorSuggestWidget.border": h(p.winBorder),
            "editorSuggestWidget.selectedBackground": h(p.selected), "editorSuggestWidget.highlightForeground": h(p.accent),
            "editorHoverWidget.background": h(p.sheet), "editorHoverWidget.border": h(p.winBorder),
            "list.hoverBackground": h(p.sbHover), "list.activeSelectionBackground": h(p.selected),
            "list.focusBackground": h(p.selected), "list.highlightForeground": h(p.accent),
            "menu.background": h(p.sheet), "menu.foreground": h(p.tx), "menu.border": h(p.winBorder),
            "menu.selectionBackground": h(p.selected), "menu.selectionForeground": h(p.strong),
            "menu.separatorBackground": h(p.lineSheet),
            "scrollbar.shadow": "#00000000", "scrollbarSlider.background": h(p.control, alpha: 0.6),
            "scrollbarSlider.hoverBackground": h(p.controlStrong, alpha: 0.8),
            "scrollbarSlider.activeBackground": h(p.controlStrong),
            "minimap.background": h(p.editorBg), "editorOverviewRuler.border": "#00000000",
            "editorError.foreground": h(p.failed), "editorWarning.foreground": h(p.waiting),
            "editorInfo.foreground": h(p.accent),
            // Changed chars: a light step over the row tint, not a saturated slab.
            "diffEditor.insertedTextBackground": h(p.gitA, alpha: 0.12), "diffEditor.removedTextBackground": h(p.gitD, alpha: 0.12),
            "diffEditor.insertedLineBackground": h(p.diffAdd), "diffEditor.removedLineBackground": h(p.diffDel),
            "diffEditorGutter.insertedLineBackground": h(p.diffAdd), "diffEditorGutter.removedLineBackground": h(p.diffDel),
            "diffEditor.diagonalFill": h(p.line), "diffEditor.border": h(p.line),
            "diffEditor.unchangedRegionBackground": h(p.bottomBar),
            "diffEditor.unchangedRegionForeground": h(p.tx2),
            "peekView.border": h(p.winBorder), "peekViewEditor.background": h(p.editorBg),
            "peekViewResult.background": h(p.sheet), "peekViewTitle.background": h(p.sheet),
            "peekViewTitleLabel.foreground": h(p.strong), "peekViewTitleDescription.foreground": h(p.tx3),
            "peekViewResult.fileForeground": h(p.tx), "peekViewResult.lineForeground": h(p.tx2),
            "peekViewResult.selectionBackground": h(p.selected), "peekViewResult.selectionForeground": h(p.strong),
            "peekViewResult.matchHighlightBackground": h(p.waiting, alpha: 0.25),
            "peekViewEditor.matchHighlightBackground": h(p.waiting, alpha: 0.25),
            "peekViewEditorGutter.background": h(p.editorBg),
            "editorStickyScroll.background": h(p.editorBg), "editorStickyScrollHover.background": h(p.hover),
            "editorBracketHighlight.foreground1": brackets[0], "editorBracketHighlight.foreground2": brackets[1],
            "editorBracketHighlight.foreground3": brackets[2], "editorBracketHighlight.unexpectedBracket.foreground": h(p.failed),
            "editorBracketPairGuide.activeBackground1": brackets[0] + "80", "editorBracketPairGuide.activeBackground2": brackets[1] + "80",
            "editorBracketPairGuide.activeBackground3": brackets[2] + "80",
        ]
    }

    /// CSS variables of the page's own chrome (file tabs, bars, the diff header's toggle).
    static func css(_ p: ThemePalette = Theme.palette) -> [String: String] {
        let e = Theme.Editor.self
        return [
            "--bg": h(p.editorBg), "--line": h(p.line), "--text": h(p.tx),
            "--text-strong": h(p.strong), "--text2": h(p.tx2), "--text3": h(p.tx3),
            "--accent": h(p.accent), "--primary": h(p.primary), "--primary-text": h(p.primaryText),
            "--waiting": h(p.waiting), "--button": h(p.button), "--button-hover": h(p.controlStrong),
            "--sheet": h(p.sheet),
            "--button-font": "\(e.buttonFont)px", "--bar-h": "\(e.barHeight)px", "--bar-font": "\(e.barFont)px",
            "--radius": "\(e.radius)px",
            "--menu-w": "\(Theme.menuWidth)px", "--menu-r": "\(Theme.menuRadius)px", "--menu-pad": "\(Theme.menuPadding)px",
            "--menu-item-h": "\(Theme.menuItemHeight)px", "--menu-item-pl": "\(Theme.menuItemPaddingLeading)px",
            "--menu-item-pr": "\(Theme.menuItemPaddingTrailing)px", "--menu-item-r": "\(Theme.menuItemRadius)px",
            "--menu-font": "\(Theme.menuFont)px", "--menu-key-font": "\(Theme.menuShortcutFont)px",
            "--menu-sep-v": "\(Theme.menuSeparatorPaddingV)px", "--menu-sep-h": "\(Theme.menuSeparatorPaddingH)px",
            "--menu-hover": h(p.menuHover), "--menu-hover-text": h(p.menuHoverText), "--menu-border": h(p.controlStrong),
            "--line-sheet": h(p.lineSheet), "--inactive": "\(Theme.inactiveOpacity)",
        ]
    }
}

// MARK: The bundled files

let monacoScheme = "hangar-editor"

/// The bundled file for a `hangar-editor://app/…` URL; nil for anything else or anything outside `root`.
func monacoResourcePath(_ url: URL, root: String) -> String? {
    guard url.scheme == monacoScheme, url.host == "app" else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") }) else { return nil }
    let path = (root + "/" + parts.joined(separator: "/") as NSString).standardizingPath
    return path.hasPrefix(root + "/") ? path : nil
}

func monacoMimeType(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "js": "text/javascript"
    case "css": "text/css"
    case "html": "text/html"
    case "json": "application/json"
    case "ttf": "font/ttf"
    case "svg": "image/svg+xml"
    default: "application/octet-stream"
    }
}

/// Serves Monaco and the page from the app bundle (no file:// access, nothing from the network).
final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let root: String? = L10n.resources?.url(forResource: "Monaco", withExtension: nil)?.standardizedFileURL.path

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root = Self.root, let path = monacoResourcePath(url, root: root),
              let data = FileManager.default.contents(atPath: path) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = ["Content-Type": monacoMimeType(path), "Content-Length": "\(data.count)"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
