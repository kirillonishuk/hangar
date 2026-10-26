import AppKit
import Foundation
import GhosttyBridge
import Observation
import SwiftUI
import Testing
import Workspace
@testable import HangarUI

/// App themes (themes-v1.html): every token of the mockup in every theme, AA contrast, live switching.
@MainActor @Suite(.serialized) struct ThemePaletteTests {
    /// `key:'value'` pairs of one theme's `t:{…}` and its `ansi:[…]` in the approved mockup.
    private static func mockup(_ id: String) throws -> (tokens: [String: String], ansi: [String]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/superpowers/mockups/themes-v1.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(html.range(of: "{ id:'\(id)'"))
        let rest = html[start.upperBound...]
        let t = try #require(rest.range(of: "t:{")), tEnd = try #require(rest[t.upperBound...].range(of: "},"))
        var tokens: [String: String] = [:]
        for pair in rest[t.upperBound..<tEnd.lowerBound].matches(of: /(\w+):'([^']+)'/) {
            tokens[String(pair.output.1)] = String(pair.output.2)
        }
        let a = try #require(rest.range(of: "ansi:[")), aEnd = try #require(rest[a.upperBound...].range(of: "]"))
        let ansi = rest[a.upperBound..<aEnd.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "' ")) }
        return (tokens, ansi)
    }

    @Test(arguments: AppTheme.allCases) func paletteHasEveryMockupToken(_ theme: AppTheme) throws {
        let (tokens, ansi) = try Self.mockup(theme.rawValue)
        let palette = ThemePalette.of(theme)
        let ours = Dictionary(uniqueKeysWithValues: Mirror(reflecting: palette).children.compactMap { child -> (String, String)? in
            guard let label = child.label, let hex = child.value as? Hex else { return nil }
            return (label, hex.css)
        })
        #expect(tokens.count > 50)
        #expect(Set(ours.keys) == Set(tokens.keys))
        for (key, value) in tokens { #expect(ours[key] == value.lowercased(), "\(theme.rawValue).\(key)") }
        #expect(palette.ansi.map { Hex($0).css } == ansi.map { $0.lowercased() })
        #expect(palette.ansi.count == 16)
    }

    /// text1 / text2 stay AA (4.5 : 1) on every surface they sit on; button and menu text too.
    @Test(arguments: AppTheme.allCases) func textPassesAA(_ theme: AppTheme) {
        let p = ThemePalette.of(theme)
        for text in [p.tx, p.tx2] {
            for surface in [p.bg, p.sidebar, p.selected, p.panel, p.sheet, p.sbHover, p.tabInactive] {
                #expect(contrastRatio(text.rgb, surface.rgb) >= 4.5, "\(theme.rawValue) \(text.css) on \(surface.css)")
            }
        }
        #expect(contrastRatio(p.primaryText.rgb, p.primary.rgb) >= 4.5)
        #expect(contrastRatio(p.menuHoverText.rgb, p.menuHover.rgb) >= 4.5)
        #expect(contrastRatio(p.failedText.rgb, p.sidebar.rgb) >= 4.5)
        #expect(contrastRatio(p.tx3.rgb, p.sidebar.rgb) >= 3)
    }

    @Test func contrastMatchesWCAG() {
        #expect(abs(contrastRatio(0xffffff, 0x000000) - 21) < 0.01)
        #expect(abs(contrastRatio(0x777777, 0xffffff) - 4.48) < 0.01)
    }

    /// Tokens are read through the observable theme holder, so a SwiftUI body that uses one redraws on a switch.
    /// (Other suites run in parallel and read the global theme, so a separate holder is switched here.)
    @Test func tokensObserveTheTheme() {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag(), holder = Theme.Selection()
        withObservationTracking { _ = holder.theme } onChange: { flag.fired = true }
        holder.theme = .graphite
        #expect(flag.fired)
        #expect(cssHex(Theme.bg) == ThemePalette.of(Theme.current).bg.css)
        #expect(Theme.ui.bg == Color(nsColor: Theme.ns(ThemePalette.of(Theme.current).bg)))
    }

    @Test func terminalColorsFollowTheTheme() {
        let c = Theme.terminalColors(force: false, of: .of(.graphite))
        #expect(c.background == "232220")
        #expect(c.palette.count == 16)
        #expect(c.palette[1] == "f0605a")
        #expect(c.cursor == "e8853d")
        #expect(!c.forceBackground)
        #expect(Theme.terminalColors(force: true, of: .of(.navy)).forceBackground)
        #expect(Theme.terminalColors(force: true, of: .of(.navy)).background == "121826")
    }
}
