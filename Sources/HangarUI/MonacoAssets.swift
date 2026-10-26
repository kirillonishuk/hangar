import AppKit
import WebKit

extension Theme {
    /// The Monaco editor and diff (#80): code font and the page's own chrome (file tabs, bars).
    enum Editor {
        static let fontSize: CGFloat = 13
        static let lineHeight: CGFloat = 20
        /// File tabs: the Hangar tab bar's own metrics (#81), so the two rows read as one system.
        static let fileTabHeight: CGFloat = Theme.tabBarHeight
        static let fileTabFont: CGFloat = Theme.fontSize.tab
        static let fileTabPaddingH: CGFloat = Theme.tabPaddingH
        static let fileTabMaxWidth: CGFloat = Theme.tabMaxWidth
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

/// Hangar's Monaco theme: the navy palette and the diff's syntax colors, so the editor reads as part of the app.
enum MonacoTheme {
    static var json: [String: Any] {
        func hex(_ kind: SyntaxKind) -> String { String(format: "%06x", Theme.Diff.syntaxHex(kind)) }
        let token: [(String, SyntaxKind)] = [
            ("keyword", .keyword), ("tag", .keyword), ("metatag", .keyword), ("string", .string), ("string.key.json", .type),
            ("attribute.value", .string), ("regexp", .string), ("comment", .comment), ("comment.doc", .comment),
            ("number", .number), ("constant", .number), ("type", .type), ("type.identifier", .type),
            ("attribute.name", .type), ("annotation", .type), ("predefined", .type),
        ]
        var rules = token.map { ["token": $0.0, "foreground": hex($0.1)] }
        rules[rules.firstIndex { $0["token"] == "comment" }!]["fontStyle"] = "italic"
        rules.append(["token": "", "foreground": String(cssHex(Theme.text).dropFirst())])
        let add = "#98c379", del = "#e06c75"
        let colors: [String: String] = [
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
        ]
        return ["base": "vs-dark", "inherit": true, "rules": rules, "colors": colors]
    }

    /// CSS variables of the page's own chrome (file tabs, bars, the diff header's toggle).
    static var css: [String: String] {
        let e = Theme.Editor.self
        return [
            "--bg": cssHex(Theme.panel), "--bar": cssHex(Theme.bg), "--line": cssHex(Theme.line), "--text": cssHex(Theme.text),
            "--text-strong": cssHex(Theme.textStrong), "--text2": cssHex(Theme.text2), "--text3": cssHex(Theme.text3),
            "--hover": cssHex(Theme.hover), "--active": cssHex(Theme.activeSegment), "--accent": cssHex(Theme.accent),
            "--waiting": cssHex(Theme.waiting), "--button": cssHex(Theme.button), "--button-hover": cssHex(Theme.controlBorderStrong),
            "--sheet": cssHex(Theme.sheet), "--failed": cssHex(Theme.failed), "--done": cssHex(Theme.done),
            "--tab-h": "\(e.fileTabHeight)px", "--tab-font": "\(e.fileTabFont)px", "--tab-pad": "\(e.fileTabPaddingH)px",
            "--tab-max": "\(e.fileTabMaxWidth)px", "--bar-h": "\(e.barHeight)px", "--bar-font": "\(e.barFont)px",
            "--radius": "\(e.radius)px", "--accent-line": "\(Theme.tabActiveLine)px",
            "--tab-pad-v": "\(Theme.tabPaddingV)px", "--tab-gap": "\(Theme.tabGap)px", "--tab-lead": "\(Theme.tabTitleLeading)px",
            "--tab-radius": "\(Theme.tabRadius)px", "--selection": cssHex(Theme.selection),
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
