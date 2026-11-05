import AppKit
import Git
import ImageIO
import SwiftUI

/// An image the diff tab or the editor shows instead of «Бинарный файл» (HD-142): decoded once to at most
/// `ImagePreview.maxPixels` a side, so a huge file keeps neither its bytes nor its full raster while shown.
struct PreviewImage: @unchecked Sendable {
    let image: CGImage
    /// The file's own pixels (oriented), not the decoded copy's.
    let pixels: CGSize
    /// The largest size it is shown at: its pixels at its DPI (72 when unknown), as NSImage sizes it.
    let points: CGSize
    let bytes: Int

    /// «1170×2532», with « · 1,2 МБ» when `bytes`.
    func caption(bytes withBytes: Bool) -> String {
        let size = "\(Int(pixels.width))×\(Int(pixels.height))"
        return withBytes ? size + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : size
    }
}

enum ImagePreview {
    /// Bigger files keep their notice (decoding them would take seconds and hundreds of MB).
    static let maxBytes = 50 << 20
    /// The decoded copy's longest side: sharp in a Retina pane, at most 64 MB of raster.
    static let maxPixels = 4096

    /// Whatever ImageIO reads (png, jpeg, gif, webp, heic, tiff, bmp, ico …), told by the header, not the extension;
    /// decoded here (call off the main thread). nil: not an image, or it fails to decode.
    static func decode(_ source: CGImageSource, bytes: Int) -> PreviewImage? {
        guard CGImageSourceGetType(source) != nil else { return nil }
        func props(_ i: Int) -> [CFString: Any] { CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:] }
        func size(_ p: [CFString: Any]) -> (w: Int, h: Int) {
            ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        }
        // The largest frame (an .ico holds several).
        let frames = (0..<CGImageSourceGetCount(source)).map { ($0, props($0)) }
        guard let (index, p) = frames.max(by: { size($0.1).w * size($0.1).h < size($1.1).w * size($1.1).h }) else { return nil }
        var (w, h) = size(p)
        guard w > 0, h > 0 else { return nil }
        if let o = p[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }  // turned by 90°
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        func scale(_ key: CFString) -> CGFloat { (p[key] as? Double).map { $0 > 0 ? 72 / CGFloat($0) : 1 } ?? 1 }
        let points = CGSize(width: CGFloat(w) * scale(kCGImagePropertyDPIWidth), height: CGFloat(h) * scale(kCGImagePropertyDPIHeight))
        return PreviewImage(image: image, pixels: CGSize(width: w, height: h), points: points, bytes: bytes)
    }

    /// nil: empty, over `maxBytes`, or not an image.
    static func decode(_ data: Data, maxBytes: Int = maxBytes) -> PreviewImage? {
        guard !data.isEmpty, data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source, bytes: data.count)
    }

    /// A file on this Mac, off the main thread: a file that isn't an image costs only its header.
    static func load(path: String, maxBytes: Int = maxBytes) async -> PreviewImage? {
        await Task.detached(priority: .userInitiated) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            guard let size, size > 0, size <= maxBytes,
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return decode(source, bytes: size)
        }.value
    }

    /// A file at `rev` (`path` as `Git.blob` takes it), decoded off the main thread; its bytes go once decoded.
    static func load(git: Git, rev: String, path: String) async -> PreviewImage? {
        guard let data = (try? await git.blob(rev: rev, path: path, maxBytes: maxBytes)) ?? nil else { return nil }
        return await Task.detached(priority: .userInitiated) { decode(data) }.value
    }
}

/// One image (the editor, an added or deleted file) or the old and new sides with «Было» / «Стало»: fitted into the
/// pane, never above their own size; side by side in a wide pane, one above the other in a narrow one.
struct ImagePreviewView: View {
    struct Side: Identifiable {
        var id: Int
        var title: String?
        var image: PreviewImage
    }

    /// The file's name, for VoiceOver.
    let name: String
    let sides: [Side]
    /// The file size after the pixels (the editor; the diff shows only the pixels).
    var showsBytes = false

    var body: some View {
        GeometryReader { geo in
            let layout = geo.size.width >= geo.size.height
                ? AnyLayout(HStackLayout(spacing: Theme.Space.s4)) : AnyLayout(VStackLayout(spacing: Theme.Space.s4))
            layout {
                ForEach(sides) { side in cell(side) }
            }
            .padding(Theme.Space.s4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.ui.bg0)
    }

    private func cell(_ side: Side) -> some View {
        VStack(spacing: Theme.Space.s2) {
            Image(side.image.image, scale: 1, label: Text(verbatim: name))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: side.image.points.width, maxHeight: side.image.points.height)
            HStack(spacing: Theme.Space.s1) {
                if let title = side.title {
                    Text(verbatim: title).font(Theme.Typography.caption.font(.semibold)).foregroundStyle(Theme.ui.text2)
                }
                Text(verbatim: side.image.caption(bytes: showsBytes))
                    .font(Theme.Typography.caption.font()).foregroundStyle(Theme.ui.text3).monospacedDigit()
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // the caption stays under its image, both centered
        .accessibilityElement(children: .combine)  // «name, Было, 1170×2532»
    }
}


/// Both sides → «Было» and «Стало»; one (added, deleted, or the other side is no image) → just it, untitled.
@MainActor func imageSides(old: PreviewImage?, new: PreviewImage?) -> [ImagePreviewView.Side] {
    switch (old, new) {
    case let (old?, new?):
        return [.init(id: 0, title: L10n.diffImageBefore, image: old), .init(id: 1, title: L10n.diffImageAfter, image: new)]
    case let (old?, nil): return [.init(id: 0, image: old)]
    case let (nil, new?): return [.init(id: 1, image: new)]
    case (nil, nil): return []
    }
}

extension AppState {
    /// What the diff tab's images come from: every reload of the diff checks it, so an image rewritten on disk (or a
    /// change list that now has the file) loads again while unrelated changes in the repo don't decode anything.
    func diffImageStamp(_ tab: DiffTab) -> String {
        guard tab.commit == nil else { return "" }  // a commit's files never change
        guard let root = inspector.root, let changes = inspector.changes,
              let file = changes.files.first(where: { $0.path == tab.path }) else { return "-" }
        let a = try? FileManager.default.attributesOfItem(atPath: root + "/" + tab.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(changes.from)|\(file.change)|\(file.origPath ?? "")|\(size)|\(mtime)"
    }

    /// The diff tab's binary file as images: the old side from git (the base the diff compares with, or the commit's
    /// parent), the new one from the commit or the working tree. Empty: no side is an image, or the project is on a server.
    func diffImages(_ tab: DiffTab) async -> [ImagePreviewView.Side] {
        guard let task = selectedTask, let project = project(task.projectId) else { return [] }
        let runner = runner(for: project)
        // shortcut: a server's project keeps «Бинарный файл» — its runner has no byte channel; add one when asked for.
        guard runner.isLocal else { return [] }
        var old: PreviewImage?, new: PreviewImage?
        if let hash = tab.commit {
            guard let root = gitPanel.root else { return [] }
            let git = Git(repo: root, runner: runner)
            old = await ImagePreview.load(git: git, rev: hash + "^", path: tab.origPath ?? tab.path)
            new = await ImagePreview.load(git: git, rev: hash, path: tab.path)
        } else {
            guard let root = inspector.root, let changes = inspector.changes,
                  let file = changes.files.first(where: { $0.path == tab.path }) else { return [] }
            if file.change != .untracked && file.change != .added {
                old = await ImagePreview.load(git: Git(repo: root, runner: runner), rev: changes.from,
                                              path: "./" + (file.origPath ?? file.path))
            }
            if file.change != .deleted { new = await ImagePreview.load(path: root + "/" + tab.path) }
        }
        return imageSides(old: old, new: new)
    }
}
