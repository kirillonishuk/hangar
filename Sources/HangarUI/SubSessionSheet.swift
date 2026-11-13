import SwiftUI
import Workspace

/// «Новый подчат…» (HD-128, HD-131): a task for a parallel chat under this one, its agent and where it works (the chat's own
/// folder by default). Laid out as «Новый чат» (§3.14, HD-164): plain fields, «Где работать» as the same two options.
struct SubSessionSheet: View {
    let parentName: String
    /// A chat without a project has no repository: no copy (worktree).
    let canWorktree: Bool
    @State var agent: LeafKind
    let onStart: (_ prompt: String, _ agent: LeafKind, _ worktree: Bool) -> Void
    let onCancel: () -> Void

    @State private var prompt = ""
    @State private var worktree = false
    @FocusState private var focus: Field?
    private enum Field { case task, place }

    private var ready: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.newSubChatTitle(parentName))
            SheetFields {
                SheetField(label: L10n.subChatTask, note: L10n.subChatHint) {
                    TextField("", text: $prompt, axis: .vertical)
                        .lineLimit(Theme.promptLines)
                        .focused($focus, equals: .task)
                        .inputField(focused: focus == .task, multiline: true, placeholder: prompt.isEmpty ? L10n.subChatTaskPlaceholder : nil)
                }
                SheetField(label: L10n.subChatAgent) {
                    AgentSegment(agent: agent) { agent = $0 }
                }
                if canWorktree {
                    SheetField(label: L10n.whereToWork) {
                        WhereOptions(folderTitle: L10n.subChatWhereSame, folderDetail: AttributedString(L10n.subChatWhereSameHint),
                                     copyDetail: L10n.whereCopyHint, worktree: worktree, focused: focus == .place) { worktree = $0 }
                            .focused($focus, equals: .place)
                    }
                }
            }
            SheetFooter {
                // Why «Запустить» is off: the subchat starts from its task.
                if !ready {
                    Text(verbatim: L10n.subChatNeedsTask).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                }
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
        .onAppear { focus = .task }
    }

    private func start() {
        guard ready else { return }
        onStart(prompt, agent, worktree)
    }
}
