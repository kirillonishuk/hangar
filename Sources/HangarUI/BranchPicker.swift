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

/// ↑/↓ over the visible rows (both sections as one list), clamped at the ends; an unknown or nil highlight
/// lands on the first row.
func movedHighlight(_ current: String?, by delta: Int, in ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let i = ids.firstIndex(of: current) else { return ids[0] }
    return ids[min(max(i + delta, 0), ids.count - 1)]
}

/// `⎇ origin/main ▾` → popover: search, `remote` / `local` sections, ↑/↓ ↩ Esc and click.
struct BranchPicker: View {
    @Binding var selection: String?
    let branches: [Branch]
    let defaultBase: String?
    let taskBranches: Set<String>
    /// Extra first row that selects nil (project settings: «по умолчанию (origin/HEAD)»); nil = no such row.
    let defaultOption: String?

    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Theme.pickGap) {
                IconView(icon: .branch, size: Theme.smallIconSize)
                Text(selection ?? defaultOption ?? "—")
                    .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                    .foregroundStyle(Theme.ui.text0)
                IconView(icon: .chevronDown, size: Theme.pickChevronSize)
            }
            .padding(.vertical, Theme.pickPaddingV)
            .padding(.horizontal, Theme.pickPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.pickRadius).fill(Theme.ui.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.pickRadius)
                .stroke(open ? Theme.ui.accent : Theme.ui.line2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .pointingHand()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BranchListView(selection: $selection, branches: branches, defaultBase: defaultBase,
                       taskBranches: taskBranches, defaultOption: defaultOption) { open = false }
        }
    }
}

struct BranchListView: View {
    @Binding var selection: String?
    let branches: [Branch]
    let defaultBase: String?
    let taskBranches: Set<String>
    let defaultOption: String?
    let close: () -> Void

    @State private var query = ""
    @State private var highlight: String?

    /// Row id of `defaultOption` (no branch has an empty name).
    private static let defaultId = ""

    private var items: (remote: [BranchPickerItem], local: [BranchPickerItem]) {
        branchPickerItems(branches, query: query, defaultBase: defaultBase, taskBranches: taskBranches)
    }

    private var showsDefault: Bool { defaultOption != nil && query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func ids(_ items: (remote: [BranchPickerItem], local: [BranchPickerItem])) -> [String] {
        (showsDefault ? [Self.defaultId] : []) + (items.remote + items.local).map(\.branch.name)
    }

    var body: some View {
        let items = items
        let ids = ids(items)
        VStack(spacing: 0) {
            PickerSearchField(text: $query, placeholder: L10n.searchBranches,
                              onMove: { highlight = movedHighlight(highlight, by: $0, in: ids) },
                              onSubmit: { if let highlight { choose(highlight) } },
                              onCancel: close)
                .inputField(focused: true)  // the list's keys go through it: always the focused one
                .padding(.vertical, Theme.dropdownSearchPaddingV)
                .padding(.horizontal, Theme.dropdownPaddingH)
            if !ids.isEmpty {
                Rectangle().fill(Theme.ui.line2).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if showsDefault, let defaultOption { row(Self.defaultId, defaultOption, meta: nil) }
                            section(L10n.branchesRemote, items.remote)
                            section(L10n.branchesLocal, items.local)
                        }
                    }
                    .frame(height: min(listHeight(items), Theme.dropdownListMaxHeight))
                    .onChange(of: highlight) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(width: Theme.dropdownWidth)
        .background(Theme.ui.bg2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.dropdownRadius))
        .onAppear { highlight = ids.contains(selection ?? Self.defaultId) ? (selection ?? Self.defaultId) : ids.first }
        .onChange(of: query) { highlight = self.ids(self.items).first }
    }

    private func listHeight(_ items: (remote: [BranchPickerItem], local: [BranchPickerItem])) -> CGFloat {
        let rows = items.remote.count + items.local.count + (showsDefault ? 1 : 0)
        let sections = (items.remote.isEmpty ? 0 : 1) + (items.local.isEmpty ? 0 : 1)
        return CGFloat(rows) * Theme.dropdownRowHeight + CGFloat(sections) * Theme.dropdownSectionHeight
    }

    @ViewBuilder private func section(_ title: String, _ rows: [BranchPickerItem]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .textCase(.uppercase)
                .tracking(Theme.fontSize.counter * Theme.fontSize.projectTracking)
                .font(.system(size: Theme.fontSize.counter))
                .foregroundStyle(Theme.ui.text3)
                .frame(maxWidth: .infinity, minHeight: Theme.dropdownSectionHeight, alignment: .bottomLeading)
                .padding(.horizontal, Theme.dropdownPaddingH)
            ForEach(rows, id: \.branch.name) { item in row(item.branch.name, item.branch.name, meta: item.meta) }
        }
    }

    private func row(_ id: String, _ title: String, meta: BranchPickerItem.Meta?) -> some View {
        let on = highlight == id
        return HStack(spacing: Theme.dropdownItemGap) {
            Text(title)
                .font(.system(size: Theme.fontSize.sheetRow, design: .monospaced))
                .foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let meta {
                Text(metaText(meta)).font(.system(size: Theme.fontSize.counter)).foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text3)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.dropdownPaddingH)
        .frame(height: Theme.dropdownRowHeight)
        .background(on ? Theme.ui.selectedFocus : .clear)
        .contentShape(Rectangle())
        .onHover { if $0 { highlight = id } }
        .onTapGesture { choose(id) }
        .pointingHand()
        .id(id)
    }

    private func metaText(_ meta: BranchPickerItem.Meta) -> String {
        switch meta {
        case .isDefault: L10n.branchDefault
        case .task: L10n.branchTask
        case .age(let date): ageLabel(since: date, now: Date())
        }
    }

    private func choose(_ id: String) {
        selection = id == Self.defaultId ? nil : id
        close()
    }
}

/// Search field that hands ↑/↓/↩/Esc to the list instead of the field editor (SwiftUI's TextField moves the caret);
/// focused when the popover opens.
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font = Theme.Input.nsFont(mono: true)
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
