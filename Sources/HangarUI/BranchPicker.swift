import AppKit
import Git
import SwiftUI

struct BranchPickerItem: Equatable {
    var branch: Branch
    var meta: Meta
    enum Meta: Equatable { case isDefault, task, age(Date) }
}

/// Case-insensitive substring filter; the default base first among remotes, the rest in `listBranches` order.
func branchPickerItems(_ branches: [Branch], query: String, defaultBase: String?,
                       taskBranches: Set<String>) -> (remote: [BranchPickerItem], local: [BranchPickerItem]) {
    let q = query.trimmingCharacters(in: .whitespaces)
    let items = branches
        .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        .map { b -> BranchPickerItem in
            if b.name == defaultBase { return BranchPickerItem(branch: b, meta: .isDefault) }
            if !b.isRemote, taskBranches.contains(b.name) { return BranchPickerItem(branch: b, meta: .task) }
            return BranchPickerItem(branch: b, meta: .age(b.lastCommit))
        }
    let remote = items.filter(\.branch.isRemote)
    return (remote.filter { $0.meta == .isDefault } + remote.filter { $0.meta != .isDefault },
            items.filter { !$0.branch.isRemote })
}

/// «только что» / «N мин назад» / «N ч назад» / «N дн назад».
@MainActor func ageLabel(since: Date, now: Date) -> String {
    let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
    if minutes < 1 { return L10n.justNow }
    if minutes < 60 { return L10n.minutesAgo(minutes) }
    if minutes < 24 * 60 { return L10n.hoursAgo(minutes / 60) }
    return L10n.daysAgo(minutes / (24 * 60))
}

/// `⎇ origin/main ▾` (a `.regular` popup button) → the menu: search, «Удалённые» / «Локальные» groups, ↑/↓ ↩ Esc and click.
struct BranchPicker: View {
    @Binding var selection: String?
    let branches: [Branch]
    let defaultBase: String?
    let taskBranches: Set<String>
    /// Extra first row that selects nil (project settings: «по умолчанию (origin/HEAD)»); nil = no such row.
    let defaultOption: String?

    var body: some View {
        PopupButton(title: selection ?? defaultOption ?? "—", icon: .branch, mono: selection != nil, size: .regular) {
            branchMenu(selection: selection, branches: branches, defaultBase: defaultBase, taskBranches: taskBranches,
                       defaultOption: defaultOption) { selection = $0 }
        }
        .fixedSize()
    }
}

/// The branch list as a search menu: the current choice checked and highlighted, a note on the right (default, a
/// session's branch, age).
@MainActor func branchMenu(selection: String?, branches: [Branch], defaultBase: String?, taskBranches: Set<String>,
                           defaultOption: String?, choose: @escaping (String?) -> Void) -> PopoverMenuContent {
    PopoverMenuContent(search: .init(placeholder: L10n.searchBranches, mono: true, highlightFirst: true), width: Theme.menuWidthWide) { query in
        let items = branchPickerItems(branches, query: query, defaultBase: defaultBase, taskBranches: taskBranches)
        var entries: [PopoverMenuEntry] = []
        if let defaultOption, query.trimmingCharacters(in: .whitespaces).isEmpty {
            entries.append(.item(PopoverMenuItem(title: defaultOption, checked: selection == nil) { choose(nil) }))
        }
        for (title, rows) in [(L10n.branchesRemote, items.remote), (L10n.branchesLocal, items.local)] where !rows.isEmpty {
            entries.append(.header(title))
            entries += rows.map { item in
                .item(PopoverMenuItem(title: item.branch.name, checked: item.branch.name == selection, note: branchMetaText(item.meta),
                                      mono: true) { choose(item.branch.name) })
            }
        }
        return entries
    }
}

@MainActor private func branchMetaText(_ meta: BranchPickerItem.Meta) -> String {
    switch meta {
    case .isDefault: L10n.branchDefault
    case .task: L10n.branchTask
    case .age(let date): ageLabel(since: date, now: Date())
    }
}

/// Search field that hands ↑/↓/↩/Esc to the list instead of the field editor (SwiftUI's TextField moves the caret);
/// focused when the popover opens.
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font = Theme.Typography.body.nsFont()
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = Theme.text0  // = Theme.ui.inputText
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.text3, .font: Theme.Input.nsFont(),  // = inputPlaceholder, prose (never mono)
        ])
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: Theme.text3, .font: Theme.Input.nsFont(),
            ])
        }
        if field.stringValue != text {
            field.stringValue = text
            // Set from outside (⇧⌘P puts «>»): the caret after it, not the whole text selected.
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerSearchField
        init(parent: PickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }

    private final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
                // Focus selects all: a preset «>» (⇧⌘P) would be replaced by the first typed letter, leaving commands.
                self.currentEditor()?.selectedRange = NSRange(location: (self.stringValue as NSString).length, length: 0)
                (self.currentEditor() as? NSTextView)?.insertionPointColor = Theme.accentText  // not the system accent
            }
        }
    }
}
