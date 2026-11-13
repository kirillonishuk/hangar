import SwiftUI

/// Keys of the terminal find bar's tooltips (HD-159): ↩ and ⇧↩ as in Ghostty's own bar.
enum TerminalFindKey {
    static let next = "↩"
    static let prev = "⇧↩"
    static let close = "Esc"
}

/// «3 из 12», «– из 12» before a match is picked, «Нет совпадений»; nil while there is nothing to count (empty field, searching).
@MainActor func terminalFindCounter(needle: String, selected: Int?, total: Int?) -> String? {
    guard !needle.isEmpty, let total else { return nil }
    guard total > 0 else { return L10n.terminalFindNone }
    return L10n.terminalFindCounter(selected.map { String($0 + 1) } ?? "–", total)
}

/// The find bar's state for one terminal leaf; the leaf wires the closures to its surface.
@MainActor @Observable final class TerminalFind {
    var needle = "" { didSet { if needle != oldValue { needleChanged() } } }
    var total: Int?
    var selected: Int?
    /// Bumped by ⌘F while the bar is open: the field takes the keyboard again.
    var focusRequest = 0
    @ObservationIgnored var search: (String) -> Void = { _ in }
    @ObservationIgnored var navigate: (_ next: Bool) -> Void = { _ in }
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private var pending: DispatchWorkItem?

    var counter: String? { terminalFindCounter(needle: needle, selected: selected, total: total) }

    /// Short needles wait a moment (as Ghostty's bar): one or two letters match half the scrollback.
    private func needleChanged() {
        pending?.cancel()
        pending = nil
        let needle = self.needle
        guard !needle.isEmpty, needle.count < 3 else { return search(needle) }
        let work = DispatchWorkItem { [weak self] in self?.search(needle) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.terminalFindDelay, execute: work)
    }
}

/// The terminal find bar (HD-159): a strip in the pane header's look (`barPane`, `bg0`, line under it) on top of the
/// terminal — field, «N из M», ↑ ↓, ×. ↩ / ⇧↩ step, Esc closes and gives the keyboard back to the terminal.
struct TerminalFindBar: View {
    let model: TerminalFind
    @FocusState private var focused: Bool

    @MainActor static func hosted(_ model: TerminalFind) -> NSView {
        let view = NSHostingView(rootView: TerminalFindBar(model: model))
        view.sizingOptions = []
        view.safeAreaRegions = []
        return view
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.iconGap) {
                IconView(icon: .search, size: Theme.Icon.inline, tint: focused ? Theme.ui.text2 : Theme.ui.text3)
                TextField("", text: $model.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.ui.text0)
                    .focused($focused)
                    .overlay(alignment: .leading) {
                        if model.needle.isEmpty {
                            Text(verbatim: L10n.terminalFindPlaceholder).foregroundStyle(Theme.ui.text3).lineLimit(1).allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        model.navigate(!press.modifiers.contains(.shift))
                        return .handled
                    }
                    .onExitCommand { model.close() }
                    .onChange(of: model.focusRequest) { focused = true }
                    // Next turn: the bar has just been added to the window, focus set now is lost.
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .accessibilityLabel(L10n.terminalFindPlaceholder)
                Text(verbatim: model.counter ?? "").foregroundStyle(Theme.ui.text2).monospacedDigit().lineLimit(1)
                    .padding(.trailing, Theme.Space.s1)
                HStack(spacing: Theme.paneHeaderButtonGap) {
                    IconButton(icon: .chevronUp, help: L10n.terminalFindUp + " — " + TerminalFindKey.next) { model.navigate(true) }
                    IconButton(icon: .chevronDown, help: L10n.terminalFindDown + " — " + TerminalFindKey.prev) { model.navigate(false) }
                    IconButton(icon: .close, help: L10n.terminalFindClose + " — " + TerminalFindKey.close) { model.close() }
                }
            }
            .padding(.horizontal, Theme.paneHeaderPaddingH)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.ui.line).frame(height: 1)
        }
        .font(Theme.Typography.secondary.font())
        .background(Theme.ui.bg0)
    }
}
