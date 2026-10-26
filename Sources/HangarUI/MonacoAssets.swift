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

/// Hangar's Monaco theme: the navy chrome with the chosen syntax palette (#84) — VS Code Dark+ (default) or the diff's
/// muted colors. Rules cover Monarch tokens and tsserver's semantic types (class, function, variable …).
enum MonacoTheme {
    static func json(_ palette: HangarConfig.EditorPalette) -> [String: Any] {
        ["base": "vs-dark", "inherit": true, "rules": rules(palette), "colors": colors]
    }

    /// Both themes for the page; it switches between them when the setting changes.
    static var all: [String: Any] {
        Dictionary(uniqueKeysWithValues: HangarConfig.EditorPalette.allCases.map { ($0.rawValue, json($0)) })
    }

    private static func rules(_ palette: HangarConfig.EditorPalette) -> [[String: String]] {
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
            token = pairs.map { ($0.0, hex($0.1)) } + [("", String(cssHex(Theme.text).dropFirst()))]
        }
        var rules = token.map { ["token": $0.0, "foreground": $0.1] }
        if palette == .hangar { rules[rules.firstIndex { $0["token"] == "comment" }!]["fontStyle"] = "italic" }
        return rules
    }

    private static var colors: [String: String] {
        let add = "#98c379", del = "#e06c75"
        // Bracket pairs as in VS Code: gold, orchid, blue by depth.
        let brackets = ["#FFD700", "#DA70D6", "#179FFF"]
        return [
            "editor.background": cssHex(Theme.panel), "editor.foreground": cssHex(Theme.text),
            "editorLineNumber.foreground": cssHex(Theme.text3), "editorLineNumber.activeForeground": cssHex(Theme.text2),
            "editorCursor.foreground": cssHex(Theme.accent), "editor.selectionBackground": cssHex(Theme.selection),
            "editor.inactiveSelectionBackground": cssHex(Theme.selection, alpha: 0.6),
            "editor.lineHighlightBackground": cssHex(Theme.hover), "editor.lineHighlightBorder": cssHex(Theme.hover),
            "editor.wordHighlightBackground": cssHex(Theme.selection, alpha: 0.7),
            "editor.findMatchBackground": cssHex(Theme.waiting, alpha: 0.35),
            "editor.findMatchHighlightBackground": cssHex(Theme.waiting, alpha: 0.18),
            "editorBracketMatch.background": cssHex(Theme.selection), "editorBracketMatch.border": cssHex(Theme.controlBorderStrong),
            "editorIndentGuide.background1": cssHex(Theme.line), "editorIndentGuide.activeBackground1": cssHex(Theme.control),
            "editorWhitespace.foreground": cssHex(Theme.control), "editorGutter.background": cssHex(Theme.panel),
            "editorWidget.background": cssHex(Theme.sheet), "editorWidget.border": cssHex(Theme.sheetBorder),
            "editorWidget.foreground": cssHex(Theme.text), "widget.shadow": "#00000066",
            "input.background": cssHex(Theme.field), "input.border": cssHex(Theme.controlBorderStrong),
            "input.foreground": cssHex(Theme.text), "input.placeholderForeground": cssHex(Theme.text3),
            "inputOption.activeBorder": cssHex(Theme.accent), "inputOption.activeBackground": cssHex(Theme.accent, alpha: 0.2),
            "focusBorder": cssHex(Theme.accent, alpha: 0.6),
            "editorSuggestWidget.background": cssHex(Theme.sheet), "editorSuggestWidget.border": cssHex(Theme.sheetBorder),
            "editorSuggestWidget.selectedBackground": cssHex(Theme.selection), "editorSuggestWidget.highlightForeground": cssHex(Theme.accent),
            "editorHoverWidget.background": cssHex(Theme.sheet), "editorHoverWidget.border": cssHex(Theme.sheetBorder),
            "list.hoverBackground": cssHex(Theme.sidebarHover), "list.activeSelectionBackground": cssHex(Theme.selection),
            "list.focusBackground": cssHex(Theme.selection), "list.highlightForeground": cssHex(Theme.accent),
            "menu.background": cssHex(Theme.sheet), "menu.foreground": cssHex(Theme.text), "menu.border": cssHex(Theme.sheetBorder),
            "menu.selectionBackground": cssHex(Theme.selection), "menu.selectionForeground": cssHex(Theme.selectionText),
            "menu.separatorBackground": cssHex(Theme.lineSheet),
            "scrollbar.shadow": "#00000000", "scrollbarSlider.background": cssHex(Theme.control, alpha: 0.6),
            "scrollbarSlider.hoverBackground": cssHex(Theme.controlBorderStrong, alpha: 0.8),
            "scrollbarSlider.activeBackground": cssHex(Theme.controlBorderStrong),
            "minimap.background": cssHex(Theme.panel), "editorOverviewRuler.border": "#00000000",
            "editorError.foreground": cssHex(Theme.failed), "editorWarning.foreground": cssHex(Theme.waiting),
            "editorInfo.foreground": cssHex(Theme.accent),
            "diffEditor.insertedTextBackground": add + "33", "diffEditor.removedTextBackground": del + "33",
            "diffEditor.insertedLineBackground": add + "1f", "diffEditor.removedLineBackground": del + "1f",
            "diffEditorGutter.insertedLineBackground": add + "26", "diffEditorGutter.removedLineBackground": del + "26",
            "diffEditor.diagonalFill": cssHex(Theme.line), "diffEditor.border": cssHex(Theme.line),
            "diffEditor.unchangedRegionBackground": cssHex(Theme.bottomBar),
            "diffEditor.unchangedRegionForeground": cssHex(Theme.text2),
            "peekView.border": cssHex(Theme.sheetBorder), "peekViewEditor.background": cssHex(Theme.panel),
            "peekViewResult.background": cssHex(Theme.sheet), "peekViewTitle.background": cssHex(Theme.sheet),
            "peekViewTitleLabel.foreground": cssHex(Theme.textStrong), "peekViewTitleDescription.foreground": cssHex(Theme.text3),
            "peekViewResult.fileForeground": cssHex(Theme.text), "peekViewResult.lineForeground": cssHex(Theme.text2),
            "peekViewResult.selectionBackground": cssHex(Theme.selection), "peekViewResult.selectionForeground": cssHex(Theme.textStrong),
            "peekViewResult.matchHighlightBackground": cssHex(Theme.waiting, alpha: 0.25),
            "peekViewEditor.matchHighlightBackground": cssHex(Theme.waiting, alpha: 0.25),
            "peekViewEditorGutter.background": cssHex(Theme.panel),
            "editorStickyScroll.background": cssHex(Theme.panel), "editorStickyScrollHover.background": cssHex(Theme.hover),
            "editorBracketHighlight.foreground1": brackets[0], "editorBracketHighlight.foreground2": brackets[1],
            "editorBracketHighlight.foreground3": brackets[2], "editorBracketHighlight.unexpectedBracket.foreground": cssHex(Theme.failed),
            "editorBracketPairGuide.activeBackground1": brackets[0] + "80", "editorBracketPairGuide.activeBackground2": brackets[1] + "80",
            "editorBracketPairGuide.activeBackground3": brackets[2] + "80",
        ]
    }

    /// CSS variables of the page's own chrome (file tabs, bars, the diff header's toggle).
    static var css: [String: String] {
        let e = Theme.Editor.self
        return [
            "--bg": cssHex(Theme.panel), "--line": cssHex(Theme.line), "--text": cssHex(Theme.text),
            "--text-strong": cssHex(Theme.textStrong), "--text2": cssHex(Theme.text2), "--text3": cssHex(Theme.text3),
            "--accent": cssHex(Theme.accent),
            "--waiting": cssHex(Theme.waiting), "--button": cssHex(Theme.button), "--button-hover": cssHex(Theme.controlBorderStrong),
            "--sheet": cssHex(Theme.sheet),
            "--button-font": "\(e.buttonFont)px", "--bar-h": "\(e.barHeight)px", "--bar-font": "\(e.barFont)px",
            "--radius": "\(e.radius)px",
            "--menu-w": "\(Theme.menuWidth)px", "--menu-r": "\(Theme.menuRadius)px", "--menu-pad": "\(Theme.menuPadding)px",
            "--menu-item-h": "\(Theme.menuItemHeight)px", "--menu-item-pl": "\(Theme.menuItemPaddingLeading)px",
            "--menu-item-pr": "\(Theme.menuItemPaddingTrailing)px", "--menu-item-r": "\(Theme.menuItemRadius)px",
            "--menu-font": "\(Theme.menuFont)px", "--menu-key-font": "\(Theme.menuShortcutFont)px",
            "--menu-sep-v": "\(Theme.menuSeparatorPaddingV)px", "--menu-sep-h": "\(Theme.menuSeparatorPaddingH)px",
            "--menu-hover": cssHex(Theme.sidebarHover), "--menu-border": cssHex(Theme.controlBorderStrong),
            "--line-sheet": cssHex(Theme.lineSheet), "--inactive": "\(Theme.inactiveOpacity)",
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
