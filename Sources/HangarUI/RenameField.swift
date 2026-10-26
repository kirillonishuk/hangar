import SwiftUI

/// Inline rename (F2 / double-click): ↩ saves, Esc cancels, losing focus saves. Blank text keeps the old name.
struct RenameField: View {
    let app: AppState
    let target: ActionTarget
    @State private var text: String
    @State private var done = false
    @FocusState private var focused: Bool

    init(app: AppState, target: ActionTarget) {
        self.app = app
        self.target = target
        _text = State(initialValue: app.name(of: target))
    }

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            // Inline: the row's own font; the box grows outwards, so the text stays where the label was (no jump on F2).
            .modifier(InputField(focused: true, inline: true))
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in if !isFocused { finish(save: true) } }
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard !done else { return }
        done = true
        if save { app.commitRename(target, text) } else { app.cancelRename() }
    }
}
