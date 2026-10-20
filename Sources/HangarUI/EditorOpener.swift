import Foundation
import Workspace

/// A path as one argument of Helix's command line (decision #44): `'…'`, else `` `…` ``, else `"…"`
/// (expands `%`, so only without `%`); nil → open in a new tab, where the shell quotes argv.
func helixQuoted(_ path: String) -> String? {
    // A control character (newline) would end or garble the pasted command line.
    guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
    if !path.contains("'") { return "'\(path)'" }
    if !path.contains("`") { return "`\(path)`" }
    if !path.contains("\""), !path.contains("%") { return "\"\(path)\"" }
    return nil
}

/// Typed after `:` one by one; nil when the path can't be quoted.
func helixCommands(path: String, line: Int?) -> [String]? {
    guard let quoted = helixQuoted(path) else { return nil }
    guard let line, line >= 1 else { return ["open \(quoted)"] }
    return ["open \(quoted)", "goto \(line)"]
}

enum EditorRoute: Equatable {
    /// A running Helix: Esc + `:open` (+ `:goto`).
    case sendKeys(tab: UUID, leaf: UUID)
    /// The leaf never started or has exited: point it at the file and (re)launch.
    case launch(tab: UUID, leaf: UUID)
    case newTab
}

/// The task's editor leaf: the active tab's focused leaf, else its first editor leaf, else the first one in tab order.
@MainActor func editorRoute(task: HangarTask, isHelix: Bool, quotable: Bool, isLive: (UUID) -> Bool) -> EditorRoute {
    guard isHelix, quotable else { return .newTab }
    func editors(_ tab: Tab) -> [Leaf] { tab.root.leaves.filter { $0.kind == .editor } }
    var target: (tab: UUID, leaf: UUID)?
    if let tab = task.tabs.first(where: { $0.id == task.activeTabId }) {
        let leaves = editors(tab)
        if let leaf = leaves.first(where: { $0.id == tab.focusedLeafId }) ?? leaves.first { target = (tab.id, leaf.id) }
    }
    if target == nil, let tab = task.tabs.first(where: { !editors($0).isEmpty }) { target = (tab.id, editors(tab)[0].id) }
    guard let target else { return .newTab }
    return isLive(target.leaf) ? .sendKeys(tab: target.tab, leaf: target.leaf) : .launch(tab: target.tab, leaf: target.leaf)
}
