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
            // Room for «×» inside the box, past the text: the mouse way to cancel (Esc is the keyboard's).
            .padding(.trailing, Theme.smallIconSize + Theme.tabCloseInset * 2)
            .overlay(alignment: .trailing) { cancelButton }
            // Inline: the row's own font; the box grows outwards, so the text stays where the label was (no jump on F2).
            .modifier(InputField(focused: true, inline: true))
            .onAppear { focused = true }
            // A turn later: a press on «×» (which may take the focus) cancels before the lost focus commits.
            .onChange(of: focused) { _, isFocused in if !isFocused { DispatchQueue.main.async { finish(save: true) } } }
            .onDisappear { finish(save: true) }
    }

    private var cancelButton: some View {
        IconView(icon: .close, size: Theme.smallIconSize)
            .padding(Theme.tabCloseInset)
            .contentShape(Rectangle())
            // On press, not release: the press may end the field's editing, which commits.
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in finish(save: false) })
            .pointingHand()
            .help(L10n.escCancel)
            .accessibilityElement()
            .accessibilityLabel(L10n.cancel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { finish(save: false) }
    }

    private func finish(save: Bool) {
        guard !done else { return }
        done = true
        if save { app.commitRename(target, text) } else { app.cancelRename() }
    }
}
