import AppKit
import Foundation
@testable import HangarUI
import Testing

@Suite struct FileIconsTests {
    /// The bundled theme (icons.json from the VS Code "Icons" extension), found as the app finds it.
    private static let theme = FileIconTheme.bundled

    @Test(arguments: [
        ("package.json", "_f_nodejs"),
        ("tsconfig.json", "_f_tsconfig"),
        (".env", "_f_env"),
        ("Dockerfile", "_f_docker"),
        ("foo.d.ts", "_f_typescriptdef"),
        ("foo.test.ts", "_f_testts"),
        ("foo.tsx", "_f_reactts"),
        ("README.md", "_f_readme"),
        ("foo.qqqzz", "_file"),
        ("noextension", "_file"),
    ])
    func file(_ name: String, _ id: String) throws {
        let theme = try #require(Self.theme)
        #expect(theme.fileIcon(name) == id)
    }

    @Test(arguments: [
        ("node_modules", false, "_fd_folder_node"),
        ("node_modules", true, "_fd_folder_node_open"),
        ("src", false, "_fd_folder_src"),
        ("SRC", true, "_fd_folder_src_open"),
        (".github", false, "_fd_folder_github"),
        ("qqqzz", false, "_folder"),
        ("qqqzz", true, "_folder_open"),
    ])
    func folder(_ name: String, _ expanded: Bool, _ id: String) throws {
        let theme = try #require(Self.theme)
        #expect(theme.folderIcon(name, expanded: expanded) == id)
    }

    @Test func everyIdHasAnSVG() throws {
        let theme = try #require(Self.theme)
        for id in ["_file", "_folder", "_f_nodejs", "_fd_folder_src_open"] {
            let url = try #require(theme.url(id))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(theme.url("_nope") == nil)
    }

    private static let mini = Data("""
    {"iconDefinitions": {"f": {"iconPath": "./icons/f.svg"}},
     "file": "f", "folder": "d", "folderExpanded": "do", "rootFolder": "r", "rootFolderExpanded": "ro",
     "fileExtensions": {"ts": "ts", "d.ts": "dts", "a.b.c": "abc", "b.c": "bc"},
     "fileNames": {"makefile": "mk", "foo.d.ts": "food"},
     "languageIds": {"python": "py"},
     "folderNames": {"lib": "lib", "x": "x"}, "folderNamesExpanded": {"lib": "libo"},
     "rootFolderNames": {"app": "app"}, "rootFolderNamesExpanded": {"app": "appo"}}
    """.utf8)

    @Test func semantics() throws {
        let t = try FileIconTheme(json: Self.mini, base: URL(fileURLWithPath: "/tmp"))
        #expect(t.fileIcon("Makefile") == "mk")  // fileNames, any case
        #expect(t.fileIcon("FOO.D.TS") == "food")  // fileNames beats extensions
        #expect(t.fileIcon("x.d.ts") == "dts")  // longest compound extension
        #expect(t.fileIcon("x.a.b.c") == "abc")
        #expect(t.fileIcon("y.b.c") == "bc")
        #expect(t.fileIcon("x.TS") == "ts")
        #expect(t.fileIcon("main.py") == "py")  // languageIds via the extension map
        #expect(t.fileIcon("x.zzz") == "f")
        #expect(t.folderIcon("lib", expanded: true) == "libo")
        #expect(t.folderIcon("x", expanded: true) == "x")  // no expanded entry: the folderNames one
        #expect(t.folderIcon("y", expanded: false) == "d")
        #expect(t.folderIcon("app", expanded: false, root: true) == "app")
        #expect(t.folderIcon("app", expanded: true, root: true) == "appo")
        #expect(t.folderIcon("other", expanded: true, root: true) == "ro")
        #expect(t.url("f")?.path == "/tmp/icons/f.svg")
    }

    @MainActor @Test func imagesLoadAndFallBack() throws {
        let image = try #require(FileIconImages.image(name: "package.json", isDir: false))
        #expect(image.size == NSSize(width: Theme.Icon.toolbar, height: Theme.Icon.toolbar))
        #expect(image.isValid)
        #expect(FileIconImages.image(name: "src", isDir: true, expanded: true) != nil)
    }
}
