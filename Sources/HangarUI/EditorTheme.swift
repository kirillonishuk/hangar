import Foundation
import Workspace

typealias EditorPalette = HangarConfig.EditorPalette

/// The three lists of Settings → Appearance → «Цвета».
enum EditorColorSection: CaseIterable { case syntax, editor, diff }

extension EditorColor {
    var section: EditorColorSection {
        switch self {
        case .keyword, .control, .string, .escape, .regexp, .comment, .number, .type, .function, .variable, .constant, .jsonKey,
             .punctuation, .operator, .text: .syntax
        case .diffAddedLine, .diffRemovedLine, .diffAddedText, .diffRemovedText: .diff
        default: .editor
        }
    }

    /// Monarch tokens and tsserver / LSP semantic types it colors (one table for every theme; empty for the editor's parts).
    var tokens: [String] {
        switch self {
        case .keyword: ["keyword", "keyword.json", "tag", "metatag"]
        case .control: ["keyword.control"]
        case .variable: ["identifier", "variable", "parameter", "property", "attribute.name"]
        case .jsonKey: ["string.key.json"]
        case .type: ["type", "type.identifier", "class", "interface", "enum", "namespace", "typeParameter", "annotation"]
        case .function: ["function", "member", "predefined"]
        case .constant: ["constant", "enumMember"]
        case .string: ["string", "string.value.json", "attribute.value"]
        case .escape: ["string.escape"]
        case .regexp: ["regexp"]
        case .number: ["number"]
        case .comment: ["comment", "comment.doc"]
        case .operator: ["operator"]
        case .punctuation: ["delimiter", "delimiter.bracket"]
        case .text: [""]
        default: []
        }
    }
}

/// `#rrggbb(aa)` helpers for the editor colors (config values, Monaco's theme).
enum EditorHex {
    static func of(_ x: Hex, alpha: Double? = nil) -> String {
        "#" + x.bare + ((alpha ?? (x.alpha < 1 ? x.alpha : nil)).map { String(format: "%02x", Int(($0 * 255).rounded())) } ?? "")
    }

    /// The `rrggbb` part (Monaco's token rules take no alpha).
    static func rgb(_ hex: String) -> String { String(hex.dropFirst().prefix(6)) }

    static func alpha(_ hex: String) -> Double {
        hex.count == 9 ? Double(Int(hex.suffix(2), radix: 16) ?? 255) / 255 : 1
    }

    /// The same color at `alpha` (1 drops the `aa`).
    static func with(_ hex: String, alpha: Double) -> String {
        let a = max(0, min(1, alpha))
        return "#" + rgb(hex) + (a >= 1 ? "" : String(format: "%02x", Int((a * 255).rounded())))
    }

    /// 0…1 components (`#rrggbb(aa)`); nil for anything else.
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let n = HangarConfig.normalizedHex(hex), let v = UInt32(rgb(n), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, alpha(n))
    }

    /// `#rrggbb(aa)` from 0…1 components (clamped).
    static func from(r: Double, g: Double, b: Double, a: Double = 1) -> String {
        func byte(_ v: Double) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return with(of(Hex(byte(r) << 16 | byte(g) << 8 | byte(b))), alpha: a)
    }

    /// Hue, saturation, lightness (0…1) and alpha: the popover's two bars move hue and lightness.
    static func hsl(_ hex: String) -> (h: Double, s: Double, l: Double, a: Double) {
        guard let c = components(hex) else { return (0, 0, 0, 1) }
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), l = (mx + mn) / 2, d = mx - mn
        guard d > 0 else { return (0, 0, l, c.a) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch mx {
        case c.r: h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
        case c.g: h = (c.b - c.r) / d + 2
        default: h = (c.r - c.g) / d + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l, c.a)
    }

    static func fromHSL(h: Double, s: Double, l: Double, a: Double = 1) -> String {
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch Int(h * 6) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return from(r: r + m, g: g + m, b: b + m, a: a)
    }
}

/// The popover's hue and lightness bars. A color made by the bars keeps the hue and saturation it was made with:
/// near black or white they can't be read back from the hex, so a drag to black and back would lose them.
struct EditorHSL: Equatable {
    var h, s, l, a: Double

    init(h: Double, s: Double, l: Double, a: Double) { (self.h, self.s, self.l, self.a) = (h, s, l, a) }

    init(_ hex: String) {
        let x = EditorHex.hsl(hex)
        self.init(h: x.h, s: x.s, l: x.l, a: x.a)
    }

    var hex: String { EditorHex.fromHSL(h: min(h, 0.999), s: s, l: l, a: a) }

    /// The held values while the color on screen is still the one they made; otherwise the color's own.
    static func basis(_ hex: String, held: (hsl: EditorHSL, hex: String)?) -> EditorHSL {
        if let held, held.hex == hex { return held.hsl }
        return EditorHSL(hex)
    }
}

/// One editor theme resolved to all its colors (#108, #109): the app theme's pair, a built-in one (VS Code Dark Modern
/// has its own editor colors; Dark+ and Hangar take theirs from the app theme) or «Своя» = its base plus the changed colors.
struct EditorTheme: Equatable {
    let palette: EditorPalette
    /// The built-in theme the colors come from (itself, or «Своя»'s base).
    let base: EditorPalette
    let colors: [EditorColor: String]
    /// «Своя»'s changed colors (empty for a built-in theme).
    let changed: Set<EditorColor>
    /// The app theme's chrome around the text (widgets, menus) and Dark+ / Hangar's editor colors.
    let app: AppTheme

    init(palette: EditorPalette, customBase: EditorPalette, custom: [EditorColor: String], app: AppTheme) {
        self.palette = palette
        self.app = app
        var config = HangarConfig()
        (config.editorPalette, config.editorCustomBase, config.theme) = (palette, customBase, app)
        base = config.editorBase
        var colors = Self.builtIn(base, ThemePalette.of(app))
        if palette == .custom {
            for (color, hex) in custom { colors[color] = hex }
            changed = Set(custom.keys)
        } else {
            changed = []
        }
        self.colors = colors
    }

    init(_ config: HangarConfig) {
        self.init(palette: config.editorPalette, customBase: config.editorCustomBase, custom: config.editorColors,
                  app: config.theme)
    }

    func hex(_ color: EditorColor) -> String { colors[color] ?? "#000000" }

    /// The colors of a built-in theme in an app theme (the table of the spec, §2).
    static func builtIn(_ palette: EditorPalette, _ p: ThemePalette) -> [EditorColor: String] {
        var c: [EditorColor: String] = [
            .keyword: "#569cd6", .control: "#c586c0", .string: "#ce9178", .escape: "#d7ba7d", .regexp: "#d16969",
            .comment: "#6a9955", .number: "#b5cea8", .type: "#4ec9b0", .function: "#dcdcaa", .variable: "#9cdcfe",
            .constant: "#4fc1ff", .jsonKey: "#9cdcfe", .punctuation: "#d4d4d4", .operator: "#d4d4d4", .text: "#d4d4d4",
            .bracket1: "#ffd700", .bracket2: "#da70d6", .bracket3: "#179fff",
        ]
        if palette == .darkModern {
            c[.punctuation] = "#cccccc"
            c[.text] = "#cccccc"
            let ui: [EditorColor: String] = [
                .background: "#1f1f1f", .line: "#282828", .selection: "#264f78", .find: "#9e6a03", .gutter: "#6e7681",
                .gutterActive: "#cccccc", .cursor: "#aeafad", .indent: "#404040", .indentActive: "#707070", .whitespace: "#e3e4e229",
                .diffAddedLine: "#9bb95533", .diffRemovedLine: "#ff000033", .diffAddedText: "#9ccc2c33", .diffRemovedText: "#ff000033",
            ]
            return c.merging(ui) { $1 }
        }
        if palette == .hangar {
            func muted(_ kind: SyntaxKind) -> String { "#" + String(format: "%06x", Theme.Diff.syntaxHex(kind)) }
            let tx = EditorHex.of(p.tx)
            let syntax: [EditorColor: String] = [
                .keyword: muted(.keyword), .control: muted(.keyword), .string: muted(.string), .escape: muted(.string),
                .regexp: muted(.string), .comment: muted(.comment), .number: muted(.number), .constant: muted(.number),
                .type: muted(.type), .jsonKey: muted(.type), .function: tx, .variable: tx, .punctuation: tx, .operator: tx, .text: tx,
            ]
            c.merge(syntax) { $1 }
        }
        let ui: [EditorColor: String] = [
            .background: EditorHex.of(p.editorBg), .line: EditorHex.of(p.edLine), .selection: EditorHex.of(p.edSel),
            .find: EditorHex.of(p.waiting, alpha: 0.35), .gutter: EditorHex.of(p.edGutter), .gutterActive: EditorHex.of(p.edGutterActive),
            .cursor: EditorHex.of(p.accent), .indent: EditorHex.of(p.edIndent), .indentActive: EditorHex.of(p.controlStrong),
            .whitespace: EditorHex.of(p.control), .diffAddedLine: EditorHex.of(p.diffAdd), .diffRemovedLine: EditorHex.of(p.diffDel),
            // Changed chars: a light step over the row tint, not a saturated slab.
            .diffAddedText: EditorHex.of(p.gitA, alpha: 0.12), .diffRemovedText: EditorHex.of(p.gitD, alpha: 0.12),
        ]
        return c.merging(ui) { $1 }
    }

    /// Dark Modern draws the current line as a frame (VS Code); the others fill it.
    var lineFilled: Bool { base != .darkModern }
    /// Hangar's muted palette keeps its italic comments.
    var italicComments: Bool { base == .hangar }
}

// MARK: «Своя»: changes to the config

extension HangarConfig {
    /// A color changed in Settings: following the app theme or on a built-in theme it creates «Своя» on the theme
    /// shown (the built-in stays as it is); a color equal to the base's own is no change at all.
    func customizing(_ color: EditorColor, _ hex: String) -> HangarConfig {
        // Only colors drawn over text take an alpha (as the config parser): the preview then matches the editor.
        let hex = color.translucent ? hex : EditorHex.with(hex, alpha: 1)
        var c = self
        if c.editorPalette != .custom {
            let base = c.editorBase
            // «Как у темы» starts a fresh «Своя»: colors kept for the switch's way back stay hidden (#109).
            if c.editorPalette == .theme || c.editorCustomBase != base { c.editorColors = [:] }
            c.editorCustomBase = base
            c.editorPalette = .custom
        }
        let own = EditorTheme.builtIn(c.editorCustomBase, ThemePalette.of(theme))[color]
        c.editorColors[color] = hex == own ? nil : hex
        return c
    }

    /// Editing a v0.7.0 built-in theme would drop «Своя»'s changes made on another base: ask first. («Как у темы» drops
    /// its hidden colors without asking: they aren't on screen, #109.)
    var customizingReplacesColors: Bool {
        editorPalette.isBuiltIn && editorCustomBase != editorBase && !editorColors.isEmpty
    }

    /// «Сбросить» of one color; nil: «Сбросить всё», back to the app theme's editor theme with nothing left over.
    func resettingColor(_ color: EditorColor?) -> HangarConfig {
        var c = self
        if let color { c.editorColors[color] = nil } else {
            c.editorColors = [:]
            c.editorCustomBase = HangarConfig().editorCustomBase
            c.editorPalette = .theme
        }
        return c
    }

    /// The «Как у темы / Своя» switch. «Своя» brings back the saved colors on their base, or starts empty on the theme
    /// shown; «Как у темы» keeps them for the way back.
    func followingTheme(_ follow: Bool) -> HangarConfig {
        var c = self
        if follow {
            c.editorPalette = .theme
        } else if c.editorPalette != .custom {
            if c.editorColors.isEmpty { c.editorCustomBase = c.editorBase }
            c.editorPalette = .custom
        }
        return c
    }

    /// The config file edit that turns `self`'s editor theme keys into `new`'s: only what differs, removed when gone.
    func editorThemeEdit(to new: HangarConfig) -> (String) -> String {
        { text in
            // A default value is no key at all («Как у темы», Dark Modern's base).
            func set(_ t: String, _ key: String, _ value: EditorPalette, default: EditorPalette) -> String {
                value == `default` ? HangarConfig.removing(t, key: key) : HangarConfig.updating(t, key: key, value: value.rawValue)
            }
            let defaults = HangarConfig()
            var t = text
            if new.editorPalette != editorPalette { t = set(t, "editor_palette", new.editorPalette, default: defaults.editorPalette) }
            if new.editorCustomBase != editorCustomBase {
                t = set(t, "editor_custom_base", new.editorCustomBase, default: defaults.editorCustomBase)
            }
            for color in EditorColor.allCases where new.editorColors[color] != editorColors[color] {
                t = new.editorColors[color].map { HangarConfig.updating(t, key: color.configKey, value: $0) }
                    ?? HangarConfig.removing(t, key: color.configKey)
            }
            return t
        }
    }
}
