import AppKit
import Git
import SwiftUI

/// An image the diff tab or the editor shows instead of «Бинарный файл» (HD-142).
struct PreviewImage: @unchecked Sendable {
    let image: NSImage
    /// The bitmap's pixels (a vector image: its size).
    let pixels: CGSize
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

    /// Whatever NSImage reads (png, jpeg, gif, webp, heic, tiff, bmp, ico, pdf, svg …): tried, not guessed by extension.
    /// nil: empty, over `maxBytes`, or not an image.
    static func decode(_ data: Data, maxBytes: Int = maxBytes) -> PreviewImage? {
        guard !data.isEmpty, data.count <= maxBytes, let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        // The largest bitmap (an .ico holds several); vector reps report 0.
        let bitmap = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let pixels = bitmap.map { CGSize(width: CGFloat($0.pixelsWide), height: CGFloat($0.pixelsHigh)) } ?? image.size
        return PreviewImage(image: image, pixels: pixels, bytes: data.count)
    }

    /// A file on this Mac, read and decoded off the main thread.
    static func load(path: String, maxBytes: Int = maxBytes) async -> PreviewImage? {
        await Task.detached(priority: .userInitiated) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            guard let size, size <= maxBytes, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return decode(data, maxBytes: maxBytes)
        }.value
    }

    /// A file at `rev` (`path` as `Git.blob` takes it), decoded off the main thread.
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
            Image(nsImage: side.image.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: side.image.image.size.width, maxHeight: side.image.image.size.height)
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
        .accessibilityElement(children: .combine)
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
