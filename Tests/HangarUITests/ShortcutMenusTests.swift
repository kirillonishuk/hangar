import AppKit
import Git
import Testing
@testable import HangarUI

/// The menu bar and the cheatsheet come from the shortcut table; their keys are shown, never run (HD-161).
@MainActor @Suite struct ShortcutMenusTests {
    final class Target: NSObject {
        var hits: [Shortcut] = []
        @objc func run(_ sender: NSMenuItem) { if let sc = sender.representedObject as? Shortcut { hits.append(sc) } }
    }

    private var tableItems: [Shortcut] { ShortcutGroup.allCases.flatMap { $0.sections.flatMap { $0 } } }

    @Test func tableHasEveryShortcutOnce() {
        let items = tableItems
        for sc in Shortcut.allCases + [.nextWorking] {
            #expect(items.filter { $0 == sc }.count == 1, "\(sc)")
        }
        #expect(items.count == Shortcut.allCases.count + 1)
    }

    @Test func keyEquivalentsFollowTheTable() {
        #expect(menuKeyEquivalent(.newTask) == ("n", .command))
        #expect(menuKeyEquivalent(.splitDown) == ("d", [.command, .shift]))
        #expect(menuKeyEquivalent(.shortcuts) == ("/", .command))
        #expect(menuKeyEquivalent(.prevTab) == ("\t", [.control, .shift]))
        #expect(menuKeyEquivalent(.rename).key == String(Character(Unicode.Scalar(NSF2FunctionKey)!)))
        #expect(menuKeyEquivalent(.focusSplit(.left)) == (String(Character(Unicode.Scalar(NSLeftArrowFunctionKey)!)), [.command, .option]))
        #expect(menuKeyEquivalent(.nextWorking) == ("", []))
    }

    /// Every group menu: items in table order, tabs 1…9 and split focus as submenus, each item runs its own shortcut.
    @Test func menusAreBuiltFromTheTable() {
        let target = Target()
        for group in ShortcutGroup.menus + [.help] {
            let menu = shortcutMenu(group, target: target, action: #selector(Target.run(_:)))
            #expect(menu is ShownKeysMenu)
            let items = menu.items.flatMap { $0.submenu?.items ?? [$0] }.filter { !$0.isSeparatorItem }
            #expect(items.compactMap { $0.representedObject as? Shortcut } == group.sections.flatMap { $0 })
            for item in items { item.target.map { _ = $0.perform(item.action, with: item) } }
            if group == .tab { #expect(menu.items.compactMap(\.submenu).count == 2) }
        }
        #expect(target.hits == (ShortcutGroup.menus + [.help]).flatMap { $0.sections.flatMap { $0 } })
    }

    /// A key the monitor passed on never runs a menu item: the menus only show their keys.
    @Test func menusNeverTakeKeys() throws {
        _ = NSApplication.shared
        let target = Target()
        let main = NSMenu()
        for group in ShortcutGroup.menus + [.help] {
            let item = NSMenuItem()
            item.submenu = shortcutMenu(group, target: target, action: #selector(Target.run(_:)))
            main.addItem(item)
        }
        func event(_ sc: Shortcut) throws -> NSEvent {
            let (key, mods) = menuKeyEquivalent(sc)
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: sc.key.code))
        }
        for sc in Shortcut.allCases {
            #expect(!main.performKeyEquivalent(with: try event(sc)), "\(sc)")
        }
        #expect(target.hits.isEmpty)
        // The same item in a plain menu does take ⌘T: the check above is not vacuous.
        let plain = NSMenu()
        let item = plain.addItem(withTitle: "t", action: #selector(Target.run(_:)), keyEquivalent: "t")
        item.target = target
        item.representedObject = Shortcut.newTab
        #expect(plain.performKeyEquivalent(with: try event(.newTab)))
        #expect(target.hits == [.newTab])
    }

    @Test func cheatsheetListsEveryKeyAndFilters() {
        let all = cheatsheet(query: "").flatMap(\.rows)
        let keys = Set(all.map(\.keys))
        for sc in Shortcut.allCases {
            if case .tab = sc { continue }
            #expect(keys.contains(sc.label), "\(sc)")
        }
        #expect(keys.contains("⌘1…9"))
        #expect(!all.contains { $0.title == L10n.command(.nextWorking) })  // no key, not in the cheatsheet
        #expect(cheatsheet(query: "⌘/").flatMap(\.rows).map(\.title) == [L10n.command(.shortcuts)])
        let byTitle = cheatsheet(query: L10n.command(.newTab).uppercased())
        #expect(byTitle.map(\.group) == [.tab] && byTitle[0].rows.contains { $0.keys == "⌘T" })
        #expect(cheatsheet(query: "zzzqqq").isEmpty)
    }
}

@Suite struct ListKeysTests {
    // a/ (open): a/x, a/b/ (closed); c
    private let rows: [NavRow<String>] = [
        NavRow(id: "a", folder: true, expanded: true), NavRow(id: "a/x", parent: "a"),
        NavRow(id: "a/b", parent: "a", folder: true), NavRow(id: "c"),
    ]

    @Test func upDownStepAndStopAtTheEnds() {
        #expect(listNav(rows, cursor: nil, key: .down) == .select("a"))
        #expect(listNav(rows, cursor: nil, key: .up) == .select("c"))
        #expect(listNav(rows, cursor: "gone", key: .down) == .select("a"))
        #expect(listNav(rows, cursor: "a", key: .down) == .select("a/x"))
        #expect(listNav(rows, cursor: "a/x", key: .up) == .select("a"))
        #expect(listNav(rows, cursor: "a", key: .up) == .none)
        #expect(listNav(rows, cursor: "c", key: .down) == .none)
        #expect(listNav([NavRow<String>](), cursor: nil, key: .down) == .none)
    }

    @Test func leftRightFoldAndMove() {
        #expect(listNav(rows, cursor: "a/b", key: .right) == .expand("a/b"))
        #expect(listNav(rows, cursor: "a", key: .right) == .select("a/x"))  // open: to the first child
        #expect(listNav(rows, cursor: "a/x", key: .right) == .none)
        #expect(listNav(rows, cursor: "a", key: .left) == .collapse("a"))
        #expect(listNav(rows, cursor: "a/x", key: .left) == .select("a"))  // to the parent
        #expect(listNav(rows, cursor: "a/b", key: .left) == .select("a"))  // closed folder: to the parent
        #expect(listNav(rows, cursor: "c", key: .left) == .none)
    }

    @Test func enterOpensOrFolds() {
        #expect(listNav(rows, cursor: "a/x", key: .enter) == .open("a/x"))
        #expect(listNav(rows, cursor: "a", key: .enter) == .collapse("a"))
        #expect(listNav(rows, cursor: "a/b", key: .enter) == .expand("a/b"))
    }

    @Test func treeRowsKnowTheirVisibleParent() {
        let tree = FileTree(paths: ["src/app/main.swift", "README.md"])
        let nav = treeNavRows(visibleRows(tree, expanded: ["src", "src/app"]))
        #expect(nav.map(\.id) == ["src", "src/app", "src/app/main.swift", "README.md"])
        #expect(nav.map(\.parent) == [nil, "src", "src/app", nil])
        #expect(nav.map(\.folder) == [true, true, false, false])
        #expect(nav[0].expanded)
    }

    @Test func searchRowsHideFoldedHits() {
        let files = [SearchFile(path: "a.swift", hits: [SearchHit(line: 1, column: 1, preview: "x", ranges: []),
                                                        SearchHit(line: 2, column: 1, preview: "x", ranges: [])]),
                     SearchFile(path: "b.swift", hits: [SearchHit(line: 3, column: 1, preview: "x", ranges: [])])]
        let nav = searchNavRows(files, collapsed: ["b.swift"])
        #expect(nav.map(\.id) == [.file("a.swift"), .hit("a.swift", 0), .hit("a.swift", 1), .file("b.swift")])
        #expect(nav[1].parent == .file("a.swift"))
        #expect(nav[3].folder && !nav[3].expanded)
        #expect(listNav(nav, cursor: .hit("a.swift", 1), key: .left) == .select(.file("a.swift")))
        #expect(listNav(nav, cursor: .file("b.swift"), key: .right) == .expand(.file("b.swift")))
    }
}
