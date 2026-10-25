import SwiftUI
import Workspace

/// Rail label: parts split on `-`, `_`, `.`, whitespace and lower→Upper (camelCase) boundaries;
/// first letters of the first two parts, uppercased ("frontend-cd" → "FC", "shopApi" → "SA", "refactor" → "R").
func monogram(_ name: String) -> String {
    var parts: [String] = []
    var current = ""
    var previousLower = false
    for ch in name {
        if ch.isWhitespace || "-_.".contains(ch) {
            if !current.isEmpty { parts.append(current); current = "" }
            previousLower = false
            continue
        }
        if ch.isUppercase, previousLower, !current.isEmpty { parts.append(current); current = "" }
        current.append(ch)
        previousLower = ch.isLowercase
    }
    if !current.isEmpty { parts.append(current) }
    let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "?" : letters.joined()
}

/// Index among the other items (the list without the dragged one) where the dragged item's center lands.
func dropIndex(heights: [CGFloat], from: Int, dy: CGFloat) -> Int {
    var top: CGFloat = 0
    var centers: [CGFloat] = []
    for h in heights { centers.append(top + h / 2); top += h }
    let dragged = centers[from] + dy
    return centers.indices.filter { $0 != from && centers[$0] < dragged }.count
}

struct SidebarView: View {
    let app: AppState
    let ctx: ActionContext
    /// Row being reordered (task within its group, or project) and its vertical translation.
    @State private var drag: (target: ActionTarget, dy: CGFloat)?

    private var collapsed: Bool { app.state.sidebarCollapsed }

    var body: some View {
        GeometryReader { geo in
            // While collapsed or animating, lay out at the expanded width and clip, so text never reflows.
            let width = collapsed || app.sidebarAnimating ? max(geo.size.width, CGFloat(app.state.sidebarWidth)) : geo.size.width
            // Row highlights keep their inset from the visible edges, also while laid out wider than shown.
            let inset = collapsed ? Theme.railInset : Theme.rowInset
            VStack(spacing: 0) {
                Color.clear.frame(height: Theme.trafficLightsHeight).background(WindowDragArea())
                newTaskButton(visibleWidth: geo.size.width, inset: inset)
                sessionsRow
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !app.state.attentionOnly { pinnedSection }
                        hostsSection
                        projectsSection
                    }
                    .padding(.bottom, Theme.sectionGap)
                }
                .scrollIndicators(collapsed ? .never : .automatic)
                bottomBar
            }
            .environment(\.rowHighlight, RowHighlight(leading: inset, trailing: width - geo.size.width + inset, radius: Theme.rowRadius))
            .frame(width: width, alignment: .leading)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .environment(\.hoverPalette, .sidebar)
        .background(Theme.ui.sidebar)
        .ignoresSafeArea()
    }

    /// Debug snapshots: the row drawn as hovered (`debug hover …`).
    private func forcedHover(_ target: ActionTarget) -> Bool {
        #if DEBUG
        app.debugHover == target
        #else
        false
        #endif
    }

    // MARK: Top

    /// Filled full-width button; the fill is inset so the `+` keeps the shared marker x.
    private func newTaskButton(visibleWidth: CGFloat, inset: CGFloat) -> some View {
        Button { ctx.newTask(nil) } label: {
            GutterRow(collapsed: collapsed, trailing: Theme.rowEndTrailing) {
                IconView(icon: .add, active: true)
            } expanded: {
                HStack(spacing: 0) {
                    Text(L10n.newTask).foregroundStyle(Theme.ui.textStrong)
                    Spacer(minLength: 0)
                    ShortcutHint(text: Shortcut.newTask.label)
                }
            } rail: { EmptyView() }
            .contentShape(Rectangle())
        }
        .buttonStyle(FilledRowStyle(width: visibleWidth - 2 * inset, inset: inset, radius: Theme.rowRadius))
        .padding(.top, Theme.newTaskTop)
        .padding(.bottom, Theme.newTaskBottom)
        .help(L10n.help(L10n.newTaskHelp, .newTask))
    }

    /// «Сессии ⌘Y»: the history of sessions, closed ones included (the АРХИВ section's successor).
    private var sessionsRow: some View {
        HoverRow(selected: app.sessionsViewVisible, action: app.showSessionsView) { _ in
            GutterRow(collapsed: collapsed, trailing: Theme.rowEndTrailing) {
                IconView(icon: .history, active: app.sessionsViewVisible)
            } expanded: {
                HStack(spacing: 0) {
                    Text(L10n.sessionsView)
                        .foregroundStyle(app.sessionsViewVisible ? Theme.ui.selectionText : Theme.ui.textRow)
                    Spacer(minLength: 0)
                    ShortcutHint(text: Theme.sessionsShortcutLabel)
                }
            } rail: { EmptyView() }
        }
        .help("\(L10n.sessionsViewHelp) — \(Theme.sessionsShortcutLabel)")
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedSection: some View {
        let pinned = app.pinnedTasks
        if !pinned.isEmpty {
            SectionHeader(title: L10n.sectionPinned, collapsed: collapsed)
            ForEach(pinned) { task in pinnedRow(task) }
        }
    }

    /// One line, 32: dot, name, project (`text3`); pin and «⋯» on hover.
    private func pinnedRow(_ task: HangarTask) -> some View {
        let selected = task.id == app.state.selectedTaskId
        let target = ActionTarget.task(task.id)
        let dot = app.displayState(of: task)
        return HoverRow(selected: selected, action: {
                            clicked(target)
                            app.select(taskId: task.id)
                        },
                        doubleAction: { Action.rename.perform(target, ctx) },
                        forceHover: forcedHover(target)) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.sessionRowTrailing, railReplacesMarker: true) {
                StatusDot(state: dot)
            } expanded: {
                HStack(spacing: Theme.rowEndGap) {
                    if app.renaming == target {
                        RenameField(app: app, target: target)
                    } else {
                        Text(task.name).lineLimit(1).truncationMode(.tail)
                    }
                    Text(app.project(task.projectId)?.name ?? "").lineLimit(1)
                        .font(.system(size: Theme.rowStatusFont))
                        .foregroundStyle(Theme.ui.text3)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, hover ? 2 * Theme.rowActionSize - Theme.rowActionsOverhang : 0)
                .overlay(alignment: .trailing) { taskActions(task, target: target, shown: hover && app.renaming != target) }
            } rail: {
                RailTile(text: monogram(task.name), state: dot, selected: selected)
            }
            .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.rowWithStatus(task.name, dot))
        .help(collapsed ? "\(app.project(task.projectId)?.name ?? "") › \(task.name)" : "")
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
    }

    // MARK: SSH hosts

    /// Hosts of remote projects, typed-in terminals and the ssh config (#64); hidden when there are none.
    /// A row: server icon, host, state `text3` (project hosts only); a waiting dot when the server needs attention.
    /// A host's terminal («<host> · терминал») sits right under its row.
    @ViewBuilder private var hostsSection: some View {
        let hosts = app.sidebarHosts
        if !hosts.isEmpty {
            SectionHeader(title: L10n.sectionSSHHosts, collapsed: collapsed, plusHelp: L10n.connectToHost, plus: ctx.connectHost)
            ForEach(hosts, id: \.self) { host in
                hostRow(host)
                if let task = app.state.hostShellTask(host: host) { hostShellRow(task, host: host) }
            }
        }
    }

    private func hostRow(_ host: String) -> some View {
        let info = app.remote.hosts[host]
        let items = hostMenuItems(host, app: app, ctx: ctx)
        // Without projects the host has no master or state: a click logs in (or shows its terminal).
        let known = app.sshHosts.contains(host)
        return HoverRow(action: { if known { popUpMenu(items) } else { app.showHostShell(host) } }) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.projectRowTrailing) {
                IconView(icon: .sshHost, size: Theme.hostIconSize)
                    .overlay(alignment: .topTrailing) {
                        // The same corner dot as a rail monogram's: visible in both modes, nothing moves.
                        Circle().fill(Theme.ui.waiting)
                            .frame(width: Theme.railDot, height: Theme.railDot)
                            .background(Circle().fill(Theme.ui.sidebar).padding(-Theme.railDotBorder))
                            .offset(x: Theme.railDotOffset, y: -Theme.railDotOffset)
                            .opacity(info?.needsAttention == true ? 1 : 0)
                    }
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    Text(verbatim: host).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: Theme.fontSize.base))
                        .foregroundStyle(Theme.ui.textRow)
                    Spacer(minLength: 0)
                    if known {
                        Text(hostStatusLabel(info)).lineLimit(1)
                            .font(.system(size: Theme.rowStatusFont))
                            .foregroundStyle(Theme.ui.text3)
                            .opacity(hover ? 0 : 1)
                    }
                }
                // «⋯» takes the state's place on hover, no layout change.
                .overlay(alignment: .trailing) {
                    PopoverMenuButton { popoverEntries(items) }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                }
            } rail: { EmptyView() }
        }
        .help(known ? hostHelp(host, info) : L10n.openTerminal)
        .popoverContextMenu { popoverEntries(items) }
    }

    /// «<host> · терминал»: plain ssh shells (#64); its menu opens another tab or closes them all.
    private func hostShellRow(_ task: HangarTask, host: String) -> some View {
        let selected = task.id == app.state.selectedTaskId
        let dot = app.displayState(of: task)
        let name = L10n.hostTerminal(host)
        let items = [MenuEntry(title: L10n.openTerminal, icon: .shell) { app.openHostShell(host) },
                     MenuEntry(title: L10n.closeTerminal, icon: .close) { app.closeHostShell(host) }]
        return HoverRow(selected: selected, action: { app.select(taskId: task.id) }) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.projectRowTrailing, railReplacesMarker: true) {
                StatusDot(state: dot)
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, hover ? Theme.rowActionSize : 0)
                .overlay(alignment: .trailing) {
                    PopoverMenuButton { popoverEntries(items) }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                }
            } rail: {
                RailTile(text: monogram(host), state: dot, selected: selected)
            }
            .font(.system(size: Theme.fontSize.sidebarRow))
            .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.rowWithStatus(name, dot))
        .help(collapsed ? name : L10n.plainSSHHint)
        .popoverContextMenu { popoverEntries(items) }
    }

    /// Why the host is not connected (or that its server needs attention).
    private func hostHelp(_ host: String, _ info: HostInfo?) -> String {
        if info?.needsAttention == true { return L10n.serverTitle(host) + " · " + L10n.checkServer }
        guard let info, info.state != .connected else { return host }
        return host + " · " + hostFailure(host, info).text
    }

    // MARK: Projects

    @ViewBuilder private var projectsSection: some View {
        let filtering = app.state.attentionOnly
        let groups = filtering ? app.attentionGroups() : []
        SectionHeader(title: L10n.sectionProjects, collapsed: collapsed, plusHelp: L10n.help(L10n.addProject, .addProject),
                      plusAlwaysVisible: app.state.projects.isEmpty, plus: ctx.addProject,
                      filterOn: filtering, filterHelp: L10n.help(L10n.attentionOnly, .attentionFilter),
                      filter: { app.perform { $0.attentionOnly.toggle() } })
        if filtering && groups.isEmpty {
            Text(L10n.nobodyWaiting)
                .font(.system(size: Theme.fontSize.sidebarRow))
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(1)
                .padding(.leading, Theme.sectionHeaderX)
                .frame(maxWidth: .infinity, minHeight: Theme.railRowHeight, alignment: .leading)
                .opacity(collapsed ? 0 : 1)
        }
        ForEach(filtering ? groups.map(\.project) : app.state.projects) { project in
            // One block per project, so a dragged project moves with its tasks.
            VStack(spacing: 0) {
                projectRow(project)
                if !project.collapsed {
                    ForEach(filtering ? groups.first { $0.project.id == project.id }?.tasks ?? [] : app.groupTasks(project.id)) { task in
                        taskRow(task)
                            .modifier(DragLook(dy: dragOffset(.task(task.id)), line: dropLine(at: task.id)))
                    }
                }
            }
            .modifier(DragLook(dy: dragOffset(.project(project.id)), line: dropLine(at: project.id)))
            .zIndex(isDragging(in: project) ? 1 : 0)
        }
    }

    /// Remembered as the F2 target; the keyboard stays with the terminal.
    private func clicked(_ target: ActionTarget) { app.chromeClicked(target) }

    // MARK: Reorder

    /// Ids and heights of the dragged item's group: a project's unpinned tasks, or all project blocks.
    private func dragGroup(_ target: ActionTarget) -> (ids: [UUID], heights: [CGFloat])? {
        switch target {
        case .task(let id):
            guard let task = app.state.tasks.first(where: { $0.id == id }) else { return nil }
            let ids = app.groupTasks(task.projectId).map(\.id)
            return (ids, ids.map { _ in Theme.sessionRowHeight })
        case .project:
            let heights = app.state.projects.map { p in
                Theme.railRowHeight + Theme.sessionRowHeight * CGFloat(p.collapsed ? 0 : app.groupTasks(p.id).count)
            }
            return (app.state.projects.map(\.id), heights)
        case .tab: return nil
        }
    }

    private func id(_ target: ActionTarget) -> UUID? {
        switch target {
        case .task(let id), .project(let id): id
        case .tab: nil
        }
    }

    /// Where the dragged item would land: index among the others, plus the row the insertion line is drawn on.
    private var dropSlot: (index: Int, row: UUID, edge: VerticalEdge)? {
        guard let drag, let group = dragGroup(drag.target), let dragged = id(drag.target),
              let from = group.ids.firstIndex(of: dragged) else { return nil }
        let to = dropIndex(heights: group.heights, from: from, dy: drag.dy)
        let others = group.ids.filter { $0 != dragged }
        guard to != from, let last = others.last else { return nil }
        return to < others.count ? (to, others[to], .top) : (to, last, .bottom)
    }

    private func dropLine(at row: UUID) -> VerticalEdge? { dropSlot?.row == row ? dropSlot?.edge : nil }

    /// The block holding the dragged row draws above its neighbours.
    private func isDragging(in project: Project) -> Bool {
        guard let drag else { return false }
        if case .task(let id) = drag.target { return app.state.tasks.first { $0.id == id }?.projectId == project.id }
        return drag.target == .project(project.id)
    }

    private func dragOffset(_ target: ActionTarget) -> CGFloat { drag?.target == target ? drag?.dy ?? 0 : 0 }

    private func dragHandlers(_ target: ActionTarget) -> (onDrag: (CGFloat) -> Void, onDragEnd: (CGFloat) -> Void) {
        ({ dy in drag = (target, dy) }, { dy in
            drag = (target, dy)
            let slot = dropSlot
            drag = nil
            guard let slot, let moved = id(target) else { return }
            switch target {
            case .task: app.moveTask(moved, toGroupIndex: slot.index)
            case .project: app.moveProject(moved, to: slot.index)
            case .tab: break
            }
        })
    }

    /// Group header, 32: chevron in the gutter, name 13.5 semibold; «⋯» and «+» on hover, on the highlight itself.
    private func projectRow(_ project: Project) -> some View {
        // Remote: gray only while the host is given up on (its disk is not stat'ed from here).
        let exists = app.isAvailable(project)
        let target = ActionTarget.project(project.id)
        let handlers = dragHandlers(target)
        let renaming = app.renaming == target
        return HoverRow(action: {
                            clicked(target)
                            app.setCollapsed(projectId: project.id, !project.collapsed)
                        },
                        // The filtered list is not the real order: no reordering while it is on.
                        onDrag: app.state.attentionOnly ? nil : handlers.onDrag, onDragEnd: handlers.onDragEnd,
                        forceHover: forcedHover(target)) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.projectRowTrailing, railReplacesMarker: true) {
                IconView(icon: project.collapsed ? .chevronRight : .chevronDown, tint: Theme.ui.text3)
            } expanded: {
                HStack(spacing: 0) {
                    Group {
                        if renaming {
                            RenameField(app: app, target: target)
                        } else {
                            Text(project.name).foregroundStyle(Theme.ui.textStrong).lineLimit(1)
                        }
                    }
                    .font(.system(size: Theme.fontSize.sidebarRow, weight: .semibold))
                    // Remote: the server glyph and host after the name (`text3`); the rail keeps the plain monogram.
                    if let host = project.host, !renaming {
                        HStack(spacing: Theme.railInset) {
                            IconView(icon: .sshHost, size: Theme.hostIconSize, tint: Theme.ui.text3)
                            Text(verbatim: host).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: Theme.rowStatusFont))
                                .foregroundStyle(Theme.ui.text3)
                        }
                        .padding(.leading, Theme.inlineGap)
                        .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                    if !exists, project.host == nil {
                        Text(L10n.folderMissing).font(.system(size: Theme.rowStatusFont)).foregroundStyle(Theme.ui.text3)
                            .padding(.leading, Theme.rowEndGap)
                            .opacity(hover ? 0 : 1)
                    }
                }
                .padding(.trailing, hover ? 2 * Theme.rowActionSize : 0)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 0) {
                        PopoverMenuButton { actionMenu(for: target, ctx: ctx) }
                        if exists {
                            RowActionButton(icon: .add, help: L10n.newTaskIn(project.name)) { ctx.newTask(project.id) }
                        }
                    }
                    .opacity(hover && !renaming ? 1 : 0)
                    .allowsHitTesting(hover && !renaming)
                }
            } rail: {
                // Rail: a folder-like monogram tile (no status dot, `text3` border).
                Text(monogram(project.name))
                    .font(.system(size: Theme.fontSize.small, weight: .semibold))
                    .foregroundStyle(Theme.ui.text3)
                    .frame(width: Theme.projectTileSize, height: Theme.projectTileSize)
                    .overlay(RoundedRectangle(cornerRadius: Theme.projectTileRadius).stroke(Theme.ui.text3, lineWidth: 1))
            }
            .opacity(exists ? 1 : Theme.inactiveOpacity)
        }
        .help(collapsed ? project.name : project.host.map { "\($0):\(project.path)" }
              ?? (exists ? project.path : L10n.folderMissing(project.path)))
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
    }

    // MARK: Sessions

    /// Two lines, 44: name with the `+N −M` badge, then the status («ждёт · 1 агент»). On hover pin and «⋯»
    /// fade in where the badge was (it fades out): no box of their own, nothing moves.
    private func taskRow(_ task: HangarTask) -> some View {
        let selected = task.id == app.state.selectedTaskId
        let target = ActionTarget.task(task.id)
        let dot = app.displayState(of: task)
        let badge = app.diffBadge(of: task)
        let worktree = if case .worktree = task.mode { true } else { false }
        // As a project whose folder is missing: the host was given up on.
        let offline = app.project(task.projectId).map { $0.host != nil && !app.isAvailable($0) } ?? false
        let handlers = app.state.attentionOnly ? nil : dragHandlers(target)
        return HoverRow(selected: selected, action: {
                            clicked(target)
                            app.select(taskId: task.id)
                        },
                        doubleAction: { Action.rename.perform(target, ctx) },
                        onDrag: handlers?.onDrag, onDragEnd: handlers?.onDragEnd,
                        forceHover: forcedHover(target)) { hover in
            let showActions = hover && app.renaming != target
            GutterRow(collapsed: collapsed, height: Theme.sessionRowHeight, trailing: Theme.sessionRowTrailing, railReplacesMarker: true,
                      markerDY: Theme.sessionRowPaddingV + Theme.sessionNameLine / 2 - Theme.sessionRowHeight / 2) {
                StatusDot(state: dot)
            } expanded: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.rowSlotGap) {
                        Group {
                            if app.renaming == target {
                                RenameField(app: app, target: target)
                            } else {
                                Text(task.name).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        // Without a badge the actions cover the name's end: it truncates earlier instead.
                        .padding(.trailing, showActions && badge == nil ? 2 * Theme.rowActionSize - Theme.rowActionsOverhang : 0)
                        Spacer(minLength: 0)
                        if let badge { DiffBadgeView(badge: badge).opacity(showActions ? 0 : 1) }
                    }
                    .frame(height: Theme.sessionNameLine)
                    .overlay(alignment: .trailing) {
                        taskActions(task, target: target, shown: showActions)
                            .offset(x: Theme.rowActionsOverhang)
                    }
                    SessionStatusLine(status: app.sessionStatus(of: task), worktree: worktree)
                }
            } rail: {
                RailTile(text: monogram(task.name), state: dot, selected: selected)
            }
            .font(.system(size: Theme.fontSize.sidebarRow))
            .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
            .opacity(offline ? Theme.inactiveOpacity : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.rowWithStatus(task.name, dot))
        .help(collapsed ? "\(app.project(task.projectId)?.name ?? "") › \(task.name)" : "")
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
        .onAppear { app.requestBadge(task) }
    }

    /// Pin and «⋯» (120 ms fade, opacity only); the pin is white while pinned.
    private func taskActions(_ task: HangarTask, target: ActionTarget, shown: Bool) -> some View {
        HStack(spacing: 0) {
            RowActionButton(icon: .pin, tint: task.pinned ? Theme.ui.textStrong : nil, help: task.pinned ? L10n.unpin : L10n.pin) {
                app.setPinned(task.id, !task.pinned)
            }
            PopoverMenuButton { actionMenu(for: target, ctx: ctx) }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(Motion.ease(Theme.hoverFade), value: shown)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // No data for any agent → no block (and no rail tile).
            if !app.limitRows.isEmpty {
                if collapsed { LimitsRailTile(app: app) } else { LimitsBlock(app: app) }
            }
            // ☕ has its own row in both modes: collapsing never adds or removes a row, so the bottom group stays put.
            KeepAwakeRow(app: app, collapsed: collapsed)
            // «Добавить проект» lives only at ПРОЕКТЫ «+» (redesign v1): Settings has no «⋯».
            HoverRow(action: ctx.openSettings) { _ in
                GutterRow(collapsed: collapsed, height: Theme.railRowHeight, trailing: Theme.rowEndTrailing) {
                    IconView(icon: .settings)
                } expanded: {
                    HStack(spacing: 0) {
                        Text(L10n.settings)
                        Spacer(minLength: 0)
                        ShortcutHint(text: Shortcut.settings.label)
                    }
                    .font(.system(size: Theme.fontSize.sidebarFooter))
                    .foregroundStyle(Theme.ui.text2)
                } rail: { EmptyView() }
            }
            .help(L10n.help(L10n.settingsHelp, .settings))
        }
        .padding(.top, Theme.bottomBarTop)
        .padding(.bottom, Theme.bottomBarBottom)
        .background(Theme.ui.bottomBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }
}


/// ☕ state → its look: on = accent icon, `textStrong` label, switch on; the dot only while the assertion is held.
struct KeepAwakeLook: Equatable {
    let on: Bool
    let tint: Color
    let label: Color
    let dot: Bool
}

func keepAwakeLook(enabled: Bool, held: Bool) -> KeepAwakeLook {
    enabled ? KeepAwakeLook(on: true, tint: Theme.ui.accent, label: Theme.ui.textStrong, dot: held)
        : KeepAwakeLook(on: false, tint: Theme.ui.text3, label: Theme.ui.text3, dot: false)
}

/// ☕ row above Settings (both modes): a switch on the right (expanded), the icon tint and dot (both modes); click toggles `keep_awake`.
private struct KeepAwakeRow: View {
    let app: AppState
    let collapsed: Bool

    var body: some View {
        let keep = app.keepAwake
        let look = keepAwakeLook(enabled: app.config.keepAwake, held: keep.held)
        HoverRow(action: toggle) { _ in
            GutterRow(collapsed: collapsed, height: Theme.railRowHeight, trailing: Theme.rowEndTrailing) {
                IconView(icon: .keepAwake, tint: look.tint)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(Theme.ui.accent)
                            .overlay(Circle().stroke(Theme.ui.bottomBar, lineWidth: Theme.railDotBorder))
                            .frame(width: Theme.keepAwakeDot, height: Theme.keepAwakeDot)
                            .offset(x: Theme.keepAwakeDotOffset, y: -Theme.keepAwakeDotOffset)
                            .opacity(look.dot ? 1 : 0)
                    }
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    Text(L10n.keepAwakeShort).lineLimit(1).truncationMode(.tail)
                        .font(.system(size: Theme.fontSize.sidebarFooter))
                        .foregroundStyle(look.label)
                    Spacer(minLength: 0)
                    KeepAwakeSwitch(on: look.on)
                }
            } rail: { EmptyView() }
        }
        .help(L10n.keepAwakeHelp(enabled: app.config.keepAwake, held: keep.held, working: keep.working))
        .accessibilityLabel(L10n.keepAwakeTitle)
        .accessibilityValue(look.on ? L10n.toggleOn : L10n.toggleOff)
    }

    private func toggle() {
        let on = !app.config.keepAwake
        do { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } } catch { app.beep() }
    }
}

/// Small macOS-style switch (display only: the whole row is the button): accent fill when on, `text3` outline when off.
private struct KeepAwakeSwitch: View {
    let on: Bool

    var body: some View {
        let knob = Theme.keepAwakeSwitchHeight - 2 * Theme.keepAwakeSwitchInset
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Theme.ui.accent : .clear)
            Capsule().stroke(on ? Theme.ui.accent : Theme.ui.text3, lineWidth: 1)
            Circle().fill(on ? Theme.ui.textStrong : Theme.ui.text3)
                .frame(width: knob, height: knob)
                .padding(.horizontal, Theme.keepAwakeSwitchInset)
        }
        .frame(width: Theme.keepAwakeSwitchWidth, height: Theme.keepAwakeSwitchHeight)
    }
}

/// Dragged row follows the pointer; the drop target gets a 2 pt `accent` line on the insertion edge.
private struct DragLook: ViewModifier {
    let dy: CGFloat
    let line: VerticalEdge?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: line == .bottom ? .bottom : .top) {
                if line != nil { Rectangle().fill(Theme.ui.accent).frame(height: Theme.dropLineWidth) }
            }
            .offset(y: dy)
            .zIndex(dy == 0 ? 0 : 1)
    }
}
