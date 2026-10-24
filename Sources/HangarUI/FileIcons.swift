import AppKit
import SwiftUI

/// File/folder icons of the inspector (decision #NN-file-icons): a VS Code icon theme (`FileIcons/icons.json`, the
/// dark/base set) resolved with VS Code's rules; the SVGs are drawn in their own colours.
struct FileIconTheme: Sendable {
    private struct Definition: Decodable { var iconPath: String }
    private struct JSON: Decodable {
        var iconDefinitions: [String: Definition]
        var file: String
        var folder: String
        var folderExpanded: String?
        var rootFolder: String?
        var rootFolderExpanded: String?
        var fileExtensions: [String: String]?
        var fileNames: [String: String]?
        var languageIds: [String: String]?
        var folderNames: [String: String]?
        var folderNamesExpanded: [String: String]?
        var rootFolderNames: [String: String]?
        var rootFolderNamesExpanded: [String: String]?
    }

    private let json: JSON
    /// Lowercased keys: VS Code matches names and extensions case-insensitively.
    private let extensions, names, languages, folders, foldersExpanded, roots, rootsExpanded: [String: String]
    private let base: URL

    /// `base`: the folder `iconPath`s are relative to.
    init(json data: Data, base: URL) throws {
        let j = try JSONDecoder().decode(JSON.self, from: data)
        func lower(_ d: [String: String]?) -> [String: String] {
            Dictionary((d ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        json = j
        extensions = lower(j.fileExtensions)
        names = lower(j.fileNames)
        languages = lower(j.languageIds)
        folders = lower(j.folderNames)
        foldersExpanded = lower(j.folderNamesExpanded)
        roots = lower(j.rootFolderNames)
        rootsExpanded = lower(j.rootFolderNamesExpanded)
        self.base = base
    }

    /// `FileIcons/` in the HangarUI resource bundle, found as L10n finds its strings; nil → callers use the generic glyph.
    static let bundled: FileIconTheme? = {
        guard let dir = L10n.resources?.url(forResource: "FileIcons", withExtension: nil),
              let data = try? Data(contentsOf: dir.appendingPathComponent("icons.json")) else { return nil }
        return try? FileIconTheme(json: data, base: dir)
    }()

    /// fileNames → the longest compound extension (`d.ts` before `ts`) → languageIds → `file`.
    func fileIcon(_ name: String) -> String {
        let name = name.lowercased()
        if let id = names[name] { return id }
        // As VS Code: every suffix after a dot, longest first (".env" → "env").
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        for i in parts.indices.dropFirst() {
            if let id = extensions[parts[i...].joined(separator: ".")] { return id }
        }
        if parts.count > 1, let lang = Self.languageOf[String(parts[parts.count - 1])], let id = languages[lang] { return id }
        return json.file
    }

    /// folderNames(Expanded) → folder(Expanded); `root`: rootFolderNames(Expanded) → rootFolder(Expanded).
    func folderIcon(_ name: String, expanded: Bool, root: Bool = false) -> String {
        let name = name.lowercased()
        if root {
            let named = expanded ? rootsExpanded[name] ?? roots[name] : roots[name]
            if let id = named ?? (expanded ? json.rootFolderExpanded ?? json.rootFolder : json.rootFolder) { return id }
        }
        if expanded { return foldersExpanded[name] ?? folders[name] ?? json.folderExpanded ?? json.folder }
        return folders[name] ?? json.folder
    }

    /// The SVG of an icon id (nil for an unknown id).
    func url(_ id: String) -> URL? {
        json.iconDefinitions[id].map { base.appendingPathComponent($0.iconPath).standardizedFileURL }
    }

    /// VS Code's built-in language ids of common extensions (only used when the theme has `languageIds`).
    private static let languageOf: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact", "ts": "typescript",
        "tsx": "typescriptreact", "json": "json", "md": "markdown", "css": "css", "scss": "scss", "html": "html",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "swift": "swift", "java": "java", "kt": "kotlin",
        "c": "c", "h": "c", "cpp": "cpp", "cs": "csharp", "php": "php", "sh": "shellscript", "yml": "yaml",
        "yaml": "yaml", "toml": "toml", "xml": "xml", "sql": "sql", "txt": "plaintext",
    ]
}

/// Rasterised-on-demand SVGs at `Theme.iconSize`; only rows that are built (LazyVStack) ask, so hidden rows cost nothing.
@MainActor enum FileIconImages {
    /// Per icon id, misses included; bounded by the theme's ~800 ids.
    private static var cache: [String: NSImage?] = [:]

    static func image(name: String, isDir: Bool, expanded: Bool = false) -> NSImage? {
        guard let theme = FileIconTheme.bundled else { return nil }
        let id = isDir ? theme.folderIcon(name, expanded: expanded) : theme.fileIcon(name)
        if let hit = cache[id] { return hit }
        // NSImage reads SVG on macOS 14+; a broken or missing file stays nil → generic glyph.
        let image = theme.url(id).flatMap(NSImage.init(contentsOf:)).flatMap { $0.isValid ? $0 : nil }
        image?.size = NSSize(width: Theme.iconSize, height: Theme.iconSize)
        cache[id] = image
        return image
    }
}

/// The theme icon of a file or folder row in full colour; without one, folders get the `project` glyph and
/// files an empty slot of the same size (the look before icons), so names never shift.
struct FileIconView: View {
    let name: String
    var isDir = false
    var expanded = false

    var body: some View {
        if let image = FileIconImages.image(name: name, isDir: isDir, expanded: expanded) {
            Image(nsImage: image).renderingMode(.original).resizable().frame(width: Theme.iconSize, height: Theme.iconSize)
        } else if isDir {
            IconView(icon: .project)
        } else {
            Color.clear.frame(width: Theme.iconSize, height: Theme.iconSize)
        }
    }
}
