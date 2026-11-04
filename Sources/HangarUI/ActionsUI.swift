import SwiftUI
import Workspace

/// The chat's actions as menu items (#133): each runs (or restarts) its action; running ones get «работает» and a stop
/// item; «Настроить действия…» last. The toolbar's run menu and the chat's context menu show the same list.
@MainActor func actionMenuEntries(app: AppState, task: HangarTask, edit: Bool = true) -> [PopoverMenuEntry] {
    let actions = app.actions(of: task)
    let running = app.runningActions(of: task)
    let primary = app.primaryAction(of: task)?.name
    var entries: [PopoverMenuEntry] = actions.map { a in
        let isRunning = running.contains { $0.name == a.name }
        return .item(PopoverMenuItem(title: a.name, icon: .play,
                                     shortcut: !isRunning && a.name == primary && app.selectedTask?.id == task.id ? Shortcut.runAction.label : nil,
                                     note: isRunning ? L10n.actionRunningNote : a.source == .repo ? L10n.actionFromRepo : nil,
                                     help: a.action.command) {
            app.runAction(a.name, taskId: task.id)
        })
    }
    if !running.isEmpty {
        entries.append(.separator)
        entries += running.map { r in .item(PopoverMenuItem(title: L10n.actionStop(r.name), icon: .stop) { app.stopAction(r.leaf) }) }
    }
    if edit {
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item(PopoverMenuItem(title: L10n.actionsEdit, icon: .settings) { app.editActions?(task.projectId) }))
    }
    return entries
}

/// The toolbar's run button (design system §3.1, #133), right of the branch button and only while the chat's project has
/// actions: «▶ <last action>» runs it (⌘R), the chevron opens the list. A `control.regular` box with a `line2` border
/// split by a `line2` divider; each half has its own hover.
struct RunActionButton: View {
    let app: AppState
    let task: HangarTask
    let action: ResolvedAction
    @State private var hoverRun = false
    @State private var hoverMenu = false
    @State private var anchor = MenuAnchor()

    private func showMenu() {
        let task = app.state.tasks.first { $0.id == task.id } ?? task  // as it is now (its action leaves are renewed on restarts)
        PopoverMenu.show(actionMenuEntries(app: app, task: task), below: anchor.view)
        Task { await app.loadRepoActions(task) }  // the next opening has the file as it is now
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        HStack(spacing: 0) {
            Button { app.runAction(action.name, taskId: task.id) } label: {
                HStack(spacing: Theme.Space.iconGap) {
                    IconView(icon: .play, size: Theme.Icon.row)
                    Text(verbatim: action.name)
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(Theme.ui.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: Theme.runActionNameMax, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)  // hugs a short name, cuts a long one at the max
                }
                .padding(.leading, Theme.Space.s2)
                .padding(.trailing, Theme.Space.s2)
                .frame(maxHeight: .infinity)
                .background(hoverRun ? Theme.ui.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverRun = $0 }
            .help(L10n.help(L10n.actionRun(action.name), .runAction))
            .accessibilityLabel(L10n.actionRun(action.name))
            Rectangle().fill(Theme.ui.line2).frame(width: 1)
            Button(action: showMenu) {
                IconView(icon: .chevronDown, size: Theme.Icon.inline)
                    .frame(width: Theme.Height.controlSmall)
                    .frame(maxHeight: .infinity)
                    .background(hoverMenu ? Theme.ui.hover : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MenuAnchorView(anchor: anchor))
            .onHover { hoverMenu = $0 }
            .help(L10n.actionsMenuHelp)
            .accessibilityLabel(L10n.actionsMenuHelp)
        }
        .frame(height: Theme.Height.controlRegular)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.ui.line2, lineWidth: 1))
        .pointingHand()
        #if DEBUG
        .onAppear { debugRunMenuOpen = showMenu }
        .onChange(of: task.id) { debugRunMenuOpen = showMenu }
        #endif
    }
}

#if DEBUG
/// Debug channel `runMenu`: as a click on the toolbar run button's chevron.
@MainActor var debugRunMenuOpen: (() -> Void)?
#endif
