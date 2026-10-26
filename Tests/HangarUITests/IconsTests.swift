import AppKit
import Testing
@testable import HangarUI

/// Icons v2 (icons-v2.html): 32 line glyphs drawn in code on a 16 grid, plus the two brand logos.
@MainActor @Suite struct IconsTests {
    private var glyphs: [Icon] { Icon.allCases.filter { $0 != .claude && $0 != .codex } }

    @Test func thirtySevenGlyphsAndTwoBrands() {
        #expect(glyphs.count == 37)  // + history, search (redesign v1); appearance, bell, plug (settings categories)
        #expect(Icon.allCases.count == 39)
    }

    @Test func glyphsAreTemplatesOfTheRequestedSize() {
        for icon in glyphs {
            for size: CGFloat in [16, 13, 12, 10] {
                let image = icon.image(size: size)
                #expect(image.isTemplate, "\(icon)")
                #expect(image.size == NSSize(width: size, height: size), "\(icon) \(size)")
            }
        }
    }

    @Test func glyphsDrawSomething() throws {
        for icon in glyphs {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.image(size: 16).draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            let inked = (0..<32).flatMap { x in (0..<32).map { y in rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 } }.filter { $0 > 0.5 }.count
            #expect(inked > 8, "\(icon) draws \(inked) px")
        }
    }

    /// Stroke centres stay on the keylines 1…15, so the 1.5 pt line never clips at the image edge.
    @Test func glyphsStayInsideTheKeylines() {
        for icon in glyphs {
            let b = icon.outline.bounds
            #expect(!b.isEmpty, "\(icon)")
            #expect(b.minX >= 1 && b.minY >= 1 && b.maxX <= 15 && b.maxY <= 15, "\(icon): \(b)")
        }
    }

    @Test func noTwoIconsShareAGlyph() {
        for (i, a) in glyphs.enumerated() {
            for b in glyphs[(i + 1)...] { #expect(a.glyph != b.glyph, "\(a) == \(b)") }
        }
    }

    @Test func imagesAreCachedPerSize() {
        #expect(Icon.add.image(size: 16) === Icon.add.image(size: 16))
        #expect(Icon.add.image(size: 16) !== Icon.add.image(size: 10))
    }
}
