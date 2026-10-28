import SwiftUI
import Workspace

/// The header of a split tab's pane (DESIGN «Сплиты»): kind icon, status dot, name (inline rename); «⇱» and «×» on
/// hover and on the focused pane, their space always reserved. Reads its leaf by id, so a moved pane keeps its header.
struct PaneHeader: View {
    let app: AppState
    /// Read on use: the window's services are set after the terminal area is made.
    let ctx: () -> ActionContext
    let leafId: UUID
    /// Gives the pane the keyboard (a click on the header).
    let focus: () -> Void
    @State private var hover = false

    /// For the AppKit leaf view (SwiftUI's `Tab` would clash with `Workspace.Tab` there).
    @MainActor static func hosted(app: AppState, ctx: @escaping () -> ActionContext, leafId: UUID, focus: @escaping () -> Void) -> NSView {
        let view = NSHostingView(rootView: PaneHeader(app: app, ctx: ctx, leafId: leafId, focus: focus))
        view.sizingOptions = []
        return view
    }

    var body: some View {
        if let loc = app.location(ofLeaf: leafId), let leaf = app.leaf(id: leafId),
           let tab = app.state.tasks.first(where: { $0.id == loc.task })?.tabs.first(where: { $0.id == loc.tab }) {
            content(.leaf(task: loc.task, tab: loc.tab, leaf: leafId), leaf: leaf, focused: tab.focusedLeafId == leafId)
        }
    }

    private func content(_ target: ActionTarget, leaf: Leaf, focused: Bool) -> some View {
        let renaming = app.renaming == target
        let state = app.displayState(ofLeaf: leaf.id, kind: leaf.kind)
        let shown = (hover || focused) && !renaming
        return HStack(spacing: 0) {
            IconView(icon: .of(leaf.kind), size: Theme.paneHeaderIcon, tint: focused ? Theme.ui.text2 : Theme.ui.text3).padding(.trailing, Theme.iconGap)
            // As tabs (`showsDot`): agents always, other panes only while something is going on.
            if state != .idle || leaf.kind == .claude || leaf.kind == .codex {
                StatusDot(state: state).padding(.trailing, Theme.iconGap).help(app.statusText(state, leaves: [leaf]))
            }
            if renaming {
                RenameField(app: app, target: target).frame(maxWidth: Theme.tabRenameWidth)
                Spacer(minLength: Theme.rowEndGap)
            } else {
                Text(verbatim: app.paneTitle(leaf)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Theme.paneHeaderButtonGap) {
                PaneHeaderButton(icon: .popOut, help: L10n.detachPane, active: focused) { Action.detachPane.perform(target, ctx()) }
                PaneHeaderButton(icon: .close, help: L10n.help(L10n.closePane, .closeTab), active: focused) {
                    Action.closePane.perform(target, ctx())
                }
            }
            .padding(.leading, Theme.rowEndGap)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
        }
        .font(.system(size: Theme.fontSize.counter))
        .foregroundStyle(focused ? Theme.ui.text2 : Theme.ui.text3)
        .padding(.horizontal, Theme.paneHeaderPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // One tap handler: a separate count-2 gesture would delay every single click.
        .onTapGesture {
            app.chromeClicked(target)
            app.focused(leafId: leaf.id)
            focus()
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { Action.rename.perform(target, ctx()) }
        }
        .popoverContextMenu { actionMenu(for: target, ctx: ctx()) }
        .pointingHand(!renaming)
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
    }
}

/// «⇱» / «×» of a pane header: a small icon with its own hover background (as a tab's `×`).
private struct PaneHeaderButton: View {
    let icon: Icon
    let help: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, active: active || hover, size: Theme.smallIconSize).padding(Theme.tabCloseInset)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.tabCloseRadius))
        .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        .help(help)
        .accessibilityLabel(help)
    }
}
