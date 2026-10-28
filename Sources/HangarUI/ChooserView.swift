import SwiftUI
import Workspace

/// What a chooser pane (⌘D / ⇧⌘D) offers.
func chooserChoices() -> [LeafKind] { [.claude, .codex, .shell, .editor] }

/// The chooser's «Редактор» while the tab has a free editor slot.
func chooserEditorEnabled(_ tab: Workspace.Tab) -> Bool { tab.editorCount < Workspace.Tab.maxEditorPanes }

/// A chooser pane: «Продолжить» and the kind buttons, centred on the pane's own background; the pane header names it.
struct ChooserView: View {
    let app: AppState
    let leafId: UUID
    /// A click on the empty pane gives it the keyboard (↩ / Esc).
    let focus: () -> Void

    @MainActor static func hosted(app: AppState, leafId: UUID, focus: @escaping () -> Void) -> NSView {
        let view = NSHostingView(rootView: ChooserView(app: app, leafId: leafId, focus: focus))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        let loc = app.location(ofLeaf: leafId)
        let tab = loc.flatMap { l in app.state.tasks.first { $0.id == l.task }?.tabs.first { $0.id == l.tab } }
        KindChoiceButtons(kinds: chooserChoices(), disabled: tab.map(chooserEditorEnabled) == false ? [.editor] : [], shellHint: "↩") { kind in
            if kind == .editor { app.onChooseEditor?(leafId) } else { app.chooseKind(leafId, kind) }
        }
        .aboveCentered {
            if let task = loc?.task { ContinueList(app: app, taskId: task) { app.chooseConversation(leafId, $0) } }
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
    }
}
