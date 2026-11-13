import AppKit
import SwiftUI

/// A command menu of the menu bar and a group of the cheatsheet (HD-161). One table with `Shortcut`, so the menus,
/// the cheatsheet and the keys can't disagree.
enum ShortcutGroup: CaseIterable {
    case app, chat, tab, view, help

    /// Sections in menu order (a separator between them). A section of tabs 1…9 or of split focus is one submenu.
    /// A key of the table no group names lands at the end of «Вид», so no key is ever missing from the menus.
    var sections: [[Shortcut]] {
        guard self == .view else { return placed }
        let named = Self.allCases.flatMap { $0.placed.flatMap { $0 } }
        let rest = Shortcut.allCases.filter { !named.contains($0) }
        return placed + (rest.isEmpty ? [] : [rest])
    }

    private var placed: [[Shortcut]] {
        switch self {
        case .app: [[.settings]]  // the app menu's «Настройки…» is built by hand (a real key equivalent, other windows need it)
        case .chat:
            [[.newTask, .newFreeChat, .newSubSession, .addProject], [.rename, .archiveTask],
             [.prevTask, .nextTask, .nextAttention, .nextWorking, .attentionFilter], [.runAction, .revealInFinder, .copyPath]]
        case .tab:
            [[.newTab, .closeTab], [.splitRight, .splitDown], [.prevTab, .nextTab], (1...9).map { .tab($0) },
             [SplitDirection.left, .right, .up, .down].map { .focusSplit($0) }]
        case .view:
            [[.toggleSidebar, .toggleInspector, .toggleDrawer], [.inspectorFiles, .inspectorChanges, .inspectorGit, .findInFiles],
             [.quickOpen, .commandPalette, .sessions, .limits]]
        case .help: [[.shortcuts]]
        }
    }

    /// The groups that are menus of their own (the app menu is built by hand).
    static let menus: [ShortcutGroup] = [.chat, .tab, .view]
}

/// The menu's key equivalent for `sc`: shown only (`ShownKeysMenu`); "" for a command without a key.
func menuKeyEquivalent(_ sc: Shortcut) -> (key: String, mods: NSEvent.ModifierFlags) {
    let (mods, code, symbol) = sc.key
    guard code != .max else { return ("", []) }
    let special: [String: Int] = ["F2": NSF2FunctionKey, "Tab": 0x09, "←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey,
                                  "↑": NSUpArrowFunctionKey, "↓": NSDownArrowFunctionKey]
    if let scalar = special[symbol].flatMap(Unicode.Scalar.init) { return (String(Character(scalar)), mods) }
    return (symbol.lowercased(), mods)
}

/// A menu whose key equivalents are only shown. The key monitor matches keys by keyCode (any layout) and passes some on
/// on purpose (F2 to Monaco, keys under a sheet); the menu must never take them itself, or a key would run twice or wrongly.
final class ShownKeysMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// The menu of `group`: every item runs `action` on `target` with its `Shortcut` as `representedObject`.
@MainActor func shortcutMenu(_ group: ShortcutGroup, target: AnyObject, action: Selector) -> NSMenu {
    let menu = ShownKeysMenu(title: L10n.shortcutGroup(group))
    func item(_ sc: Shortcut, title: String) -> NSMenuItem {
        let (key, mods) = menuKeyEquivalent(sc)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        item.representedObject = sc
        return item
    }
    for (i, section) in group.sections.enumerated() {
        if i > 0 { menu.addItem(.separator()) }
        if let title = L10n.shortcutSubmenu(section) {
            let sub = ShownKeysMenu(title: title)
            for sc in section { sub.addItem(item(sc, title: L10n.shortcutMenuTitle(sc))) }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        } else {
            for sc in section { menu.addItem(item(sc, title: L10n.shortcutMenuTitle(sc))) }
        }
    }
    return menu
}

// MARK: Cheatsheet

/// A cheatsheet line: tabs 1…9 are one line.
struct CheatRow: Equatable, Identifiable {
    var title: String
    var keys: String
    var id: String { title + keys }
}

/// The cheatsheet (⌘/): every key of the table by group, filtered by `query` (title or keys, case-insensitive).
@MainActor func cheatsheet(query: String) -> [(group: ShortcutGroup, rows: [CheatRow])] {
    let q = query.trimmingCharacters(in: .whitespaces)
    return ShortcutGroup.allCases.compactMap { group in
        let rows = group.sections.flatMap { section -> [CheatRow] in
            if case .tab = section.first, let last = section.last {
                return [CheatRow(title: L10n.shortcutsTabs, keys: section[0].label + "…" + last.key.symbol)]
            }
            return section.filter { $0.key.code != .max }.map { CheatRow(title: L10n.shortcutMenuTitle($0, inCheatsheet: true), keys: $0.label) }
        }.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.keys.localizedCaseInsensitiveContains(q) }
        return rows.isEmpty ? nil : (group, rows)
    }
}

/// ⌘/ and «Справка → Сочетания клавиш»: search field on top, groups as the menus, Esc or «Готово» closes.
struct ShortcutsSheet: View {
    let onClose: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let groups = cheatsheet(query: query)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.command(.shortcuts))
            TextField("", text: $query)
                .focused($focused)
                .inputField(focused: focused, icon: .search, placeholder: query.isEmpty ? L10n.shortcutsSearch : nil)
                .padding(.top, Theme.sheetNameTop)
                .onAppear { focused = true }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        Text(L10n.shortcutsNothing)
                            .foregroundStyle(Theme.ui.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.sheetGap)
                    }
                    ForEach(groups, id: \.group) { group in
                        CardSection(title: L10n.shortcutGroup(group.group)) {
                            ForEach(group.rows) { row in
                                HStack(spacing: Theme.sheetButtonGap) {
                                    Text(verbatim: row.title).foregroundStyle(Theme.ui.text1)
                                    Spacer(minLength: Theme.sheetButtonGap)
                                    Text(verbatim: row.keys).font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text2)
                                }
                                .padding(.horizontal, Theme.Space.s3)
                                .frame(minHeight: Theme.Height.rowLarge)
                            }
                        }
                    }
                }
            }
            .frame(height: Theme.shortcutsListHeight)
            .padding(.top, Theme.sheetGap)
            SheetFooter {
                Button(L10n.shortcutsDone, action: onClose)
                    .buttonStyle(.hangar(.primary))
                    .keyboardShortcut(.defaultAction)
                    .background {
                        Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0)
                    }
            }
        }
        .sheetFrame()
    }
}
