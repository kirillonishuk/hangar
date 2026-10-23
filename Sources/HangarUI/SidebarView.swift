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
    @State private var archiveOpen = false
    /// Row being reordered (task within its group, or project) and its vertical translation.
    @State private var drag: (target: ActionTarget, dy: CGFloat)?

    private var collapsed: Bool { app.state.sidebarCollapsed }

    var body: some View {
        GeometryReader { geo in
            // While collapsed or animating, lay out at the expanded width and clip, so text never reflows.
            let width = collapsed || app.sidebarAnimating ? max(geo.size.width, CGFloat(app.state.sidebarWidth)) : geo.size.width
            VStack(spacing: 0) {
                Color.clear.frame(height: Theme.trafficLightsHeight).background(WindowDragArea())
                newTaskButton(visibleWidth: geo.size.width)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        pinnedSection
                        hostsSection
                        projectsSection
                        archivedSection
                    }
                    .padding(.bottom, Theme.sectionGap)
                }
                .scrollIndicators(collapsed ? .never : .automatic)
                bottomBar
            }
            .frame(width: width, alignment: .leading)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
        }
        .font(.system(size: Theme.fontSize.sidebarRow))
        .environment(\.hoverPalette, .sidebar)
        .background(Theme.ui.sidebar)
        .ignoresSafeArea()
    }

    // MARK: Top

    /// Filled full-width button; the fill is inset so the `+` keeps the shared marker x.
    private func newTaskButton(visibleWidth: CGFloat) -> some View {
        Button { ctx.newTask(nil) } label: {
            GutterRow(collapsed: collapsed) {
                IconView(icon: .newTask, active: true)
            } expanded: {
                HStack(spacing: 0) {
                    Text(L10n.newTask).foregroundStyle(Theme.ui.textStrong)
                    Spacer(minLength: 0)
                    ShortcutHint(text: "⌘N")
                }
            } rail: { EmptyView() }
            .contentShape(Rectangle())
        }
        .buttonStyle(FilledRowStyle(width: visibleWidth - 2 * Theme.railInset))
        .help(L10n.newTaskHelp)
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedSection: some View {
        let pinned = app.pinnedTasks
        if !pinned.isEmpty {
            SectionHeader(title: L10n.sectionPinned, collapsed: collapsed)
            ForEach(pinned) { task in taskRow(task, projectName: app.project(task.projectId)?.name, indent: false) }
        }
    }

    // MARK: SSH hosts

    /// Hidden without remote projects. A row: server icon, host, state `text3`; a waiting dot when the server needs attention.
    @ViewBuilder private var hostsSection: some View {
        let hosts = app.sshHosts
        if !hosts.isEmpty {
            SectionHeader(title: L10n.sectionSSHHosts, collapsed: collapsed)
            ForEach(hosts, id: \.self) { host in hostRow(host) }
        }
    }

    private func hostRow(_ host: String) -> some View {
        let info = app.remote.hosts[host]
        let items = hostMenuItems(host, app: app, ctx: ctx)
        return HoverRow(action: { popUpMenu(items) }) { hover in
            GutterRow(collapsed: collapsed) {
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
                    Text(hostStatusLabel(info)).lineLimit(1)
                        .font(.system(size: Theme.fontSize.counter))
                        .foregroundStyle(Theme.ui.text3)
                    MoreButton { MenuItemsView(items: items) }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                }
            } rail: { EmptyView() }
        }
        .help(hostHelp(host, info))
        .contextMenu { MenuItemsView(items: items) }
    }

    /// Why the host is not connected (or that its server needs attention).
    private func hostHelp(_ host: String, _ info: HostInfo?) -> String {
        if info?.needsAttention == true { return L10n.serverTitle(host) + " · " + L10n.checkServer }
        guard let info, info.state != .connected else { return host }
        return host + " · " + hostFailure(host, info).text
    }

    // MARK: Projects

    @ViewBuilder private var projectsSection: some View {
        SectionHeader(title: L10n.sectionProjects, collapsed: collapsed, plusHelp: L10n.addProject,
                      plusAlwaysVisible: app.state.projects.isEmpty, plus: ctx.addProject)
        ForEach(app.state.projects) { project in
            // One block per project, so a dragged project moves with its tasks.
            VStack(spacing: 0) {
                projectRow(project)
                if !project.collapsed {
                    ForEach(app.groupTasks(project.id)) { task in
                        taskRow(task, projectName: nil, indent: true)
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

    /// The context menu's actions as entries for `popUpMenu`.
    private func actionEntries(_ target: ActionTarget) -> [MenuEntry] {
        Action.list(for: target, app: app).map { action in
            MenuEntry(title: action.title(for: target, app: app), icon: action.icon,
                      enabled: action.isEnabled(for: target, app: app)) { action.perform(target, ctx) }
        }
    }

    // MARK: Reorder

    /// Ids and heights of the dragged item's group: a project's unpinned tasks, or all project blocks.
    private func dragGroup(_ target: ActionTarget) -> (ids: [UUID], heights: [CGFloat])? {
        switch target {
        case .task(let id):
            guard let task = app.state.tasks.first(where: { $0.id == id }) else { return nil }
            let ids = app.groupTasks(task.projectId).map(\.id)
            return (ids, ids.map { _ in Theme.railRowHeight })
        case .project:
            let heights = app.state.projects.map { p in
                Theme.railRowHeight * CGFloat(1 + (p.collapsed ? 0 : app.groupTasks(p.id).count))
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

    private func projectRow(_ project: Project) -> some View {
        // Remote: gray only while the host is given up on (its disk is not stat'ed from here).
        let exists = app.isAvailable(project)
        let target = ActionTarget.project(project.id)
        let handlers = dragHandlers(target)
        return HoverRow(action: {
                            clicked(target)
                            app.setCollapsed(projectId: project.id, !project.collapsed)
                        },
                        onDrag: handlers.onDrag, onDragEnd: handlers.onDragEnd) { hover in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    IconView(icon: project.collapsed ? .chevronRight : .chevronDown, size: Theme.smallIconSize)
                        .frame(width: Theme.smallIconSize)
                        .padding(.leading, Theme.projectChevronX - Theme.smallIconSize / 2)
                    Group {
                        if app.renaming == target {
                            RenameField(app: app, target: target)
                        } else {
                            Text(project.name).foregroundStyle(Theme.ui.text).lineLimit(1)
                        }
                    }
                    .font(.system(size: Theme.fontSize.sidebarRow, weight: .semibold))
                    .padding(.leading, Theme.projectTextX - Theme.projectChevronX - Theme.smallIconSize / 2)
                    // Remote: the server glyph and host after the name (`text3`); the rail keeps the plain monogram.
                    if let host = project.host, app.renaming != target {
                        HStack(spacing: Theme.railInset) {
                            IconView(icon: .sshHost, size: Theme.hostIconSize, tint: Theme.ui.text3)
                            Text(verbatim: host).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: Theme.fontSize.counter))
                                .foregroundStyle(Theme.ui.text3)
                        }
                        .padding(.leading, Theme.inlineGap)
                        .layoutPriority(-1)
                    }
                    Spacer(minLength: Theme.rowEndGap)
                    MoreButton { ActionMenuItems(target: target, ctx: ctx) }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                    if exists {
                        Button { ctx.newTask(project.id) } label: {
                            IconView(icon: .newTask, size: Theme.smallIconSize).padding(Theme.railInset)
                        }
                        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                        .opacity(hover ? 1 : 0)
                        .help(L10n.newTaskIn(project.name))
                    } else if project.host == nil {
                        Text(L10n.folderMissing).font(.system(size: Theme.fontSize.small)).foregroundStyle(Theme.ui.text3)
                    }
                }
                .padding(.trailing, Theme.rowPaddingH - Theme.railInset)
                .opacity(collapsed ? 0 : 1)
                // Rail: a folder-like monogram tile (no status dot, `text3` border).
                Text(monogram(project.name))
                    .font(.system(size: Theme.fontSize.small, weight: .semibold))
                    .foregroundStyle(Theme.ui.text3)
                    .frame(width: Theme.projectTileSize, height: Theme.projectTileSize)
                    .overlay(RoundedRectangle(cornerRadius: Theme.projectTileRadius).stroke(Theme.ui.text3, lineWidth: 1))
                    .padding(.leading, (Theme.sidebarRailWidth - Theme.projectTileSize) / 2)
                    .opacity(collapsed ? 1 : 0)
            }
            .frame(height: Theme.railRowHeight)
            .opacity(exists ? 1 : Theme.inactiveOpacity)
            .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
        }
        .help(collapsed ? project.name : project.host.map { "\($0):\(project.path)" }
              ?? (exists ? project.path : L10n.folderMissing(project.path)))
        .contextMenu { ActionMenuItems(target: target, ctx: ctx) }
    }

    // MARK: Tasks

    /// `projectName` set → pinned row (project shown after the name); `indent` → under its project.
    private func taskRow(_ task: HangarTask, projectName: String?, indent: Bool) -> some View {
        let selected = task.id == app.state.selectedTaskId
        let target = ActionTarget.task(task.id)
        let dot = app.displayState(of: task)
        // As a project whose folder is missing: the host was given up on.
        let offline = app.project(task.projectId).map { $0.host != nil && !app.isAvailable($0) } ?? false
        // Pinned rows mix projects, so only rows inside a project group reorder.
        let handlers = indent ? dragHandlers(target) : nil
        return HoverRow(selected: selected, action: {
                            clicked(target)
                            app.select(taskId: task.id)
                        },
                        doubleAction: { Action.rename.perform(target, ctx) },
                        onDrag: handlers?.onDrag, onDragEnd: handlers?.onDragEnd) { hover in
            GutterRow(collapsed: collapsed, railReplacesMarker: true) {
                StatusDot(state: dot)
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    if app.renaming == target {
                        RenameField(app: app, target: target)
                    } else {
                        Text(task.name).lineLimit(1).truncationMode(.tail)
                    }
                    if let projectName {
                        Text(projectName).lineLimit(1).foregroundStyle(Theme.ui.text3)
                    }
                    Spacer(minLength: 0)
                    if case .worktree = task.mode {
                        IconView(icon: .worktree, size: Theme.worktreeEndIcon, tint: Theme.ui.text3)
                    }
                }
                // Overlaid, not laid out: the name keeps the full width and nothing reflows on hover.
                .overlay(alignment: .trailing) { taskActions(task, target: target, selected: selected, hover: hover) }
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
        .contextMenu { ActionMenuItems(target: target, ctx: ctx) }
    }

    /// `…` and pin at the row's trailing edge (on hover/selection; the pin also while pinned), over a short fade
    /// in the row's own background so they cover the name's end instead of taking width from it.
    private func taskActions(_ task: HangarTask, target: ActionTarget, selected: Bool, hover: Bool) -> some View {
        let showMenu = hover || selected
        // Not over the inline rename field.
        let shown = (showMenu || task.pinned) && app.renaming != target
        let bg = HoverPalette.sidebar.background(selected: selected, hover: hover, base: Theme.ui.sidebar)
        return HStack(spacing: 0) {
            LinearGradient(colors: [bg.opacity(0), bg], startPoint: .leading, endPoint: .trailing)
                .frame(width: Theme.rowActionsFade)
                .allowsHitTesting(false)
            HStack(spacing: Theme.inlineGap) {
                if showMenu { MoreButton { ActionMenuItems(target: target, ctx: ctx) } }
                Button { app.setPinned(task.id, !task.pinned) } label: {
                    IconView(icon: task.pinned ? .pinned : .pin, active: selected, size: Theme.smallIconSize)
                        .padding(Theme.railInset)
                }
                .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                .help(task.pinned ? L10n.unpin : L10n.pin)
            }
            .background(bg)
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }

    // MARK: Archived

    @ViewBuilder private var archivedSection: some View {
        let archived = app.archivedTasks
        if !archived.isEmpty {
            VStack(spacing: 0) {
                HoverRow(action: { withAnimation(Motion.ease(Theme.selectionFade)) { archiveOpen.toggle() } }) { _ in
                    GutterRow(collapsed: collapsed) {
                        IconView(icon: .archive)
                    } expanded: {
                        HStack(spacing: Theme.inlineGap) {
                            Text(L10n.sectionArchived).tracking(Theme.fontSize.section * Theme.fontSize.projectTracking)
                            Text("\(archived.count)").font(.system(size: Theme.fontSize.counter))
                            Spacer(minLength: 0)
                            IconView(icon: archiveOpen ? .chevronDown : .chevronRight, size: Theme.smallIconSize)
                        }
                        .font(.system(size: Theme.fontSize.section, weight: .semibold))
                        .foregroundStyle(Theme.ui.text3)
                    } rail: { EmptyView() }
                }
                if archiveOpen {
                    ForEach(archived) { task in
                        let target = ActionTarget.task(task.id)
                        // A click opens the same menu as right-click (restore / delete), at the pointer like the host row.
                        HoverRow(action: { popUpMenu(actionEntries(target)) }) { _ in
                            GutterRow(collapsed: collapsed) {
                                StatusDot(state: app.displayState(of: task))
                            } expanded: {
                                HStack(spacing: Theme.inlineGap) {
                                    Text(task.name).lineLimit(1)
                                    Text(app.project(task.projectId)?.name ?? "").lineLimit(1).foregroundStyle(Theme.ui.text3)
                                }
                                .font(.system(size: Theme.fontSize.sidebarRow))
                                .foregroundStyle(Theme.ui.text2)
                            } rail: { EmptyView() }
                        }
                        .contextMenu { ActionMenuItems(target: target, ctx: ctx) }
                    }
                }
            }
            .padding(.top, Theme.sectionGap)
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
        }
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
            HoverRow(action: ctx.openSettings) { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .settings)
                } expanded: {
                    HStack(spacing: 0) {
                        Text(L10n.settings)
                        Spacer(minLength: 0)
                        MoreButton {
                            Button(L10n.addLocalProject, action: ctx.addLocalProject)
                            Button(L10n.addRemoteProject, action: ctx.addRemoteProject)
                        }
                    }
                    .font(.system(size: Theme.fontSize.sidebarFooter))
                    .foregroundStyle(Theme.ui.text3)
                } rail: { EmptyView() }
            }
            .help(L10n.settingsHelp)
            HoverRow(action: ctx.toggleSidebar) { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .sidebarToggle)
                } expanded: {
                    HStack(spacing: 0) {
                        Text(L10n.collapse)
                        Spacer(minLength: 0)
                        ShortcutHint(text: "⌘0")
                    }
                    .font(.system(size: Theme.fontSize.sidebarFooter))
                    .foregroundStyle(Theme.ui.text3)
                } rail: { EmptyView() }
            }
            .help(collapsed ? L10n.expandSidebarHelp : L10n.collapseSidebarHelp)
        }
        .padding(.vertical, Theme.railInset)
        .background(Theme.ui.bottomBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }
}

/// ☕ row above Settings (both modes): accent while the sleep assertion is held; click toggles `keep_awake`.
private struct KeepAwakeRow: View {
    let app: AppState
    let collapsed: Bool

    var body: some View {
        let keep = app.keepAwake
        HoverRow(action: toggle) { _ in
            GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                IconView(icon: .keepAwake, tint: keep.held ? Theme.ui.accent : Theme.ui.text3)
            } expanded: {
                Text(L10n.keepAwakeTitle).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: Theme.fontSize.sidebarFooter))
                    .foregroundStyle(app.config.keepAwake ? Theme.ui.text2 : Theme.ui.text3)
            } rail: { EmptyView() }
        }
        .help(L10n.keepAwakeHelp(enabled: app.config.keepAwake, held: keep.held, working: keep.working))
        .accessibilityLabel(L10n.keepAwakeTitle)
    }

    private func toggle() {
        let on = !app.config.keepAwake
        do { try app.setConfig("keep_awake", flag: on) { $0.keepAwake = on } } catch { app.beep() }
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
