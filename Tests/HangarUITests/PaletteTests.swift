import AppKit
import Foundation
import Testing
@testable import HangarUI

@Suite struct FuzzyMatchTests {
    @Test func subsequenceAcrossWords() {
        let m = fuzzyMatch("rbs", "Refactor billing service")
        #expect(m != nil)
        #expect(m?.positions == [0, 9, 17])  // the word starts, not the first «s» of «billing»
    }

    @Test func caseInsensitiveAndCyrillic() {
        #expect(fuzzyMatch("REF", "refactor") != nil)
        #expect(fuzzyMatch("пч", "Починить чекаут") != nil)
    }

    @Test func noMatch() {
        #expect(fuzzyMatch("xyz", "Refactor billing service") == nil)
        #expect(fuzzyMatch("rr", "r") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(fuzzyMatch("", "anything") == FuzzyMatch(score: 0, positions: []))
        #expect(fuzzyMatch("  ", "anything")?.score == 0)
    }

    @Test func spacesInQueryAreIgnored() {
        #expect(fuzzyMatch("ref bil", "Refactor billing service") != nil)
    }

    @Test func wordStartBeatsMidWord() {
        let start = fuzzyMatch("bs", "billing service")!.score
        let mid = fuzzyMatch("bs", "abbsx")!.score
        #expect(start > mid)
    }

    @Test func consecutiveBeatsScattered() {
        let tight = fuzzyMatch("bill", "billing")!.score
        let loose = fuzzyMatch("bill", "bxixlxl")!.score
        #expect(tight > loose)
    }

    @Test func prefixBeatsLaterMatch() {
        #expect(fuzzyMatch("set", "settings")!.score > fuzzyMatch("set", "reset")!.score)
    }

    @Test func camelCaseAndPathBoundaries() {
        #expect(fuzzyMatch("mw", "MainWindow.swift")?.positions == [0, 4])
        #expect(fuzzyMatch("hs", "Sources/HangarUI/Shortcuts.swift")?.positions == [8, 17])
    }
}

@Suite struct PaletteRankingTests {
    private let a = UUID(), b = UUID(), c = UUID()

    private var tasks: [PaletteItem] {
        [PaletteItem(task: a, name: "Refactor billing service", project: "shop"),
         PaletteItem(task: b, name: "Fix login", project: "shop"),
         PaletteItem(task: c, name: "Release notes", project: "docs")]
    }
    private let files = ["Sources/Billing/Service.swift", "README.md", "docs/billing.md"]
    private let commands: [PaletteItem] = [PaletteItem(command: .newTask, title: "New Session"),
                                           PaletteItem(command: .settings, title: "Settings")]

    private func kinds(_ s: [PaletteSection]) -> [PaletteItem.Kind] { s.map(\.kind) }

    @Test func emptyQueryShowsTasksOnly() {
        let s = paletteSections(query: "", tasks: tasks, files: files, commands: commands)
        #expect(kinds(s) == [.task])
        #expect(s[0].items.map(\.title) == tasks.map(\.title))  // original order without a query
    }

    @Test func typingAddsFilesAfterTasks() {
        let s = paletteSections(query: "s", tasks: tasks, files: files, commands: commands)
        #expect(kinds(s) == [.task, .file])
    }

    @Test func leadingAngleSwitchesToCommands() {
        let all = paletteSections(query: ">", tasks: tasks, files: files, commands: commands)
        #expect(kinds(all) == [.command])
        #expect(all[0].items.map(\.title) == ["New Session", "Settings"])
        let s = paletteSections(query: ">set", tasks: tasks, files: files, commands: commands)
        #expect(s.first?.items.map(\.title) == ["Settings"])
        #expect(s.first?.items.first?.positions == [0, 1, 2])  // offsets in the title, without the «>»
        #expect(paletteSections(query: "> new", tasks: tasks, files: files, commands: commands).first?.items.first?.title == "New Session")
        // Only a leading «>» switches.
        #expect(paletteCommandQuery("a>") == nil)
        #expect(paletteCommandQuery(">x") == "x")
    }

    @Test func rankedByScore() {
        let s = paletteSections(query: "rbs", tasks: tasks, files: [], commands: commands)
        #expect(s.first?.items.first?.title == "Refactor billing service")
        let r = paletteSections(query: "re", tasks: tasks, files: [], commands: [])
        // both are prefix matches: the shorter title wins the tie
        #expect(r.first?.items.map(\.title) == ["Release notes", "Refactor billing service"])
    }

    @Test func taskMatchesByProjectNameToo() {
        let s = paletteSections(query: "docs", tasks: tasks, files: [], commands: [])
        #expect(s.first?.items.map(\.title) == ["Release notes"])
    }

    @Test func fileNameBeatsDirectory() {
        let s = paletteSections(query: "billing", tasks: [], files: ["Sources/Billing/Service.swift", "docs/billing.md"],
                                commands: [])
        #expect(s.first?.items.first?.title == "billing.md")
        #expect(s.first?.items.first?.subtitle == "docs")
    }

    @Test func emptySectionsAreDropped() {
        let s = paletteSections(query: "zzz", tasks: tasks, files: files, commands: commands)
        #expect(s.isEmpty)
    }

    @Test func rowsPerSectionAreCapped() {
        let many = (0..<500).map { "src/file\($0).swift" }
        let s = paletteSections(query: "file", tasks: [], files: many, commands: [])
        #expect(s.first?.items.count == paletteSectionLimit)
    }

    @Test func idsAreUniqueAcrossKinds() {
        let s = paletteSections(query: "s", tasks: tasks, files: files, commands: commands)
        let ids = s.flatMap(\.items).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func fileListIsCapped() {
        var tree = FileTree(paths: (0..<20).map { "d/f\($0)" } + ["top.txt"])
        tree.setChildren([], of: "empty")
        #expect(paletteFiles(tree, cap: 5).count == 5)
        #expect(Set(paletteFiles(tree, cap: 100)) == Set((0..<20).map { "d/f\($0)" } + ["top.txt"]))  // files only, no dirs
    }

    @Test func commandsCoverTheMenuShortcuts() {
        let list = paletteCommands
        #expect(list.contains(.newTask) && list.contains(.newTab) && list.contains(.splitRight) && list.contains(.settings))
        #expect(list.contains(.toggleInspector) && list.contains(.toggleDrawer) && list.contains(.archiveTask) && list.contains(.attentionFilter))
        #expect(list.contains(.nextAttention))
        #expect(!list.contains(.quickOpen) && !list.contains(.commandPalette) && !list.contains(.tab(1)))
    }

    @Test func paletteShortcutsByKeyCode() {
        #expect(shortcut(keyCode: 35, modifiers: .command) == .quickOpen)  // P by keyCode: works in the ru layout (З)
        #expect(shortcut(keyCode: 35, modifiers: [.command, .shift]) == .commandPalette)
        #expect(shortcut(keyCode: 40, modifiers: .command) == nil)  // ⌘K stays with Ghostty (clear screen)
        #expect(Shortcut.quickOpen.label == "⌘P")
        #expect(Shortcut.commandPalette.label == "⇧⌘P")
    }
}

@MainActor @Suite struct PaletteModelTests {
    @Test func filesAreListedOnceOnFirstQuickOpen() {
        var loads = 0
        let m = PaletteModel(tasks: [], files: nil, commands: [PaletteItem(command: .settings, title: "Settings")], query: ">",
                             loadFiles: { loads += 1 })
        #expect(loads == 0)  // ⇧⌘P: commands only, no listing
        m.setQuery("bil")
        #expect(loads == 1)
        #expect(m.showsLoading)
        m.setQuery("bi")
        #expect(loads == 1)
        m.setFiles(["docs/billing.md"])
        #expect(!m.showsLoading)
        #expect(m.sections.map(\.kind) == [.file])
        m.setQuery(">")
        #expect(m.isCommands && m.sections.map(\.kind) == [.command])
    }
}
