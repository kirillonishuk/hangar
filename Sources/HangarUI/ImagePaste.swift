import AppKit
import UniformTypeIdentifiers
import Workspace

/// What ⌘V does in a leaf (#70).
enum PasteAction: Equatable { case text, ctrlV }

/// claude/codex read an image from the clipboard on ⌃V, not from a text paste: an image-only clipboard
/// (png/tiff or an image file URL, no plain text) becomes ⌃V in every terminal leaf (claude may run in a
/// shell tab), except the editor (Monaco pastes itself). Text wins, as in VS Code.
func pasteAction(kind: LeafKind, types: [NSPasteboard.PasteboardType], fileURLs: [URL]) -> PasteAction {
    guard kind != .editor, !types.contains(.string) else { return .text }
    if types.contains(.png) || types.contains(.tiff) { return .ctrlV }
    let imageFile = fileURLs.contains { $0.isFileURL && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    return imageFile ? .ctrlV : .text
}

/// `pasteAction` for the general pasteboard.
@MainActor func pasteAction(kind: LeafKind) -> PasteAction {
    let pb = NSPasteboard.general
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return pasteAction(kind: kind, types: pb.types ?? [], fileURLs: urls)
}
