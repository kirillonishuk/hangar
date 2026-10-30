import Foundation
import Testing

/// Design system §2, stage 11: UI code takes sizes, fonts and colours from `Theme` tokens and roles. These scans catch
/// a literal slipping back into `Sources/HangarUI`; the allowed files are the documented exceptions (spec §7.1).
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
        Rule(what: "literal frame size", pattern: #"\.frame\((width|height|minWidth|maxWidth|minHeight|maxHeight): *([2-9]|[1-9][0-9]+)\b"#, allowed: []),
    ]

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
                for (n, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    let hit = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                    #expect(!hit, "\(rule.what): \(file.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    /// The scan itself works: each rule catches its own example.
    @Test func rulesCatchExamples() throws {
        let samples = [
            ".font(.system(size: 13))", "NSFont.systemFont(ofSize: 12)", ".font(.caption)", "let c = 0x1e1e1e", ##"x = "#ff0000""##,
            "Color(red: 1, green: 0, blue: 0)", ".opacity(0.5)", "RoundedRectangle(cornerRadius: 7)", ".padding(.horizontal, 14)",
            "VStack(spacing: 6)", ".frame(width: 24)",
        ]
        for (rule, sample) in zip(Self.rules, samples) {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            #expect(regex.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil, "\(rule.what): \(sample)")
        }
        #expect(Self.rules.count == samples.count)
    }
}
