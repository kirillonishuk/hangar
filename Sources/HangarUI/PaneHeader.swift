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
    @State private var dragging = false
    /// True while the drag gesture lives; its reset without `onEnded` is a cancel.
    @GestureState private var pressed = false

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
        var hovered = hover
        #if DEBUG
        if app.debugHover == target { hovered = true }  // snapshots can't hover
        #endif
        let shown = (hovered || focused) && !renaming
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
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
            }
            .contentShape(Rectangle())
            // Only this part drags (never the ⇱/× buttons), and not while renaming (the field keeps its own mouse).
            .simultaneousGesture(moveGesture, including: renaming ? .subviews : .all)
            HStack(spacing: Theme.paneHeaderButtonGap) {
                PaneHeaderButton(icon: .popOut, help: L10n.detachPane) { Action.detachPane.perform(target, ctx()) }
                PaneHeaderButton(icon: .close, help: L10n.help(L10n.closePane, Action.closePane.shortcut(for: target, app: app))) {
                    Action.closePane.perform(target, ctx())
                }
            }
            .padding(.leading, Theme.rowEndGap)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
        }
        .font(Theme.Typography.caption.font())
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
        .onChange(of: pressed) { _, live in
            // Next turn: a normal end has run `onEnded` by then (whatever order SwiftUI resets the state in).
            guard !live else { return }
            DispatchQueue.main.async {
                guard dragging else { return }
                dragging = false
                app.paneDragCancelled?()
            }
        }
        .pointingHand(!renaming && !dragging)  // a drag keeps its closed hand (PaneDragController)
        .onHover { h in hover = h }
    }
}

extension PaneHeader {
    /// Past `Theme.dragThreshold` the pane follows the pointer to another pane's edge or into the tab bar (splits spec §2).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: Theme.dragThreshold, coordinateSpace: .global)
            .updating($pressed) { _, pressed, _ in pressed = true }
            .onChanged { value in
                dragging = true
                _ = app.paneDragMoved?(.leaf(leafId), windowPoint(NSApp.currentEvent) ?? value.location)
            }
            .onEnded { _ in
                guard dragging else { return }
                dragging = false
                _ = app.paneDragEnded?(.leaf(leafId))
            }
    }
}

/// «⇱» / «×» of a pane header: a small icon with its own hover background (as a tab's `×`).
private struct PaneHeaderButton: View {
    let icon: Icon
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, active: hover, size: Theme.smallIconSize).padding(Theme.tabCloseInset)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.tabCloseRadius))
        .onHover { h in hover = h }
        .help(help)
        .accessibilityLabel(help)
    }
}
