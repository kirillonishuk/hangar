import SwiftUI
import Workspace

/// «Новый подчат…» (#127): a task for a separate chat under this one, its agent, where it works and where its result goes.
struct SubSessionSheet: View {
    let parentName: String
    /// A chat without a project has no repository: no copy (worktree).
    let canWorktree: Bool
    @State var agent: LeafKind
    let onStart: (_ prompt: String, _ agent: LeafKind, _ worktree: Bool, _ delivery: SubDelivery) -> Void
    let onCancel: () -> Void

    @State private var prompt = ""
    @State private var worktree = false
    @State private var delivery = SubDelivery.parent
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
                        Segmented(selection: worktree, options: [(false, L10n.whereFolder), (true, L10n.whereCopy)]) { worktree = $0 }
                    }
                }
                CardRow(label: L10n.subChatDeliver) {
                    Segmented(selection: delivery, options: [(SubDelivery.parent, L10n.subChatDeliverParent),
                                                             (SubDelivery.notify, L10n.subChatDeliverNotify)]) { delivery = $0 }
                }
            }
            .padding(.top, Theme.sheetNameTop)
            Text(verbatim: delivery == .parent ? L10n.subChatDeliverParentHint : L10n.subChatDeliverNotifyHint)
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
        onStart(prompt, agent, worktree, delivery)
    }
}
