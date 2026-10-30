import AppKit
import WebKit
import Workspace

extension Theme {
    /// The Monaco editor and diff (#80): code font and the page's own chrome (bars, buttons).
    enum Editor {
        /// The diff's header row: as tall as the tab bar above it.
        static let headerHeight: CGFloat = Theme.tabBarHeight
        static let buttonFont: CGFloat = Theme.Typography.secondary.size
        /// The conflict / notice bar above the text.
        static let barHeight: CGFloat = 30
        static let barFont: CGFloat = Theme.Typography.body.size
        static let radius: CGFloat = 6
    }
}

/// `#rrggbb` (+ `aa`) of a Theme color, for the page.
func cssHex(_ color: NSColor, alpha: Double? = nil) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    func h(_ v: CGFloat) -> String { String(format: "%02x", Int((v * 255).rounded())) }
    return "#" + h(c.redComponent) + h(c.greenComponent) + h(c.blueComponent) + (alpha.map { h(CGFloat($0)) } ?? "")
}

/// Hangar's Monaco theme (#80, #84, #108): the editor theme's colors (syntax rules for Monarch tokens and tsserver's
/// semantic types, the editor's parts, diff tints) inside the app theme's chrome (widgets, menus, peek, scrollbars).
enum MonacoTheme {
    static func json(_ t: EditorTheme) -> [String: Any] {
        ["base": "vs-dark", "inherit": true, "rules": rules(t), "colors": colors(t)]
    }

    /// `#rrggbb`, plus `aa` for `alpha` or a translucent token.
    private static func h(_ x: Hex, alpha: Double? = nil) -> String { EditorHex.of(x, alpha: alpha) }

    private static func rules(_ t: EditorTheme) -> [[String: String]] {
        EditorColor.allCases.flatMap { color in
            color.tokens.map { token in
                var rule = ["token": token, "foreground": EditorHex.rgb(t.hex(color))]
                if color == .comment, t.italicComments { rule["fontStyle"] = "italic" }
                return rule
            }
        }
    }

    private static func colors(_ t: EditorTheme) -> [String: String] {
        let p = ThemePalette.of(t.app)
        let modern = t.base == .darkModern
        func c(_ color: EditorColor) -> String { t.hex(color) }
        // Derived from a changed color, so «Своя» stays consistent: half as strong as the color itself.
        func softer(_ color: EditorColor, _ own: String, _ factor: Double) -> String {
            t.changed.contains(color) ? EditorHex.with(c(color), alpha: EditorHex.alpha(c(color)) * factor) : own
        }
        let brackets = [c(.bracket1), c(.bracket2), c(.bracket3)]
        return [
            "editor.background": c(.background), "editor.foreground": c(.text), "editorGutter.background": c(.background),
            "minimap.background": c(.background), "peekViewEditor.background": c(.background),
            "peekViewEditorGutter.background": c(.background), "editorStickyScroll.background": c(.background),
            "editorLineNumber.foreground": c(.gutter), "editorLineNumber.activeForeground": c(.gutterActive),
            "editorCursor.foreground": c(.cursor), "editor.selectionBackground": c(.selection),
            "editor.inactiveSelectionBackground": softer(.selection, modern ? "#3a3d41" : h(p.edSel, alpha: 0.6), 0.6),
            // VS Code Dark Modern frames the current line; the others fill it.
            "editor.lineHighlightBackground": t.lineFilled ? c(.line) : "#00000000", "editor.lineHighlightBorder": c(.line),
            "editor.wordHighlightBackground": h(p.selected, alpha: 0.7),
            "editor.findMatchBackground": c(.find),
            "editor.findMatchHighlightBackground": softer(.find, modern ? "#ea5c0055" : h(p.waiting, alpha: 0.18), 0.5),
            "editorBracketMatch.background": modern ? "#0064001a" : h(p.selected),
            "editorBracketMatch.border": modern ? "#888888" : h(p.line2),
            "editorIndentGuide.background1": c(.indent), "editorIndentGuide.activeBackground1": c(.indentActive),
            "editorWhitespace.foreground": c(.whitespace),
            "editorWidget.background": h(p.bg2), "editorWidget.border": h(p.line2),
            "editorWidget.foreground": h(p.text1), "widget.shadow": "#00000066",
            "input.background": h(p.field), "input.border": h(p.line2),
            "input.foreground": h(p.text1), "input.placeholderForeground": h(p.text3),
            "inputOption.activeBorder": h(p.accent), "inputOption.activeBackground": h(p.accent, alpha: 0.2),
            "focusBorder": h(p.accent, alpha: 0.6),
            "editorSuggestWidget.background": h(p.bg2), "editorSuggestWidget.border": h(p.line2),
            "editorSuggestWidget.selectedBackground": h(p.selected), "editorSuggestWidget.highlightForeground": h(p.accentText),
            "editorHoverWidget.background": h(p.bg2), "editorHoverWidget.border": h(p.line2),
            "list.hoverBackground": h(p.hover), "list.activeSelectionBackground": h(p.selected),
            "list.focusBackground": h(p.selected), "list.highlightForeground": h(p.accentText),
            "menu.background": h(p.bg2), "menu.foreground": h(p.text1), "menu.border": h(p.line2),
            "menu.selectionBackground": h(p.selectedFocus), "menu.selectionForeground": h(p.onAccent),
            "menu.separatorBackground": h(p.line2),
            "scrollbar.shadow": "#00000000", "scrollbarSlider.background": h(p.line2, alpha: 0.6),
            "scrollbarSlider.hoverBackground": h(p.line2, alpha: 0.8),
            "scrollbarSlider.activeBackground": h(p.line2),
            "editorOverviewRuler.border": "#00000000",
            "editorError.foreground": h(p.failed), "editorWarning.foreground": h(p.waiting),
            "editorInfo.foreground": h(p.accentText),
            "diffEditor.insertedTextBackground": c(.diffAddedText), "diffEditor.removedTextBackground": c(.diffRemovedText),
            "diffEditor.insertedLineBackground": c(.diffAddedLine), "diffEditor.removedLineBackground": c(.diffRemovedLine),
            "diffEditorGutter.insertedLineBackground": c(.diffAddedLine), "diffEditorGutter.removedLineBackground": c(.diffRemovedLine),
            "diffEditor.diagonalFill": h(p.line), "diffEditor.border": h(p.line),
            "diffEditor.unchangedRegionBackground": h(p.bg1),
            "diffEditor.unchangedRegionForeground": h(p.text2),
            "peekView.border": h(p.line2),
            "peekViewResult.background": h(p.bg2), "peekViewTitle.background": h(p.bg2),
            "peekViewTitleLabel.foreground": h(p.text0), "peekViewTitleDescription.foreground": h(p.text3),
            "peekViewResult.fileForeground": h(p.text1), "peekViewResult.lineForeground": h(p.text2),
            "peekViewResult.selectionBackground": h(p.selected), "peekViewResult.selectionForeground": h(p.text0),
            "peekViewResult.matchHighlightBackground": h(p.waiting, alpha: 0.25),
            "peekViewEditor.matchHighlightBackground": h(p.waiting, alpha: 0.25),
            "editorStickyScrollHover.background": h(p.hover),
            "editorBracketHighlight.foreground1": brackets[0], "editorBracketHighlight.foreground2": brackets[1],
            "editorBracketHighlight.foreground3": brackets[2], "editorBracketHighlight.unexpectedBracket.foreground": h(p.failed),
            "editorBracketPairGuide.activeBackground1": EditorHex.with(brackets[0], alpha: 0.5),
            "editorBracketPairGuide.activeBackground2": EditorHex.with(brackets[1], alpha: 0.5),
            "editorBracketPairGuide.activeBackground3": EditorHex.with(brackets[2], alpha: 0.5),
        ]
    }

    /// CSS variables of the page's own chrome (file tabs, bars, the diff header's toggle).
    static func css(_ p: ThemePalette = Theme.palette, background: String? = nil) -> [String: String] {
        let e = Theme.Editor.self
        return [
            "--bg": background ?? h(p.bg0), "--line": h(p.line), "--text": h(p.text1),
            "--text-strong": h(p.text0), "--text2": h(p.text2), "--text3": h(p.text3),
            "--accent": h(p.accent), "--primary": h(p.accent), "--primary-text": h(p.onAccent),
            "--waiting": h(p.waiting), "--button": h(p.hover2), "--button-hover": h(Theme.buttonHover(p)),
            "--sheet": h(p.bg2),
            "--button-font": "\(e.buttonFont)px", "--bar-h": "\(e.barHeight)px", "--bar-font": "\(e.barFont)px",
            "--radius": "\(e.radius)px",
            // The page's menus copy `PopoverMenu` (spec §3.12).
            "--menu-w": "\(Theme.menuWidth)px", "--menu-r": "\(Theme.Radius.popover)px", "--menu-pad": "\(Theme.menuPadding)px",
            "--menu-item-h": "\(Theme.Height.rowList)px", "--menu-item-pl": "\(Theme.Space.s2)px",
            "--menu-item-pr": "\(Theme.Space.s2)px", "--menu-item-r": "\(Theme.Radius.control)px",
            "--menu-font": "\(Theme.Typography.body.size)px", "--menu-key-font": "\(Theme.Typography.secondary.size)px",
            "--menu-sep-v": "\(Theme.menuPadding)px", "--menu-sep-h": "0px",
            "--menu-hover": h(p.selectedFocus), "--menu-hover-text": h(p.onAccent), "--menu-border": h(p.line2),
            "--line-sheet": h(p.line2), "--inactive": "\(Theme.Opacity.inactive)",
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
