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
    /// `#rrggbb`, or `rgba(r,g,b,.aa)` when translucent.
    var css: String {
        guard alpha < 1 else { return "#" + bare }
        return "rgba(\(r),\(g),\(b),\(String(format: "%.2f", alpha).dropFirst()))"
    }
}

/// The colour roles of one app theme (design-system spec §2.7); every theme fills every role. Sizes and spacing don't
/// depend on the theme and stay in `Theme`.
public struct ThemePalette: Sendable {
    /// Content (terminal, editor, History) · chrome (toolbar, both sidebars, tabs, pane headers, cards) · popovers,
    /// menus, sheets, toasts · input fields and segment tracks.
    var bg0, bg1, bg2, field: Hex
    /// Hover · pressed, the active tab and segment · the selected row out of focus · the selected row in focus and the
    /// menu item under the pointer (text `onAccent`).
    var hover, hover2, selected, selectedFocus: Hex
    /// Separators · borders of controls, popovers and sheets.
    var line, line2: Hex
    /// Headings and the selected · main · secondary and icons · meta.
    var text0, text1, text2, text3: Hex
    /// The primary button, focus, a switched-on toggle · accent as text (links, chips, the terminal cursor) · text on
    /// `accent` and `selectedFocus`.
    var accent, accentText, onAccent: Hex
    var working, waiting, done, failed, failedText, idle: Hex
    var gitA, gitM, gitD, diffAdd, diffDel, limOk, limTrack: Hex
    /// Editor chrome (the syntax is Dark+ in every theme; its background is `bg0`).
    var edGutter, edGutterActive, edLine, edSel, edIndent: Hex
    /// Git graph rails; the Claude logo colour.
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

    /// VS Code Dark+ greys.
    static let darkPlus = ThemePalette(
        bg0: 0x1e1e1e, bg1: 0x252526, bg2: 0x2c2c2d, field: 0x1e1e1e,
        hover: 0x2a2d2e, hover2: 0x37373d, selected: 0x37373d, selectedFocus: 0x0e639c,
        line: 0x303030, line2: 0x3c3c3c,
        text0: 0xffffff, text1: 0xcccccc, text2: 0xa3a3a3, text3: 0x7a7a7a,
        accent: 0x0e639c, accentText: 0x3794ff, onAccent: 0xffffff,
        working: 0x4fc1ff, waiting: 0xe8a33d, done: 0x89d185, failed: 0xf14c4c, failedText: 0xf48771, idle: 0x6e6e6e,
        gitA: 0x73c991, gitM: 0xe2c08d, gitD: 0xf48771, diffAdd: Hex(0x9bb955, 0.20), diffDel: Hex(0xff0000, 0.20),
        limOk: 0x3794ff, limTrack: 0x3c3c3c,
        edGutter: 0x858585, edGutterActive: 0xc6c6c6, edLine: 0x2a2a2a, edSel: 0x264f78, edIndent: 0x404040,
        lane1: 0x3794ff, lane2: 0xc586c0, lane3: 0x73c991, claude: 0xd97757,
        ansi: [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
               0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff])

    /// Warm grey with an amber accent, dark enough for white text; «ждёт» is yellow.
    static let graphite = ThemePalette(
        bg0: 0x232220, bg1: 0x292826, bg2: 0x302f2c, field: 0x1f1e1c,
        hover: 0x2e2d2a, hover2: 0x3a3834, selected: 0x3a3834, selectedFocus: 0x7d4a24,
        line: 0x363430, line2: 0x3d3b37,
        text0: 0xfbf8f3, text1: 0xe6e2dc, text2: 0xaea79e, text3: 0x7d7871,
        accent: 0xb35d22, accentText: 0xf0975a, onAccent: 0xffffff,
        working: 0x6cb0f0, waiting: 0xf0c048, done: 0x8fcf7f, failed: 0xf0605a, failedText: 0xff8a80, idle: 0x77726b,
        gitA: 0x8fcf7f, gitM: 0xe2c08d, gitD: 0xf07a6e, diffAdd: Hex(0x8fcf7f, 0.14), diffDel: Hex(0xf0605a, 0.15),
        limOk: 0x6cb0f0, limTrack: 0x3d3b37,
        edGutter: 0x77726b, edGutterActive: 0xcfc9c0, edLine: 0x2b2a27, edSel: 0x2f4a68, edIndent: 0x3b3935,
        lane1: 0xe8853d, lane2: 0x6cb0f0, lane3: 0x8fcf7f, claude: 0xd97757,
        ansi: [0x2b2a27, 0xf0605a, 0x8fcf7f, 0xf0c048, 0x6cb0f0, 0xd391d8, 0x5fc4c4, 0xd9d4cc,
               0x77726b, 0xff8a80, 0xa8e09a, 0xffd77a, 0x8fc4ff, 0xe3aee6, 0x86dada, 0xfbf8f3])

    /// Navy, brought in line with Dark+.
    static let navy = ThemePalette(
        bg0: 0x121826, bg1: 0x182030, bg2: 0x1f2738, field: 0x121826,
        hover: 0x202a3b, hover2: 0x2b3446, selected: 0x2b3446, selectedFocus: 0x2a6fd6,
        line: 0x232c3d, line2: 0x2f3a4d,
        text0: 0xffffff, text1: 0xe3e7ef, text2: 0x9ba4b7, text3: 0x6b7489,
        accent: 0x2a6fd6, accentText: 0x5fb0ff, onAccent: 0xffffff,
        working: 0x4fc1ff, waiting: 0xffb340, done: 0x73c991, failed: 0xf14c4c, failedText: 0xff6b61, idle: 0x5f687a,
        gitA: 0x73c991, gitM: 0xe2c08d, gitD: 0xf07a6e, diffAdd: Hex(0x73c991, 0.13), diffDel: Hex(0xf14c4c, 0.15),
        limOk: 0x5b8def, limTrack: 0x2b3444,
        edGutter: 0x5f687a, edGutterActive: 0xc6cbd6, edLine: 0x19202e, edSel: 0x264f78, edIndent: 0x262f40,
        lane1: 0x4ea1f3, lane2: 0xc586c0, lane3: 0x73c991, claude: 0xd97757,
        ansi: [0x1d2534, 0xf14c4c, 0x73c991, 0xe5c07b, 0x3794ff, 0xc586c0, 0x4fc1ff, 0xd4d9e3,
               0x5f687a, 0xff6b61, 0x8fe0ab, 0xf5d58a, 0x6cb0ff, 0xd7a2e6, 0x7fd6ff, 0xffffff])

    /// The role names of spec §2.7 (`ansi` and the editor set aside); the spec table documents them, this list is
    /// what the tests hold every theme to.
    static let roleNames = ["bg0", "bg1", "bg2", "field", "hover", "hover2", "selected", "selectedFocus", "line", "line2",
                            "text0", "text1", "text2", "text3", "accent", "accentText", "onAccent", "working", "waiting",
                            "done", "failed", "failedText", "idle", "gitA", "gitM", "gitD", "diffAdd", "diffDel", "limOk",
                            "limTrack"]

    /// Every role by name, in `roleNames` order.
    var roles: KeyValuePairs<String, Hex> {
        ["bg0": bg0, "bg1": bg1, "bg2": bg2, "field": field, "hover": hover, "hover2": hover2, "selected": selected,
         "selectedFocus": selectedFocus, "line": line, "line2": line2, "text0": text0, "text1": text1, "text2": text2,
         "text3": text3, "accent": accent, "accentText": accentText, "onAccent": onAccent, "working": working,
         "waiting": waiting, "done": done, "failed": failed, "failedText": failedText, "idle": idle, "gitA": gitA,
         "gitM": gitM, "gitD": gitD, "diffAdd": diffAdd, "diffDel": diffDel, "limOk": limOk, "limTrack": limTrack]
    }
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
