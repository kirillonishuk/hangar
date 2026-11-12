import AppKit
import Observation
import SwiftUI

/// The «Сессия в архиве · Отменить» toast, or a plain message (a dead `hangar://` link, HD-088): one at a time, hides after
/// `delay` by a one-shot work item (no polling).
@MainActor @Observable final class ArchiveUndo {
    private(set) var taskId: UUID?
    /// A message without «Отменить»; nil while the archive toast (or nothing) is shown.
    private(set) var message: String?
    /// The message's own «Вернуть» (a reverted file, HD-156); nil — a plain message.
    private(set) var messageUndo: (() -> Void)?
    /// Set by the window: restores through `restoreArchivedTask` (it needs the window's alerts).
    @ObservationIgnored var onUndo: (UUID) -> Void = { _ in }
    @ObservationIgnored private var hide: DispatchWorkItem?
    /// The pointer is over the toast: no hide is scheduled until it leaves.
    @ObservationIgnored private var held = false
    @ObservationIgnored private let delay: TimeInterval
    /// Runs the hide item after the delay (tests run it by hand).
    @ObservationIgnored private let schedule: (TimeInterval, DispatchWorkItem) -> Void

    init(delay: TimeInterval = Theme.toastDuration,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.delay = delay
        self.schedule = schedule
    }

    /// A newer archive replaces the toast and restarts its timer.
    func show(_ id: UUID) {
        present(taskId: id, message: nil)
    }

    func show(message text: String, undo: (() -> Void)? = nil) {
        present(taskId: nil, message: text, undo: undo)
    }

    private func present(taskId id: UUID?, message text: String?, undo: (() -> Void)? = nil) {
        taskId = id
        message = text
        messageUndo = undo
        arm()
    }

    /// The pointer over the toast keeps it (§3.15), also across a newer toast; leaving restarts the full delay.
    func hold(_ on: Bool) {
        held = on
        guard taskId != nil || message != nil else { return }
        if on { hide?.cancel(); hide = nil } else { arm() }
    }

    private func arm() {
        hide?.cancel()
        hide = nil
        guard !held else { return }
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = item
        schedule(delay, item)
    }

    func dismiss() {
        hide?.cancel()
        hide = nil
        held = false  // the view goes away under the pointer: no hover-exit comes
        taskId = nil
        message = nil
        messageUndo = nil
    }

    /// Restores the archived task once; the toast goes away.
    func undo(_ restore: (UUID) -> Void) {
        guard let id = taskId else { return }
        dismiss()
        restore(id)
    }

    /// The message's «Вернуть» once; the toast goes away.
    func undoMessage() {
        guard let action = messageUndo else { return }
        dismiss()
        action()
    }
}

/// Bottom-centre of the chat area (§3.15): `bg2`, `line2`, `radius.popover`, level 1; 32 high, `body`, up to one
/// primary small button and «×». Takes no space while hidden; the pointer over it holds it. Worktree removals (HD-132)
/// stack above it in the same toast style.
struct UndoToastView: View {
    let undo: ArchiveUndo
    let removals: WorktreeRemovals
    let restore: (UUID) -> Void

    var body: some View {
        let rows = removals.visible
        if !rows.isEmpty || undo.message != nil || undo.taskId != nil {
            VStack(spacing: Theme.Space.s2) {
                ForEach(rows) { WorktreeRemovalToast(item: $0, removals: removals) }
                if undo.message != nil || undo.taskId != nil { undoToast }
            }
            // Room for the level-1 shadow: the hosting view is sized to its content.
            .padding(Theme.toastShadow.radius)
            .fixedSize()
        }
    }

    private var undoToast: some View {
        HStack(spacing: Theme.Space.s2) {
            if let message = undo.message {
                Text(message).foregroundStyle(Theme.ui.text1)
                if undo.messageUndo != nil {
                    Button { undo.undoMessage() } label: { ActionLabel(title: L10n.revertUndo, icon: .restore) }
                        .buttonStyle(.hangar(.primary, .small))
                        .help(L10n.revertUndo)
                }
            } else {
                Text(L10n.taskArchived).foregroundStyle(Theme.ui.text1)
                Button { undo.undo(restore) } label: { ActionLabel(title: L10n.undoArchive, icon: .restore) }
                    .buttonStyle(.hangar(.primary, .small))
                    .help(L10n.undoArchive)
            }
            IconButton(icon: .close, size: .small, help: L10n.close) { undo.dismiss() }
        }
        .toastChrome()
        .onHover { undo.hold($0) }
        .accessibilityElement(children: .contain)
    }
}

/// «Удаление копии «x»…» with a small spinner while the folder goes; failed — the alert glyph (`failed`), the reason in
/// the tooltip, «Повторить» (primary small), «Показать в Finder» (local) and «×». Stays until done or dismissed.
struct WorktreeRemovalToast: View {
    let item: WorktreeRemovals.Item
    let removals: WorktreeRemovals

    var body: some View {
        HStack(spacing: Theme.Space.s2) {
            if let failure = item.failure {
                IconView(icon: .alert, size: Theme.Icon.row, tint: Theme.ui.failed)
                Text(verbatim: L10n.removeCopyFailed(item.name)).foregroundStyle(Theme.ui.text1)
                    .help(failure)
                    .accessibilityHint(failure)
                Button(L10n.retry) { removals.retry(item.id) }
                    .buttonStyle(.hangar(.primary, .small))
                    .help(failure)
                if item.local {
                    IconButton(icon: .finder, size: .small, help: L10n.showInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                }
                IconButton(icon: .close, size: .small, help: L10n.close) { removals.dismiss(item.id) }
            } else {
                ProgressView().controlSize(.small)
                Text(verbatim: L10n.removingCopy(item.name)).foregroundStyle(Theme.ui.text2)
            }
        }
        .toastChrome(endsWithControl: item.failure != nil)
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// §3.15: 32 high, padding 12 (the trailing control centred), `bg2`, `line2`, `radius.popover`, level-1 shadow.
    /// `endsWithControl`: the trailing control sits as far from the edge as from the top; plain text keeps the 12.
    func toastChrome(endsWithControl: Bool = true) -> some View {
        font(Theme.Typography.body.font())
            .lineLimit(1)
            .padding(.leading, Theme.Space.s3)
            .padding(.trailing, endsWithControl ? (Theme.Height.rowLarge - Theme.Height.controlSmall) / 2 : Theme.Space.s3)
            .frame(height: Theme.Height.rowLarge)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.popover).fill(Theme.ui.bg2)
                .shadow(color: .black.opacity(Theme.toastShadow.opacity), radius: Theme.toastShadow.radius, y: Theme.toastShadow.y))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.popover).stroke(Theme.ui.line2, lineWidth: 1))
            .fixedSize()
    }
}
