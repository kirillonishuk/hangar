import AppKit
import Foundation
import Testing
@testable import HangarUI

/// HD-142: a binary file is shown as an image when NSImage decodes it and it is within the limit.
@MainActor @Suite struct ImagePreviewTests {
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func decodesImagesNotOtherBinaries() throws {
        let data = try png(width: 3, height: 2)
        let image = try #require(ImagePreview.decode(data))
        #expect(image.pixels == CGSize(width: 3, height: 2))
        #expect(image.bytes == data.count)
        #expect(image.caption(bytes: false) == "3×2")
        #expect(image.caption(bytes: true).hasPrefix("3×2 · "))
        // Decided by decoding, not by the name: NUL-laden bytes that aren't an image stay «binary».
        #expect(ImagePreview.decode(Data([0x00, 0x01, 0xFF, 0x7F, 0x00] + Array(repeating: 0x42, count: 64))) == nil)
        #expect(ImagePreview.decode(Data()) == nil)
        // Over the limit: not decoded, the notice stays.
        #expect(ImagePreview.decode(data, maxBytes: data.count - 1) == nil)
    }

    @Test func loadsAFileWithinTheLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-image-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try png(width: 5, height: 4)
        let path = dir.appendingPathComponent("a b.png").path
        try data.write(to: URL(fileURLWithPath: path))
        #expect(await ImagePreview.load(path: path)?.pixels == CGSize(width: 5, height: 4))
        #expect(await ImagePreview.load(path: path, maxBytes: data.count - 1) == nil)
        #expect(await ImagePreview.load(path: dir.appendingPathComponent("nope.png").path) == nil)
    }

    @Test func sidesTitledOnlyWhenBothAreImages() throws {
        let a = try #require(ImagePreview.decode(try png(width: 1, height: 1)))
        let b = try #require(ImagePreview.decode(try png(width: 2, height: 2)))
        #expect(imageSides(old: a, new: b).map(\.title) == [L10n.diffImageBefore, L10n.diffImageAfter])
        #expect(imageSides(old: nil, new: b).map(\.title) == [nil])
        #expect(imageSides(old: a, new: nil).map(\.image.pixels) == [CGSize(width: 1, height: 1)])
        #expect(imageSides(old: nil, new: nil).isEmpty)
    }
}
