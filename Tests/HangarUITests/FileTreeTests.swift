import Foundation
import Testing
@testable import HangarUI

@Suite struct FileTreeTests {
    @Test func dirsFirstSorted() {
        let tree = FileTree(paths: ["b.txt", "src/z.swift", "a.txt", "src/lib/x.swift", "Docs/r.md", "file10.txt", "file2.txt"])
        #expect(tree.children(of: "")?.map(\.name) == ["Docs", "src", "a.txt", "b.txt", "file2.txt", "file10.txt"])
        #expect(tree.children(of: "src")?.map(\.name) == ["lib", "z.swift"])
        #expect(tree.children(of: "src")?.map(\.path) == ["src/lib", "src/z.swift"])
        #expect(tree.children(of: "src")?.map(\.isDir) == [true, false])
        #expect(tree.children(of: "src/lib")?.map(\.path) == ["src/lib/x.swift"])
        #expect(tree.children(of: "a.txt") == nil)
    }

    @Test func gitDirLinksDoNotOpen() {
        let tree = FileTree(paths: ["dl", "d/x", "a"], dirLinks: ["dl"])
        let dl = tree.children(of: "")?.first { $0.name == "dl" }
        #expect(dl?.isDir == false && dl?.isDirLink == true && dl?.opensInEditor == false)
        #expect(tree.children(of: "")?.first { $0.name == "a" }?.opensInEditor == true)
    }

    @Test func visibleRowsOnlyExpanded() {
        let tree = FileTree(paths: ["a.txt", "src/z.swift", "src/lib/x.swift"])
        let rows = visibleRows(tree, expanded: ["src"])
        #expect(rows.map(\.id) == ["src", "src/lib", "src/z.swift", "a.txt"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
        #expect(rows.map(\.expanded) == [true, false, false, false])

        var plain = FileTree()
        plain.setChildren([.init(name: "src", path: "src", isDir: true), .init(name: "a.txt", path: "a.txt", isDir: false)], of: "")
        #expect(plain.children(of: "src") == nil)
        #expect(visibleRows(plain, expanded: ["src"]).map(\.id) == ["src", "a.txt"])
    }

    /// VS Code's compact folders (HD-163): a chain of single folders is one row, opened by its deepest folder.
    @Test func compactFolderChains() {
        let tree = FileTree(paths: ["apps/merchant-dashboard/src/index.ts", "apps/merchant-dashboard/src/a/b.ts",
                                    "lib/x.ts", "lib/y/z.ts", "one/file.ts", "top.ts"])
        let closed = visibleRows(tree, expanded: [])
        #expect(closed.map(\.name) == ["apps/merchant-dashboard/src", "lib", "one", "top.ts"])
        #expect(closed[0].id == "apps/merchant-dashboard/src")
        #expect(closed[0].chain == ["apps", "apps/merchant-dashboard", "apps/merchant-dashboard/src"])
        #expect(closed[3].chain.isEmpty && closed[2].chain == ["one"])
        // Open: the deepest folder's children one level in; a folder with a file and a folder is not compacted.
        let open = visibleRows(tree, expanded: ["apps/merchant-dashboard/src", "lib"])
        #expect(open.map(\.id) == ["apps/merchant-dashboard/src", "apps/merchant-dashboard/src/a", "apps/merchant-dashboard/src/index.ts",
                                   "lib", "lib/y", "lib/x.ts", "one", "top.ts"])
        #expect(open.map(\.depth) == [0, 1, 1, 0, 1, 1, 0, 0])
        #expect(open[0].expanded && !open[1].expanded)
        // Only the head open is not enough: the row stands for its deepest folder.
        #expect(visibleRows(tree, expanded: ["apps"])[0].expanded == false)
        // A plain folder compacts only through loaded folders.
        var plain = FileTree()
        plain.setChildren([.init(name: "a", path: "a", isDir: true)], of: "")
        plain.setChildren([.init(name: "b", path: "b", isDir: true)], of: "a")
        #expect(visibleRows(plain, expanded: ["a"]).map(\.name) == ["a", "b"])
        plain.setChildren([.init(name: "f", path: "f", isDir: false)], of: "a/b")
        #expect(visibleRows(plain, expanded: ["a", "a/b"]).map(\.name) == ["a/b", "f"])
    }

    @Test func autoExpand() {
        #expect(autoExpanded(for: ["src/db/pool.ts", "x.ts"], fileCount: 10) == ["src", "src/db"])
        #expect(autoExpanded(for: ["src/db/pool.ts", "x.ts"], fileCount: 60_000) == [])
        // Only the first 50 paths count.
        let many = (0..<60).map { "d\($0)/f.txt" }
        #expect(autoExpanded(for: many, fileCount: 100).count == 50)
    }
}
