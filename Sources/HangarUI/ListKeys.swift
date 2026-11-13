import SwiftUI

/// Keyboard in the inspector's lists (HD-161): Files, «Изменения», Search results.
enum ListKey { case up, down, left, right, enter }

/// A visible row as the keys see it: `parent` is the nearest visible folder row above it.
struct NavRow<ID: Hashable>: Equatable {
    var id: ID
    var parent: ID?
    var folder = false
    var expanded = false
}

enum NavResult<ID: Hashable>: Equatable {
    case select(ID), expand(ID), collapse(ID), open(ID), none
}

/// ↑↓ step (none chosen: the first / last row), → unfolds or goes to the first child, ← folds or goes to the parent,
/// ↩ opens a row or folds / unfolds a folder — as in Finder's and VS Code's trees.
func listNav<ID: Hashable>(_ rows: [NavRow<ID>], cursor: ID?, key: ListKey) -> NavResult<ID> {
    guard !rows.isEmpty else { return .none }
    guard let i = cursor.flatMap({ c in rows.firstIndex { $0.id == c } }) else {
        switch key {
        case .up: return .select(rows[rows.count - 1].id)
        case .down, .left, .right, .enter: return .select(rows[0].id)
        }
    }
    let row = rows[i]
    switch key {
    case .up: return i > 0 ? .select(rows[i - 1].id) : .none
    case .down: return i + 1 < rows.count ? .select(rows[i + 1].id) : .none
    case .right:
        guard row.folder else { return .none }
        if !row.expanded { return .expand(row.id) }
        return i + 1 < rows.count && rows[i + 1].parent == row.id ? .select(rows[i + 1].id) : .none
    case .left:
        if row.folder, row.expanded { return .collapse(row.id) }
        return row.parent.map { .select($0) } ?? .none
    case .enter:
        guard row.folder else { return .open(row.id) }
        return row.expanded ? .collapse(row.id) : .expand(row.id)
    }
}

/// The file tree's rows for `listNav`: a row's parent is its nearest ancestor among the visible rows.
func treeNavRows(_ rows: [TreeRow]) -> [NavRow<String>] {
    let ids = Set(rows.map(\.id))
    return rows.map { row in
        var parent = (row.id as NSString).deletingLastPathComponent
        while !parent.isEmpty, !ids.contains(parent) { parent = (parent as NSString).deletingLastPathComponent }
        return NavRow(id: row.id, parent: parent.isEmpty ? nil : parent, folder: row.entry.isDir, expanded: row.expanded)
    }
}

extension View {
    /// The list takes the keyboard on `focusRequest` (⌥⌘1 / ⌥⌘2 / ↓ from the search field) or a click; Esc hands it back.
    /// `served` remembers the request taken, so one made before the list exists is taken when it appears.
    func listKeys(focusRequest: Int, served: Binding<Int>, onKey: @escaping (ListKey) -> Void, onEscape: @escaping () -> Void) -> some View {
        modifier(ListKeysModifier(focusRequest: focusRequest, served: served, onKey: onKey, onEscape: onEscape))
    }
}

private struct ListKeysModifier: ViewModifier {
    let focusRequest: Int
    @Binding var served: Int
    let onKey: (ListKey) -> Void
    let onEscape: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
                let key: ListKey = switch press.key {
                case .upArrow: .up
                case .downArrow: .down
                case .leftArrow: .left
                case .rightArrow: .right
                default: .enter
                }
                onKey(key)
                return .handled
            }
            .onExitCommand { onEscape() }
            .onAppear(perform: take)
            .onChange(of: focusRequest) { take() }
    }

    private func take() {
        guard focusRequest > 0, focusRequest != served else { return }
        served = focusRequest
        // Next turn: a list that has just appeared (⌥⌘2 switching the segment) is not focusable yet.
        DispatchQueue.main.async { focused = true }
    }
}
