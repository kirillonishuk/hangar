import Foundation
import Testing
@testable import HangarUI

/// Design system §2, stage 11: UI code takes sizes, fonts and colours from `Theme` tokens and roles. A tripwire, not a
/// proof: line-based scans of `Sources/HangarUI` catch the usual ways a literal slips back; the allowed files and
/// constants are the documented exceptions (spec §7.1).
@Suite struct DesignTokenGuardTests {
    private struct Rule {
        let what: String
        let pattern: String
        /// File names where the pattern is allowed.
        let allowed: Set<String>
    }

    private static let themeFiles: Set<String> = [
        "Theme.swift", "Theme+Colors.swift", "Theme+EditorSettings.swift", "Theme+Git.swift", "Theme+Sessions.swift",
        "Theme+Sheets.swift", "Theme+Sidebar.swift", "Theme+Tabs.swift", "Theme+Tokens.swift", "Theme+Update.swift", "ThemePalette.swift",
    ]

    private static let rules: [Rule] = [
        // Type scale: `Theme.Typography`; the theme tile's miniature code is the only other `.system(size:)`.
        Rule(what: "font size outside Theme.Typography", pattern: #"\.system\(size:"#, allowed: ["Theme+Tokens.swift", "SettingsView+Editor.swift"]),
        Rule(what: "literal NSFont size", pattern: #"(ofSize|size): *[0-9]"#, allowed: ["Theme+Tokens.swift", "SettingsView+Editor.swift"]),  // the scale; a family lookup, not drawn
        Rule(what: "SwiftUI text style instead of a type token",
             pattern: #"\.font\(\.(body|caption2?|title[23]?|headline|subheadline|footnote|callout|largeTitle)\b"#, allowed: []),
        // Colours: roles in `ThemePalette`; the diff syntax colours (`Theme.Diff.syntaxHex`); Monaco's built-in editor themes
        // and its widget colours (editor data, not app roles).
        Rule(what: "hex colour literal", pattern: #"0x[0-9a-fA-F]{6}\b"#, allowed: ["ThemePalette.swift", "Theme.swift"]),
        Rule(what: "CSS hex colour literal", pattern: ##""#[0-9a-fA-F]{6}"##, allowed: ["EditorTheme.swift", "MonacoAssets.swift"]),
        Rule(what: "colour built from components",
             pattern: #"Color\((red|white|hue):|Color\(\.sRGB|NSColor\((srgbRed|red|white|calibratedRed|calibratedWhite|deviceRed):"#,
             allowed: ["Theme+Colors.swift", "Theme+EditorSettings.swift", "EditorSettingsModel.swift"]),
        // Sizes and opacities: `Theme` constants (1 pt lines and 0 / 1 are not sizes).
        Rule(what: "literal opacity", pattern: #"(\.opacity\(|withAlphaComponent\(|opacity: *)0?\.[0-9]"#, allowed: themeFiles),
        Rule(what: "literal corner radius", pattern: #"cornerRadius: *[0-9]"#, allowed: themeFiles),
        Rule(what: "literal padding", pattern: #"\.padding\((\.[a-zA-Z]+, *)?-?([2-9]|[1-9][0-9]+)\b"#, allowed: []),
        Rule(what: "literal stack spacing", pattern: #"spacing: *([2-9]|[1-9][0-9]+)\b"#, allowed: []),
        Rule(what: "literal frame size",
             pattern: #"\.frame\([^)]*\b(width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight): *-?([2-9]|[1-9][0-9]+)\b"#,
             allowed: []),
    ]

    /// `static let x: CGFloat = <number>` in `extension Theme` blocks outside Theme*.swift: only these, each a value the
    /// spec gives its component (§3.10 segment, §3.11 checkbox / radio / switch, focus ring §2.8) or a 1 pt line.
    private static let allowedConstants: Set<String> = [
        "InputField.swift:border",
        "Controls.swift:ringWidth", "Controls.swift:segmentPadding", "Controls.swift:segmentShadowRadius", "Controls.swift:segmentShadowY",
        "Controls.swift:checkbox", "Controls.swift:checkboxRadius", "Controls.swift:radioEdge", "Controls.swift:radioOnEdge",
        "Controls.swift:switchWidth", "Controls.swift:switchHeight", "Controls.swift:switchKnob",
    ]

    /// The line without a trailing `//` comment (a tripwire: a `//` inside a string literal cuts it short too).
    private static func code(_ line: String) -> String {
        line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
    }

    private static var sourceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/HangarUI").standardized
    }

    @Test func noLiteralsOutsideTokens() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "Sources/HangarUI not found at \(Self.sourceDir.path)")
        for rule in Self.rules {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            for file in files where !rule.allowed.contains(file.lastPathComponent) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (n, full) in lines.enumerated() {
                    let line = Self.code(full)
                    let hit = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                    #expect(!hit, "\(rule.what): \(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    @Test func noLiteralConstantsOutsideThemeFiles() throws {
        let regex = try NSRegularExpression(pattern: #"static let (\w+): CGFloat = -?[0-9]"#)
        let files = try FileManager.default.contentsOfDirectory(at: Self.sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !Self.themeFiles.contains($0.lastPathComponent) }
        for file in files {
            var inTheme = false  // inside a top-level `extension Theme…` block
            for (n, full) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let line = Self.code(full)
                if line.hasPrefix("extension Theme") { inTheme = true } else if line.hasPrefix("}") { inTheme = false }
                guard inTheme, let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let r = Range(m.range(at: 1), in: line) else { continue }
                let key = "\(file.lastPathComponent):\(line[r])"
                #expect(Self.allowedConstants.contains(key), "literal size constant outside Theme*.swift: \(key) (line \(n + 1))")
            }
        }
    }

    /// The scan itself works: each rule catches its own example.
    @Test func rulesCatchExamples() throws {
        let samples = [
            ".font(.system(size: 13))", "NSFont.systemFont(ofSize: 12)", ".font(.caption)", "let c = 0x1e1e1e", ##"x = "#ff0000""##,
            "Color(red: 1, green: 0, blue: 0)", ".opacity(0.5)", "RoundedRectangle(cornerRadius: 7)", ".padding(.horizontal, 14)",
            "VStack(spacing: 6)", ".frame(maxWidth: .infinity, minHeight: 30)",
        ]
        for (rule, sample) in zip(Self.rules, samples) {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            #expect(regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil, "\(rule.what): \(sample)")
        }
        #expect(Self.rules.count == samples.count)
    }
}

/// The server report's budget in its sheet: measured, never the whole window before a measurement, last good value kept.
@MainActor @Suite struct SheetChromeTests {
    @Test func budgetFollowsMeasurements() {
        var c = SheetChrome()
        #expect(c.budget(700) == Theme.serverReportMinHeight)  // nothing measured: only the minimum, never the window
        c.sheetMeasured(400)
        #expect(c.budget(700) == Theme.serverReportMinHeight)  // no report yet
        c.partMeasured(250)
        #expect(c.budget(700) == 550)  // chrome 150
        c.partMeasured(nil)  // the report went away; the sheet shrinks
        c.sheetMeasured(150)
        #expect(c.budget(700) == 550)  // last good chrome kept
        c.partMeasured(300)
        c.sheetMeasured(460)
        #expect(c.budget(700) == 540)
        #expect(c.budget(200) == Theme.serverReportMinHeight)  // a tiny window still leaves the minimum
    }
}
