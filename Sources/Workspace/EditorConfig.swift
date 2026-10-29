import Foundation

/// A color of the editor theme (#108): a syntax group, a part of the editor, a diff tint. The raw value is the id in
/// `editor_color_<id>`; «Своя» keeps only the changed ones.
public enum EditorColor: String, Sendable, CaseIterable {
    case keyword, control, string, escape, regexp, comment, number, type, function, variable, constant
    case jsonKey = "json_key", punctuation, `operator`, text
    case background, line, selection, find, gutter, gutterActive = "gutter_active", cursor, indent
    case indentActive = "indent_active", whitespace, bracket1, bracket2, bracket3
    case diffAddedLine = "diff_added_line", diffRemovedLine = "diff_removed_line"
    case diffAddedText = "diff_added_text", diffRemovedText = "diff_removed_text"

    public var configKey: String { "editor_color_" + rawValue }

    /// Colors drawn over text (selection, find matches, whitespace, diff tints): the only ones with an alpha.
    public var translucent: Bool {
        switch self {
        case .selection, .find, .whitespace, .diffAddedLine, .diffRemovedLine, .diffAddedText, .diffRemovedText: true
        default: false
        }
    }
}

/// Settings → Editor options (#108): what Monaco is created and updated with.
public struct EditorOptions: Equatable, Sendable {
    /// nil: the system monospace font (SF Mono).
    public var fontFamily: String?
    public var fontSize = 13
    /// 0 = «авто», 1.5 × the size as in VS Code.
    public var lineHeight = 0
    public var ligatures = false
    public var tabSize = 4
    public var detectIndentation = true
    public var wordWrap = false
    public var lineHighlight: LineHighlight = .all
    public var cursorStyle: CursorStyle = .line
    public var cursorBlinking: CursorBlinking = .solid
    public var whitespace: Whitespace = .selection
    public var bracketColors = true
    public var bracketGuides: BracketGuides = .active
    public var indentGuides = true
    /// ⌘S formats first (tsserver / LSP) when the file's language has a server.
    public var formatOnSave = false

    public enum LineHighlight: String, Sendable, CaseIterable { case none, gutter, line, all }
    public enum CursorStyle: String, Sendable, CaseIterable { case line, block, underline }
    public enum CursorBlinking: String, Sendable, CaseIterable { case blink, smooth, solid }
    public enum Whitespace: String, Sendable, CaseIterable { case none, selection, all }
    public enum BracketGuides: String, Sendable, CaseIterable { case none, active, all }

    public static let fontSizes = 9...24
    public static let lineHeights = 10...40
    public static let tabSizes = 1...16

    public init() {}

    /// The line height in points: «авто» resolves the way Monaco does (`round(1.5 × size)`).
    public var resolvedLineHeight: Int { lineHeight == 0 ? Self.autoLineHeight(fontSize) : lineHeight }

    public static func autoLineHeight(_ size: Int) -> Int { Int((Double(size) * 1.5).rounded()) }
}

extension HangarConfig {
    /// `#rgb` / `#rrggbb` / `#rrggbbaa` → lower-case `#rrggbb(aa)`; anything else nil.
    public static func normalizedHex(_ s: String) -> String? {
        guard s.hasPrefix("#") else { return nil }
        let digits = s.dropFirst().lowercased()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + (digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits)
    }

    /// A font family name that can go into a CSS font-family list as is (letters, digits, space, `-_.`).
    public static func isValidFontFamily(_ name: String) -> Bool {
        name.allSatisfy { $0.isLetter || $0.isNumber || " -_.".contains($0) }
    }

    /// The editor keys of the root section; false when `key` isn't one of them.
    static func parseEditorKey(_ key: String, _ raw: Substring, line: Int, into config: inout HangarConfig) throws -> Bool {
        func fail(_ reason: String) -> ParseError { .syntax(line: line, reason: reason) }
        func choice<T: RawRepresentable & CaseIterable>(_: T.Type) throws -> T where T.RawValue == String {
            let value = try stringValue(raw, line: line)
            guard let v = T(rawValue: value) else {
                throw fail("\(key) must be " + T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
            }
            return v
        }
        func number(_ range: ClosedRange<Int>, orZero: Bool = false) throws -> Int {
            let t = raw.trimmingCharacters(in: .whitespaces)
            let text = t.hasPrefix("\"") ? try stringValue(raw, line: line) : String(t.prefix { $0 != " " && $0 != "\t" && $0 != "#" })
            guard let n = Int(text), range.contains(n) || (orZero && n == 0) else {
                throw fail("\(key) must be a number \(orZero ? "0 or " : "")\(range.lowerBound)–\(range.upperBound)")
            }
            return n
        }
        var o = config.editorOptions
        defer { config.editorOptions = o }
        switch key {
        case "editor_custom_base":
            let value = try stringValue(raw, line: line)
            guard let base = EditorPalette(rawValue: value), base != .custom else {
                throw fail(#"editor_custom_base must be "dark-modern", "dark-plus" or "hangar""#)
            }
            config.editorCustomBase = base
        case "editor_font_family":
            let value = try stringValue(raw, line: line).trimmingCharacters(in: .whitespaces)
            // The name lands in a CSS font-family list: plain names only.
            guard isValidFontFamily(value) else {
                throw fail("editor_font_family must be a font name")
            }
            o.fontFamily = value.isEmpty ? nil : value
        case "editor_font_size": o.fontSize = try number(EditorOptions.fontSizes)
        case "editor_line_height": o.lineHeight = try number(EditorOptions.lineHeights, orZero: true)
        case "editor_tab_size": o.tabSize = try number(EditorOptions.tabSizes)
        case "editor_ligatures": o.ligatures = try boolValue(raw, line: line)
        case "editor_detect_indentation": o.detectIndentation = try boolValue(raw, line: line)
        case "editor_bracket_colors": o.bracketColors = try boolValue(raw, line: line)
        case "editor_indent_guides": o.indentGuides = try boolValue(raw, line: line)
        case "editor_format_on_save": o.formatOnSave = try boolValue(raw, line: line)
        case "editor_word_wrap":
            let value = try stringValue(raw, line: line)
            guard value == "on" || value == "off" else { throw fail(#"editor_word_wrap must be "off" or "on""#) }
            o.wordWrap = value == "on"
        case "editor_line_highlight": o.lineHighlight = try choice(EditorOptions.LineHighlight.self)
        case "editor_cursor_style": o.cursorStyle = try choice(EditorOptions.CursorStyle.self)
        case "editor_cursor_blinking": o.cursorBlinking = try choice(EditorOptions.CursorBlinking.self)
        case "editor_whitespace": o.whitespace = try choice(EditorOptions.Whitespace.self)
        case "editor_bracket_guides": o.bracketGuides = try choice(EditorOptions.BracketGuides.self)
        default:
            guard key.hasPrefix("editor_color_") else { return false }
            guard let color = EditorColor(rawValue: String(key.dropFirst("editor_color_".count))) else {
                throw ParseError.unknownKey(line: line, key: key)
            }
            guard let hex = normalizedHex(try stringValue(raw, line: line)) else {
                throw fail(color.translucent ? "\(key) must be #rgb, #rrggbb or #rrggbbaa" : "\(key) must be #rgb or #rrggbb")
            }
            guard color.translucent || hex.count == 7 else { throw fail("\(key) must be #rgb or #rrggbb") }
            config.editorColors[color] = hex
        }
        return true
    }
}
