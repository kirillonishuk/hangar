import AppKit
import Observation
import SwiftUI

/// The «Сессия в архиве · Отменить» toast, or a plain message (a dead `hangar://` link, #88): one at a time, hides after
/// `delay` by a one-shot work item (no polling).
@MainActor @Observable final class ArchiveUndo {
    private(set) var taskId: UUID?
    /// A message without «Отменить»; nil while the archive toast (or nothing) is shown.
    private(set) var message: String?
    /// Set by the window: restores through `restoreArchivedTask` (it needs the window's alerts).
    @ObservationIgnored var onUndo: (UUID) -> Void = { _ in }
    @ObservationIgnored private var hide: DispatchWorkItem?
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

    func show(message text: String) {
        present(taskId: nil, message: text)
    }

    private func present(taskId id: UUID?, message text: String?) {
        hide?.cancel()
        taskId = id
        message = text
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = item
        schedule(delay, item)
    }

    func dismiss() {
        hide?.cancel()
        hide = nil
        taskId = nil
        message = nil
    }

    /// Restores the archived task once; the toast goes away.
    func undo(_ restore: (UUID) -> Void) {
        guard let id = taskId else { return }
        dismiss()
        restore(id)
    }
}

/// Bottom-centre of the task area (DESIGN «Тост»: radius 12). Takes no space while hidden.
struct UndoToastView: View {
    let undo: ArchiveUndo
    let restore: (UUID) -> Void
    @State private var hover = false

    var body: some View {
        if let message = undo.message {
            Text(message).foregroundStyle(Theme.ui.text)
                .font(.system(size: Theme.fontSize.base))
                .padding(.horizontal, Theme.toastPaddingH)
                .padding(.vertical, Theme.toastPaddingV + Theme.buttonPaddingV)
                .background(RoundedRectangle(cornerRadius: Theme.sheetRadius).fill(Theme.ui.sheet))
                .overlay(RoundedRectangle(cornerRadius: Theme.sheetRadius).stroke(Theme.ui.sheetBorder, lineWidth: 1))
                .fixedSize()
        } else if undo.taskId != nil {
            HStack(spacing: Theme.toastGap) {
                Text(L10n.taskArchived).foregroundStyle(Theme.ui.text)
                Button { undo.undo(restore) } label: {
                    Text(L10n.undoArchive)
                        .foregroundStyle(hover ? Theme.ui.textStrong : Theme.ui.accentText)
                        .padding(.vertical, Theme.buttonPaddingV)
                        .padding(.horizontal, Theme.toastButtonPaddingH)
                        .background(RoundedRectangle(cornerRadius: Theme.buttonRadius).fill(hover ? Theme.ui.hoverStrong : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
            }
            .font(.system(size: Theme.fontSize.base))
            .padding(.leading, Theme.toastPaddingH)
            .padding(.trailing, Theme.toastPaddingV)
            .padding(.vertical, Theme.toastPaddingV)
            .background(RoundedRectangle(cornerRadius: Theme.sheetRadius).fill(Theme.ui.sheet))
            .overlay(RoundedRectangle(cornerRadius: Theme.sheetRadius).stroke(Theme.ui.sheetBorder, lineWidth: 1))
            .fixedSize()
            .accessibilityElement(children: .contain)
        }
    }
}
