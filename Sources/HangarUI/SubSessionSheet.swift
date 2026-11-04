import SwiftUI
import Workspace

/// «Новый подчат…» (#128, #131): a task for a parallel chat under this one, its agent and where it works (the chat's own
/// folder by default).
struct SubSessionSheet: View {
    let parentName: String
    /// A chat without a project has no repository: no copy (worktree).
    let canWorktree: Bool
    @State var agent: LeafKind
    let onStart: (_ prompt: String, _ agent: LeafKind, _ worktree: Bool) -> Void
    let onCancel: () -> Void

    @State private var prompt = ""
    @State private var worktree = false
    @FocusState private var focused: Bool

    private var ready: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.newSubChatTitle(parentName))
            CardSection {
                CardRow(label: L10n.subChatTask, first: true) {
                    TextField("", text: $prompt, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .inputField(focused: focused, multiline: true, placeholder: prompt.isEmpty ? L10n.subChatTaskPlaceholder : nil)
                }
                CardRow(label: L10n.subChatAgent) {
                    Segmented(selection: agent, options: [(LeafKind.claude, "Claude"), (LeafKind.codex, "Codex")]) { agent = $0 }
                }
                if canWorktree {
                    CardRow(label: L10n.whereToWork) {
                        Segmented(selection: worktree, options: [(false, L10n.subChatWhereSame), (true, L10n.whereCopy)]) { worktree = $0 }
                    }
                }
            }
            .padding(.top, Theme.sheetNameTop)
            Text(verbatim: L10n.subChatHint)
                .font(Theme.Typography.secondary.font())
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.sheetMessageTop)
            SheetFooter {
                Button(L10n.cancel, action: onCancel)
                    .buttonStyle(.hangar(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.subChatStart, action: start)
                    .buttonStyle(.hangar(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!ready)
            }
        }
        .sheetFrame()
        .onAppear { focused = true }
    }

    private func start() {
        guard ready else { return }
        onStart(prompt, agent, worktree)
    }
}
