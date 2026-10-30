import SwiftUI
import Workspace

/// The header of a split tab's pane (DESIGN «Сплиты») and of any editor (§3.5): kind icon, status dot, name (inline
/// rename; an editor — its file's path in the chat's folder); an editor's language server and «Миникарта» on the
/// right (what the status bar had, §6); in a split «⇱» and «×» on hover and on the focused pane, their space always
/// reserved. Reads its leaf by id, so a moved pane keeps its header.
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
            let split = if case .split = tab.root { true } else { false }
            content(split ? .leaf(task: loc.task, tab: loc.tab, leaf: leafId) : .tab(task: loc.task, tab: loc.tab), leaf: leaf,
                    taskId: loc.task, split: split, focused: !split || tab.focusedLeafId == leafId)
        }
    }

    /// `split` false: a lone editor's header — no moving, no pane buttons, the tab's menu.
    private func content(_ target: ActionTarget, leaf: Leaf, taskId: UUID, split: Bool, focused: Bool) -> some View {
        let renaming = app.renaming == target
        let state = app.displayState(ofLeaf: leaf.id, kind: leaf.kind)
        var hovered = hover
        #if DEBUG
        if app.debugHover == target { hovered = true }  // snapshots can't hover
        #endif
        let shown = split && (hovered || focused) && !renaming
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                IconView(icon: .of(leaf.kind), size: Theme.Icon.inline, tint: focused ? Theme.ui.text2 : Theme.ui.text3).padding(.trailing, Theme.Space.iconGap)
                // As tabs (`showsDot`): agents always, other panes only while something is going on.
                if state != .idle || leaf.kind == .claude || leaf.kind == .codex {
                    StatusDot(state: state).padding(.trailing, Theme.Space.iconGap).help(app.statusText(state, leaves: [leaf]))
                }
                if renaming {
                    RenameField(app: app, target: target).frame(maxWidth: Theme.tabRenameWidth)
                    Spacer(minLength: Theme.rowEndGap)
                } else {
                    let title = leaf.kind == .editor ? leaf.openFile.map { app.pathInChat($0, taskId: taskId) } : nil
                    Text(verbatim: title ?? app.paneTitle(leaf)).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            // Only this part drags (never the ⇱/× buttons), and not while renaming (the field keeps its own mouse).
            .simultaneousGesture(moveGesture, including: renaming || !split ? .subviews : .all)
            if leaf.kind == .editor { EditorHeaderItems(app: app, leaf: leaf) }
            if split { HStack(spacing: Theme.paneHeaderButtonGap) {
                PaneHeaderButton(icon: .popOut, help: L10n.detachPane) { Action.detachPane.perform(target, ctx()) }
                PaneHeaderButton(icon: .close, help: L10n.help(L10n.closePane, Action.closePane.shortcut(for: target, app: app))) {
                    Action.closePane.perform(target, ctx())
                }
            }
            .padding(.leading, Theme.rowEndGap)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown) }
        }
        .font(Theme.Typography.secondary.font())
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
        .pointingHand(split && !renaming && !dragging)  // a drag keeps its closed hand (PaneDragController)
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

/// An editor's language server state — a dot after the language, a click restarts it, the reason in the tooltip —
/// else just the language; then the «Миникарта» switch, lit while on (§3.5).
private struct EditorHeaderItems: View {
    let app: AppState
    let leaf: Leaf

    var body: some View {
        HStack(spacing: Theme.Space.s1) {
            if let lang = app.editorLanguage[leaf.id] {
                Button { app.restartLanguage(leafId: leaf.id) } label: {
                    HStack(spacing: Theme.Space.iconGap) {
                        Text(verbatim: lang.text)
                        Circle().fill(lang.level == .ready ? Theme.ui.done : lang.level == .busy ? Theme.ui.waiting : Theme.ui.text3)
                            .frame(width: Theme.Icon.statusDot, height: Theme.Icon.statusDot)
                    }
                }
                .buttonStyle(.hangar(.plain, .small))
                .help(lang.tooltip)
            } else if let language = editorStatusLabel(leaf) {
                Text(verbatim: language).foregroundStyle(Theme.ui.text3).padding(.horizontal, Theme.Space.s2)
            }
            let minimap = app.state.editorMinimap
            Button(L10n.editorMinimap) { app.perform { $0.editorMinimap.toggle() } }
                .buttonStyle(ChipStyle(on: minimap))
                .help(L10n.editorMinimap)
                .accessibilityAddTraits(minimap ? .isSelected : [])
        }
        .padding(.leading, Theme.rowEndGap)
    }
}

/// The active file's language (the ones with a language server), else nothing: the tab already says what it is.
@MainActor func editorStatusLabel(_ leaf: Leaf) -> String? {
    switch leaf.openFile.flatMap(TsMap.scriptKind) {
    case "TS", "TSX": "TypeScript"
    case "JS", "JSX": "JavaScript"
    default: leaf.openFile.flatMap(LspLanguage.of)?.name
    }
}
