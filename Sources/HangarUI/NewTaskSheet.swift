import SwiftUI

/// Stage 1 new-task sheet (no worktree rows): name + optional first message for the default agent.
struct NewTaskSheet: View {
    let projectName: String
    let agentName: String
    let onCreate: (_ name: String, _ message: String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var message = ""
    @FocusState private var focus: Field?
    private enum Field { case name, message }

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.statusDot) {
                Text("Новая задача")
                    .font(.system(size: Theme.fontSize.sheetTitle, weight: .semibold))
                    .foregroundStyle(Theme.ui.sheetText)
                Text(projectName).font(.system(size: Theme.fontSize.base)).foregroundStyle(Theme.ui.text3)
            }
            .padding(.top, Theme.sheetHeaderTop)
            .padding(.bottom, Theme.sheetHeaderBottom)

            TextField("", text: $name, prompt: Text("название задачи").foregroundStyle(Theme.ui.text3))
                .font(.system(size: Theme.fontSize.taskName, design: .monospaced))
                .focused($focus, equals: .name)
                .onSubmit { focus = .message }
                .modifier(SheetField(focused: focus == .name))
                .padding(.top, Theme.sheetNameTop)

            TextField("", text: $message, prompt: Text("Первое сообщение для \(agentName) (необязательно)…")
                .foregroundStyle(Theme.ui.text3), axis: .vertical)
                .font(.system(size: Theme.fontSize.sheetRow))
                .lineLimit(2...8)
                .focused($focus, equals: .message)
                .frame(minHeight: Theme.messageMinHeight - 2 * Theme.fieldPaddingV, alignment: .topLeading)
                .modifier(SheetField(focused: focus == .message))
                .padding(.top, Theme.sheetGap)

            HStack(spacing: Theme.statusDot) {
                Text("esc — отмена").font(.system(size: Theme.fontSize.tab)).foregroundStyle(Theme.ui.text3)
                Spacer(minLength: 0)
                Button("Отмена", action: onCancel)
                    .buttonStyle(SheetButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Создать ⌘↩") { if canCreate { onCreate(name, message) } }
                    .buttonStyle(SheetButton(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : Theme.disabledButtonOpacity)
            }
            .padding(.vertical, Theme.sheetFooterPaddingV)
        }
        .padding(.horizontal, Theme.sheetPaddingH)
        .frame(width: Theme.sheetWidth)
        .font(.system(size: Theme.fontSize.sheetRow))
        .background(Theme.ui.sheet)
        .onAppear { focus = .name }
    }
}

/// Field: `field` background, `control` border; focused → `accent` border + 3 pt ring (DESIGN.md).
private struct SheetField: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.ui.sheetText)
            .padding(.vertical, Theme.fieldPaddingV)
            .padding(.horizontal, Theme.fieldPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.fieldRadius).fill(Theme.ui.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius)
                .stroke(focused ? Theme.ui.accent : Theme.ui.control, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius + Theme.focusRing / 2)
                .stroke(Theme.ui.accent.opacity(focused ? Theme.focusRingOpacity : 0), lineWidth: Theme.focusRing)
                .padding(-Theme.focusRing / 2 - 1))
    }
}

private struct SheetButton: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Theme.ui.selectionText : Theme.ui.sheetText)
            .padding(.vertical, Theme.buttonPaddingV)
            .padding(.horizontal, Theme.buttonPaddingH)
            .background(RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(primary ? Theme.ui.primary : Theme.ui.button))
            .opacity(configuration.isPressed ? Theme.pressedOpacity : 1)
    }
}
