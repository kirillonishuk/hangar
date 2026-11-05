import AppKit
import Foundation
import Testing
@testable import HangarUI
import Workspace

/// HD-142: a binary file is shown as an image when ImageIO decodes it and it is within the limit.
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
        // A large text file (the editor's «too large») is told apart by its header.
        let text = dir.appendingPathComponent("big.log").path
        try Data(repeating: 0x61, count: 6 << 20).write(to: URL(fileURLWithPath: text))
        #expect(await ImagePreview.load(path: text) == nil)
    }

    /// A huge image is kept as a copy at most `maxPixels` a side; its caption keeps the file's own pixels.
    @Test func downsamplesLargeImages() throws {
        let image = try #require(ImagePreview.decode(try png(width: ImagePreview.maxPixels * 2, height: 4)))
        #expect(image.pixels == CGSize(width: ImagePreview.maxPixels * 2, height: 4))
        #expect(image.image.width == ImagePreview.maxPixels)
        #expect(image.points == image.pixels)
    }

    /// The diff of a binary file stays `.loaded(.binary)` when the image is rewritten: the reload counter and the
    /// stamp still tell the tab to decode it again.
    @Test func diffImageFollowsTheFileOnDisk() async throws {
        let repo = try await TempRepo.offMain()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-image-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { repo.cleanup(); try? FileManager.default.removeItem(at: dir) }
        let file = URL(fileURLWithPath: repo.repo + "/shot.png")
        try png(width: 2, height: 2).write(to: file)
        try await repo.git("add", "shot.png", in: repo.repo)
        try await repo.git("commit", "-q", "-m", "shot", in: repo.repo)
        try png(width: 3, height: 3).write(to: file)
        var s = WorkspaceState()
        let t = s.addTask(projectId: s.addProject(name: "app", path: repo.repo), name: "a")
        _ = s.addTab(taskId: t, kind: .shell)
        s.select(taskId: t)
        let app = AppState(state: s, store: StateStore(directory: dir.appendingPathComponent("state")),
                           config: HangarConfig(), configURL: dir.appendingPathComponent("config.toml"))
        func settle() async { while let task = app.inspector.loading { await task.value } }
        app.inspector.show(taskId: t, root: repo.repo, baseBranch: { nil })
        await settle()
        app.openDiff(path: "shot.png")
        await settle()
        let tab = try #require(app.activeDiff)
        guard case .loaded(.binary) = app.inspector.diff else { Issue.record("not binary: \(app.inspector.diff)"); return }
        #expect(await app.diffImages(tab).map(\.image.pixels) == [CGSize(width: 2, height: 2), CGSize(width: 3, height: 3)])
        let loads = app.inspector.diffLoads, stamp = app.diffImageStamp(tab)

        try png(width: 5, height: 5).write(to: file)
        app.inspector.refresh(.status)
        await settle()
        guard case .loaded(.binary) = app.inspector.diff else { Issue.record("not binary: \(app.inspector.diff)"); return }
        #expect(app.inspector.diffLoads > loads)
        #expect(app.diffImageStamp(tab) != stamp)
        #expect(await app.diffImages(tab).map(\.image.pixels) == [CGSize(width: 2, height: 2), CGSize(width: 5, height: 5)])
        // Nothing changed: the same stamp, nothing to decode.
        let unchanged = app.diffImageStamp(tab)
        app.inspector.refresh(.status)
        await settle()
        #expect(app.diffImageStamp(tab) == unchanged)
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
