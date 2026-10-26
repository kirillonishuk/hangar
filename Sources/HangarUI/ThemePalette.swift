import Foundation
import Workspace

/// One sRGB colour token: `0xrrggbb` and its opacity (only the diff tints are translucent).
public struct Hex: Hashable, Sendable, ExpressibleByIntegerLiteral {
    public let rgb: UInt32
    public let alpha: Double

    public init(_ rgb: UInt32, _ alpha: Double = 1) { self.rgb = rgb; self.alpha = alpha }
    public init(integerLiteral value: UInt32) { self.init(value) }

    var r: Int { Int((rgb >> 16) & 0xff) }
    var g: Int { Int((rgb >> 8) & 0xff) }
    var b: Int { Int(rgb & 0xff) }
    /// `rrggbb`, for Ghostty.
    var bare: String { String(format: "%06x", rgb) }
    /// As written in themes-v1.html: `#rrggbb`, or `rgba(r,g,b,.aa)` when translucent.
    var css: String {
        guard alpha < 1 else { return "#" + bare }
        return "rgba(\(r),\(g),\(b),\(String(format: "%.2f", alpha).dropFirst()))"
    }
}

/// The colour tokens of one app theme; names and values are those of themes-v1.html (its `THEMES[].t`, `ansi`).
/// Sizes and spacing don't depend on the theme and stay in `Theme`.
public struct ThemePalette: Sendable {
    // Surfaces
    var bg, titlebar, sidebar, panel, status, bottomBar, tabStrip, tabActive, tabInactive: Hex
    // States
    var hover, sbHover, hoverStrong, selected, menuHover, menuHoverText, moreBg: Hex
    // Lines and controls
    var line, lineSheet, control, controlStrong, winBorder, sheet, field, button: Hex
    // Text: text1, textStrong, text2, text3
    var tx, strong, tx2, tx3: Hex
    // Accent
    var accent, accentText, primary, primaryText: Hex
    // Statuses and limits
    var working, waiting, done, failed, failedText, idle, limOk, limTrack: Hex
    // Git and diff
    var gitM, gitA, gitD, diffAdd, diffDel: Hex
    // Editor chrome (the syntax is Dark+ in every theme) and terminal
    var editorBg, edGutter, edGutterActive, edLine, edSel, edIndent, termBg: Hex
    // Git graph rails; the Claude logo colour
    var lane1, lane2, lane3, claude: Hex
    /// Terminal ANSI 0–7 normal, 8–15 bright; used when the user's Ghostty config sets no palette.
    var ansi: [UInt32]

    static func of(_ theme: AppTheme) -> ThemePalette {
        switch theme {
        case .darkPlus: darkPlus
        case .graphite: graphite
        case .navy: navy
        }
    }

    /// A: VS Code Dark+ greys; `tx2` a touch lighter than VS Code's for AA on `selected`.
    static let darkPlus = ThemePalette(
        bg: 0x1e1e1e, titlebar: 0x252526, sidebar: 0x252526, panel: 0x252526, status: 0x252526, bottomBar: 0x252526,
        tabStrip: 0x252526, tabActive: 0x1e1e1e, tabInactive: 0x2d2d2d,
        hover: 0x2a2d2e, sbHover: 0x2a2d2e, hoverStrong: 0x37373d, selected: 0x37373d, menuHover: 0x04395e,
        menuHoverText: 0xffffff, moreBg: 0x45494e,
        line: 0x333333, lineSheet: 0x3c3c3c, control: 0x3c3c3c, controlStrong: 0x454545, winBorder: 0x3c3c3c,
        sheet: 0x252526, field: 0x3c3c3c, button: 0x3a3d41,
        tx: 0xcccccc, strong: 0xffffff, tx2: 0xa3a3a3, tx3: 0x6e6e6e,
        accent: 0x007acc, accentText: 0x3794ff, primary: 0x0e639c, primaryText: 0xffffff,
        working: 0x4fc1ff, waiting: 0xe8a33d, done: 0x89d185, failed: 0xf14c4c, failedText: 0xf48771, idle: 0x6e6e6e,
        limOk: 0x3794ff, limTrack: 0x3c3c3c,
        gitM: 0xe2c08d, gitA: 0x73c991, gitD: 0xf48771, diffAdd: Hex(0x9bb955, 0.20), diffDel: Hex(0xff0000, 0.20),
        editorBg: 0x1e1e1e, edGutter: 0x858585, edGutterActive: 0xc6c6c6, edLine: 0x2a2a2a, edSel: 0x264f78,
        edIndent: 0x404040, termBg: 0x1e1e1e,
        lane1: 0x3794ff, lane2: 0xc586c0, lane3: 0x73c991, claude: 0xd97757,
        ansi: [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
               0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff])

    /// B: warm grey with an amber accent; «ждёт» is yellow and the primary button has dark text (white fails AA).
    static let graphite = ThemePalette(
        bg: 0x232220, titlebar: 0x1f1e1c, sidebar: 0x292826, panel: 0x252422, status: 0x1f1e1c, bottomBar: 0x262523,
        tabStrip: 0x1f1e1c, tabActive: 0x2b2a27, tabInactive: 0x1f1e1c,
        hover: 0x2e2d2a, sbHover: 0x34332f, hoverStrong: 0x3a3834, selected: 0x3d3b37, menuHover: 0x3d3b37,
        menuHoverText: 0xfbf8f3, moreBg: 0x4a4743,
        line: 0x363430, lineSheet: 0x3b3935, control: 0x3d3b37, controlStrong: 0x4a4743, winBorder: 0x3d3b37,
        sheet: 0x2c2b28, field: 0x1f1e1c, button: 0x3a3834,
        tx: 0xe6e2dc, strong: 0xfbf8f3, tx2: 0xaea79e, tx3: 0x77726b,
        accent: 0xe8853d, accentText: 0xf0975a, primary: 0xe8853d, primaryText: 0x1c1b19,
        working: 0x6cb0f0, waiting: 0xf0c048, done: 0x8fcf7f, failed: 0xf0605a, failedText: 0xff8a80, idle: 0x77726b,
        limOk: 0x6cb0f0, limTrack: 0x3d3b37,
        gitM: 0xe2c08d, gitA: 0x8fcf7f, gitD: 0xf07a6e, diffAdd: Hex(0x8fcf7f, 0.14), diffDel: Hex(0xf0605a, 0.15),
        editorBg: 0x232220, edGutter: 0x77726b, edGutterActive: 0xcfc9c0, edLine: 0x2b2a27, edSel: 0x2f4a68,
        edIndent: 0x3b3935, termBg: 0x232220,
        lane1: 0xe8853d, lane2: 0x6cb0f0, lane3: 0x8fcf7f, claude: 0xd97757,
        ansi: [0x2b2a27, 0xf0605a, 0x8fcf7f, 0xf0c048, 0x6cb0f0, 0xd391d8, 0x5fc4c4, 0xd9d4cc,
               0x77726b, 0xff8a80, 0xa8e09a, 0xffd77a, 0x8fc4ff, 0xe3aee6, 0x86dada, 0xfbf8f3])

    /// C: the former navy, brought in line with Dark+; AA fixes for `tx2`, `tx3` and the primary button.
    static let navy = ThemePalette(
        bg: 0x121826, titlebar: 0x121826, sidebar: 0x1d2534, panel: 0x121826, status: 0x121826, bottomBar: 0x1b2231,
        tabStrip: 0x121826, tabActive: 0x1c2433, tabInactive: 0x121826,
        hover: 0x1a2130, sbHover: 0x273044, hoverStrong: 0x2b3444, selected: 0x2e3749, menuHover: 0x273044,
        menuHoverText: 0xffffff, moreBg: 0x3a4456,
        line: 0x222b3b, lineSheet: 0x2b3444, control: 0x2b3444, controlStrong: 0x3a4456, winBorder: 0x2b3446,
        sheet: 0x1d2534, field: 0x121826, button: 0x2b3444,
        tx: 0xe3e7ef, strong: 0xffffff, tx2: 0x9ba4b7, tx3: 0x687185,
        accent: 0x4ea1f3, accentText: 0x5fb0ff, primary: 0x2a6fd6, primaryText: 0xffffff,
        working: 0x4fc1ff, waiting: 0xffb340, done: 0x73c991, failed: 0xf14c4c, failedText: 0xff6b61, idle: 0x5f687a,
        limOk: 0x5b8def, limTrack: 0x2b3444,
        gitM: 0xe2c08d, gitA: 0x73c991, gitD: 0xf07a6e, diffAdd: Hex(0x73c991, 0.13), diffDel: Hex(0xf14c4c, 0.15),
        editorBg: 0x121826, edGutter: 0x5f687a, edGutterActive: 0xc6cbd6, edLine: 0x19202e, edSel: 0x264f78,
        edIndent: 0x262f40, termBg: 0x121826,
        lane1: 0x4ea1f3, lane2: 0xc586c0, lane3: 0x73c991, claude: 0xd97757,
        ansi: [0x1d2534, 0xf14c4c, 0x73c991, 0xe5c07b, 0x3794ff, 0xc586c0, 0x4fc1ff, 0xd4d9e3,
               0x5f687a, 0xff6b61, 0x8fe0ab, 0xf5d58a, 0x6cb0ff, 0xd7a2e6, 0x7fd6ff, 0xffffff])
}

/// WCAG 2.x contrast ratio of two opaque sRGB colours (1…21).
func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
    func luminance(_ c: UInt32) -> Double {
        [16, 8, 0].map { shift -> Double in
            let v = Double((c >> UInt32(shift)) & 0xff) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }.enumerated().reduce(0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
