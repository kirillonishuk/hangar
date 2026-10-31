import AgentStatus
import SwiftUI
import Workspace

/// Rail label: parts split on `-`, `_`, `.`, whitespace and lower→Upper (camelCase) boundaries;
/// first letters of the first two parts, uppercased ("acme-web" → "AW", "shopApi" → "SA", "refactor" → "R").
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
            // The rail highlights a square around the tile, the expanded sidebar the whole row.
            let inset = collapsed ? (Theme.sidebarRailWidth - Theme.railHighlight) / 2 : Theme.rowInset
            VStack(spacing: 0) {
                // The toolbar's sidebar head (traffic lights, the toggle) is drawn over this.
                Color.clear.frame(height: Theme.Height.barToolbar)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        chatsSection
                        if !app.state.attentionOnly { pinnedSection }
                        projectsSection
                        hostsSection
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
        .font(Theme.Typography.body.font())
        // The rail's selection is a quiet square (the tile itself carries the accent), not an `accent` block.
        .environment(\.hoverPalette, collapsed ? .standard : .focus)
        .background(Theme.ui.bg1)
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

    // MARK: Chats without a project

    /// «Чаты» above everything (spec free-chats §4): pinned, open and recent chats, «Все чаты (N)…»; empty — the header
    /// with its «+». The attention filter keeps only chats that need action; the rail only shows their tiles.
    @ViewBuilder private var chatsSection: some View {
        let filtering = app.state.attentionOnly
        let rows = filtering
            ? app.state.freeChatTasks.filter { !$0.archived && [.waiting, .failed].contains(app.displayState(of: $0)) }
            : app.sidebarFreeChats()
        if !rows.isEmpty || !(filtering || collapsed) {
            SectionHeader(title: L10n.sectionChats, collapsed: collapsed, plusHelp: L10n.help(L10n.newFreeChat, .newFreeChat),
                          plusAlwaysVisible: app.state.freeChats.isEmpty, plus: { app.newFreeChat() })
            ForEach(rows) { task in freeChatRow(task) }
            if !filtering, !rows.isEmpty { allChatsRow }
        }
    }

    /// One line, 28, at the project level: dot (none while asleep), name, and at the end the word that needs action or
    /// the time of last use; pin and «⋯» over that end on hover. Asleep: name `text2`; a click wakes it.
    private func freeChatRow(_ task: HangarTask) -> some View {
        let selected = !app.sessionsViewVisible && task.id == app.state.selectedTaskId
        let target = ActionTarget.task(task.id)
        let asleep = task.archived
        let dot = app.displayState(of: task)
        // The word that needs action wins over the time («2 мин», «вчера»), which is recomputed on redraw, no timer.
        let urgent = !asleep && [.waiting, .failed, .limit].contains(dot)
        let end = urgent ? L10n.rowStatus(dot)
            : app.state.freeChat(ofTask: task.id).map { freeChatTime($0.lastUsedAt, now: Date()) } ?? ""
        let endWidth = ceil((end as NSString).size(withAttributes: [.font: Theme.Typography.caption.nsFont()]).width)
        return HoverRow(selected: selected, action: {
                            clicked(target)
                            app.wakeFreeChat(task.id)
                        },
                        doubleAction: { Action.rename.perform(target, ctx) },
                        forceHover: forcedHover(target)) { hover in
            let showActions = hover && app.renaming != target
            GutterRow(collapsed: collapsed, trailing: Theme.sessionRowTrailing, railReplacesMarker: true) {
                if !asleep {
                    StatusDot(state: dot, border: selected ? Theme.ui.onAccent : nil, borderWidth: selected ? Theme.railDotBorder : 0)
                }
            } expanded: {
                HStack(spacing: Theme.rowEndGap) {
                    Group {
                        if app.renaming == target {
                            RenameField(app: app, target: target)
                        } else {
                            Text(task.name).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(selected ? Theme.ui.onAccent : asleep ? Theme.ui.text2 : Theme.ui.text1)
                        }
                    }
                    Spacer(minLength: 0)
                    ZStack(alignment: .trailing) {
                        Color.clear.frame(width: Self.rowEndSlot(endWidth), height: 1)
                        Text(verbatim: end)
                            .font(Theme.Typography.caption.font())
                            .foregroundStyle(selected ? Theme.ui.onAccent
                                             : urgent ? (dot == .failed ? Theme.ui.failedText : Theme.ui.waiting) : Theme.ui.text3)
                            .lineLimit(1)
                            .fixedSize()
                            .opacity(showActions ? 0 : 1)
                    }
                }
                .overlay(alignment: .trailing) {
                    taskActions(task, target: target, shown: showActions)
                        .offset(x: Theme.rowActionsOverhang)
                }
            } rail: {
                RailTile(text: monogram(task.name), state: asleep ? nil : dot, selected: selected, hover: hover,
                         style: asleep && !selected ? RailTileStyle(fill: Theme.ui.hover2, border: .clear, text: Theme.ui.text3) : nil)
            }
            .font(Theme.Typography.body.font())
            .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.rowWithStatus(task.name, dot))
        .help(collapsed ? "\(L10n.noProject) › \(task.name)" : "")
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
    }

    /// «Все чаты (N)…»: History scoped to «Чаты» (search by title and conversation text).
    private var allChatsRow: some View {
        HoverRow(action: { app.showSessionsView(scope: .chats) }) { _ in
            GutterRow(collapsed: collapsed, trailing: Theme.sessionRowTrailing) {
                EmptyView()
            } expanded: {
                Text(L10n.allFreeChats(app.state.freeChats.count)).lineLimit(1).foregroundStyle(Theme.ui.text2)
            } rail: { EmptyView() }
        }
        .frame(height: collapsed ? 0 : nil)
        .opacity(collapsed ? 0 : 1)
        .allowsHitTesting(!collapsed)
        .help(L10n.help(L10n.sessionsViewHelp, .sessions))
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
        let selected = !app.sessionsViewVisible && task.id == app.state.selectedTaskId  // «Сессии» is the selected row while shown
        let target = ActionTarget.task(task.id)
        let dot = app.displayState(of: task)
        return HoverRow(selected: selected, action: {
                            clicked(target)
                            app.select(taskId: task.id)
                        },
                        doubleAction: { Action.rename.perform(target, ctx) },
                        forceHover: forcedHover(target)) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.sessionRowTrailing, railReplacesMarker: true) {
                StatusDot(state: dot, border: selected ? Theme.ui.onAccent : nil, borderWidth: selected ? Theme.railDotBorder : 0)
            } expanded: {
                HStack(spacing: Theme.rowEndGap) {
                    if app.renaming == target {
                        RenameField(app: app, target: target)
                    } else {
                        Text(task.name).lineLimit(1).truncationMode(.tail)
                    }
                    Text(app.project(task.projectId)?.name ?? "").lineLimit(1)
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text3)
                        .layoutPriority(-1)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, hover ? 2 * Theme.Height.controlSmall - Theme.rowActionsOverhang : 0)
                .overlay(alignment: .trailing) { taskActions(task, target: target, shown: hover && app.renaming != target) }
            } rail: {
                RailTile(text: monogram(task.name), state: dot, selected: selected, hover: hover)
            }
            .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text1)
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
                IconView(icon: .sshHost, size: Theme.Icon.toolbar)
                    .overlay(alignment: .topTrailing) {
                        // The same corner dot as a rail monogram's: visible in both modes, nothing moves.
                        Circle().fill(Theme.ui.waiting)
                            .frame(width: Theme.railDot, height: Theme.railDot)
                            .background(Circle().fill(Theme.ui.bg1).padding(-Theme.railDotBorder))
                            .offset(x: Theme.railDotOffset, y: -Theme.railDotOffset)
                            .opacity(info?.needsAttention == true ? 1 : 0)
                    }
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    Text(verbatim: host).lineLimit(1).truncationMode(.middle)
                        .font(Theme.Typography.body.font())
                        .foregroundStyle(Theme.ui.text1)
                    Spacer(minLength: 0)
                    if known {
                        Text(hostStatusLabel(info)).lineLimit(1)
                            .font(Theme.Typography.caption.font())
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
        let selected = !app.sessionsViewVisible && task.id == app.state.selectedTaskId  // «Сессии» is the selected row while shown
        let dot = app.displayState(of: task)
        let name = L10n.hostTerminal(host)
        let items = [MenuEntry(title: L10n.openTerminal, icon: .shell) { app.openHostShell(host) },
                     MenuEntry(title: L10n.closeTerminal, icon: .close) { app.closeHostShell(host) }]
        return HoverRow(selected: selected, action: { app.select(taskId: task.id) }) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.projectRowTrailing, railReplacesMarker: true) {
                StatusDot(state: dot, border: selected ? Theme.ui.onAccent : nil, borderWidth: selected ? Theme.railDotBorder : 0)
            } expanded: {
                HStack(spacing: Theme.inlineGap) {
                    Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, hover ? Theme.Height.controlSmall : 0)
                .overlay(alignment: .trailing) {
                    PopoverMenuButton { popoverEntries(items) }
                        .opacity(hover ? 1 : 0)
                        .allowsHitTesting(hover)
                }
            } rail: {
                RailTile(text: monogram(host), state: dot, selected: selected, hover: hover)
            }
            .font(Theme.Typography.body.font())
            .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text1)
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
                .font(Theme.Typography.body.font())
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(1)
                .padding(.leading, Theme.sectionHeaderX)
                .frame(maxWidth: .infinity, minHeight: Theme.Height.rowSidebar, alignment: .leading)
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
                    if showsArchivedHint(project) { archivedHint(project) }
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
            return (ids, ids.map { _ in Theme.Height.rowSidebar })
        case .project:
            let heights = app.state.projects.map { p in
                Theme.Height.rowSidebar * CGFloat(1 + (p.collapsed ? 0 : app.groupTasks(p.id).count))
                    + (!p.collapsed && showsArchivedHint(p) ? Theme.archivedHintHeight : 0)
            }
            return (app.state.projects.map(\.id), heights)
        case .tab, .leaf: return nil
        }
    }

    private func id(_ target: ActionTarget) -> UUID? {
        switch target {
        case .task(let id), .project(let id): id
        case .tab, .leaf: nil
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
            case .tab, .leaf: break
            }
        })
    }

    /// Project, 28 (§3.3): folder 16, name `body`; folded — its chats' most urgent dot and a chevron at the end;
    /// «⋯» and «+» on hover, on the highlight itself.
    private func projectRow(_ project: Project) -> some View {
        // Remote: gray only while the host is given up on (its disk is not stat'ed from here).
        let exists = app.isAvailable(project)
        let target = ActionTarget.project(project.id)
        let handlers = dragHandlers(target)
        let renaming = app.renaming == target
        let folded = project.collapsed ? app.foldedBadge(of: project.id) : nil
        return HoverRow(action: {
                            clicked(target)
                            app.setCollapsed(projectId: project.id, !project.collapsed)
                        },
                        // The filtered list is not the real order: no reordering while it is on.
                        onDrag: app.state.attentionOnly ? nil : handlers.onDrag, onDragEnd: handlers.onDragEnd,
                        forceHover: forcedHover(target)) { hover in
            GutterRow(collapsed: collapsed, trailing: Theme.projectRowTrailing, railReplacesMarker: true) {
                IconView(icon: .project, size: Theme.Icon.toolbar)
            } expanded: {
                HStack(spacing: 0) {
                    Group {
                        if renaming {
                            RenameField(app: app, target: target)
                        } else {
                            Text(project.name).foregroundStyle(Theme.ui.text1).lineLimit(1)
                        }
                    }
                    .font(Theme.Typography.body.font())
                    // Remote: the server glyph and host after the name (`text3`); the rail keeps the plain monogram.
                    if let host = project.host, !renaming {
                        HStack(spacing: Theme.railInset) {
                            IconView(icon: .sshHost, size: Theme.Icon.inline, tint: Theme.ui.text3)
                            Text(verbatim: host).lineLimit(1).truncationMode(.middle)
                                .font(Theme.Typography.secondary.font())
                                .foregroundStyle(Theme.ui.text3)
                        }
                        .padding(.leading, Theme.inlineGap)
                        .layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                    if !exists, project.host == nil {
                        Text(L10n.folderMissing).font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                            .padding(.leading, Theme.rowEndGap)
                            .opacity(hover ? 0 : 1)
                    }
                    // Folded: the most urgent state of its sessions (a count when more than one); under the hover actions.
                    if let folded {
                        HStack(spacing: Theme.rowStatusGap) {
                            StatusDot(state: folded.state)
                            if folded.count > 1 { Text(verbatim: "\(folded.count)").monospacedDigit() }
                        }
                        .font(Theme.Typography.secondary.font())
                        .foregroundStyle(Theme.ui.text2)
                        .padding(.leading, Theme.rowEndGap)
                        .opacity(hover ? 0 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.statusLabel(folded.state))
                    }
                    if project.collapsed {
                        IconView(icon: .chevronRight, size: Theme.Icon.inline, tint: Theme.ui.text3)
                            .padding(.leading, Theme.rowEndGap)
                            .opacity(hover ? 0 : 1)
                    }
                }
                .padding(.trailing, hover ? 2 * Theme.Height.controlSmall : 0)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 0) {
                        PopoverMenuButton { actionMenu(for: target, ctx: ctx) }
                        if exists {
                            IconButton(icon: .add, help: L10n.newTaskIn(project.name)) { ctx.newTask(project.id) }
                        }
                    }
                    .opacity(hover && !renaming ? 1 : 0)
                    .allowsHitTesting(hover && !renaming)
                }
            } rail: {
                // Rail: an outlined monogram tile; folded, its sessions are hidden in the rail too, so it carries
                // their most urgent dot.
                RailTile(text: monogram(project.name), state: folded?.state, selected: false, hover: hover, style: .project)
            }
            .opacity(exists ? 1 : Theme.Opacity.inactive)
        }
        .help(collapsed ? project.name : project.host.map { "\($0):\(project.path)" }
              ?? (exists ? project.path : L10n.folderMissing(project.path)))
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
    }

    private func showsArchivedHint(_ project: Project) -> Bool {
        !collapsed && !app.state.attentionOnly && app.allSessionsArchived(project.id)
    }

    /// Under an expanded project whose sessions are all closed: «Все сессии в архиве», «Открыть сессии ⌘Y» (scoped to
    /// the project), «+ Новая сессия» — one line each (the sidebar is narrow), at the sessions' indent, constant height.
    private func archivedHint(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.allArchived).foregroundStyle(Theme.ui.text3).lineLimit(1)
                .padding(.leading, Theme.rowStatusGap)  // in line with the buttons' titles
                .frame(height: Theme.archivedHintLine)
            hintButton(L10n.allArchivedOpen, shortcut: Shortcut.sessions.label) { app.showSessionsView(projectId: project.id) }
                .frame(height: Theme.archivedHintLine)
            hintButton("+ " + L10n.newTask, shortcut: nil) { ctx.newTask(project.id) }
                .frame(height: Theme.archivedHintLine)
                .disabled(!app.isAvailable(project))
        }
        .font(Theme.Typography.secondary.font())
        .padding(.leading, Theme.chatTextX + Theme.chatIndent - Theme.rowStatusGap)
        .padding(.trailing, Theme.sessionRowTrailing)
        .frame(maxWidth: .infinity, minHeight: Theme.archivedHintHeight, maxHeight: Theme.archivedHintHeight, alignment: .leading)
    }

    private func hintButton(_ title: String, shortcut: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.rowStatusGap) {
                Text(title).foregroundStyle(Theme.ui.text2).lineLimit(1)
                if let shortcut { Text(verbatim: shortcut).foregroundStyle(Theme.ui.text3).monospacedDigit() }
            }
            .padding(.horizontal, Theme.rowStatusGap)
        }
        .buttonStyle(HoverButtonStyle(radius: Theme.Radius.control))
    }

    // MARK: Sessions

    /// One line, 28 (§3.3): dot, name, and at the end what needs action — «ждёт ответа», «ошибка», «на лимите» —
    /// else the live branch (`mono` 11 `text3`). On hover pin and «⋯» take the end's place: nothing moves.
    private func taskRow(_ task: HangarTask) -> some View {
        let selected = !app.sessionsViewVisible && task.id == app.state.selectedTaskId  // «История» is the selected row while shown
        let target = ActionTarget.task(task.id)
        let dot = app.displayState(of: task)
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
            GutterRow(collapsed: collapsed, textX: Theme.chatTextX, indent: Theme.chatIndent, trailing: Theme.sessionRowTrailing,
                      railReplacesMarker: true) {
                StatusDot(state: dot, border: selected ? Theme.ui.onAccent : nil, borderWidth: selected ? Theme.railDotBorder : 0)
            } expanded: {
                HStack(spacing: Theme.rowEndGap) {
                    Group {
                        if app.renaming == target {
                            RenameField(app: app, target: target)
                        } else {
                            Text(task.name).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    // One slot for the row end and, on hover, the pin and «⋯» over it: the name never moves.
                    ZStack(alignment: .trailing) {
                        Color.clear.frame(width: Self.rowEndSlot(rowEndWidth(task, state: dot)), height: 1)
                        rowEnd(task, state: dot, selected: selected).opacity(showActions ? 0 : 1)
                    }
                }
                .overlay(alignment: .trailing) {
                    taskActions(task, target: target, shown: showActions)
                        .offset(x: Theme.rowActionsOverhang)
                }
            } rail: {
                RailTile(text: monogram(task.name), state: dot, selected: selected, hover: hover)
            }
            .font(Theme.Typography.body.font())
            .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text1)
            .opacity(offline ? Theme.Opacity.inactive : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.rowWithStatus(task.name, dot))
        .help(collapsed ? "\(app.project(task.projectId)?.name ?? "") › \(task.name)" : app.sessionStatus(of: task).text)
        .popoverContextMenu { actionMenu(for: target, ctx: ctx) }
        .onAppear { app.requestHead(task) }
        // A window focus reloads only the rows on screen (BranchModel).
        .onDisappear { app.hideHead(task) }
    }

    /// The row's end: the state word when it needs action, else the branch (nothing until it is known).
    @ViewBuilder private func rowEnd(_ task: HangarTask, state: AgentState, selected: Bool) -> some View {
        switch state {
        case .waiting, .failed, .limit:
            Text(L10n.rowStatus(state))
                .font(Theme.Typography.caption.font())
                .foregroundStyle(selected ? Theme.ui.onAccent : state == .failed ? Theme.ui.failedText : Theme.ui.waiting)
                .lineLimit(1)
                .fixedSize()
        case .working, .done, .idle:
            if let branch = app.head(of: task)?.title ?? task.branch {
                Text(verbatim: branch)
                    .font(Theme.Typography.monoSmall.font())
                    .foregroundStyle(selected ? Theme.ui.onAccent : Theme.ui.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // A fixed width: the branch keeps its place, a long chat name truncates instead.
                    .frame(width: Self.branchWidth(branch), alignment: .trailing)
            }
        }
    }

    /// The row end's constant width: its own (branch, state word) but at least the pin and «⋯» shown over it on
    /// hover (less the gap before it), so hovering never moves the name.
    static func rowEndSlot(_ own: CGFloat?) -> CGFloat {
        max(own ?? 0, 2 * Theme.Height.controlSmall - Theme.rowActionsOverhang - Theme.rowEndGap)
    }

    /// The width `rowEnd` takes: the state word or the branch; nil when it shows nothing.
    private func rowEndWidth(_ task: HangarTask, state: AgentState) -> CGFloat? {
        switch state {
        case .waiting, .failed, .limit:
            ceil((L10n.rowStatus(state) as NSString).size(withAttributes: [.font: Theme.Typography.caption.nsFont()]).width)
        case .working, .done, .idle:
            (app.head(of: task)?.title ?? task.branch).map(Self.branchWidth)
        }
    }

    /// The branch's width in a row: its own, up to `rowBranchMax` (§3.3).
    static func branchWidth(_ branch: String) -> CGFloat {
        let font = Theme.Typography.monoSmall.nsFont()
        return min(ceil((branch as NSString).size(withAttributes: [.font: font]).width), Theme.rowBranchMax)
    }

    /// Pin and «⋯» (shown on hover, no animation); the pin is white while pinned.
    private func taskActions(_ task: HangarTask, target: ActionTarget, shown: Bool) -> some View {
        HStack(spacing: 0) {
            IconButton(icon: .pin, tint: task.pinned ? Theme.ui.text0 : nil, help: task.pinned ? L10n.unpin : L10n.pin) {
                app.setPinned(task.id, !task.pinned)
            }
            PopoverMenuButton { actionMenu(for: target, ctx: ctx) }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }

    // MARK: Footer

    /// Limits (when any agent has data), then the footer 44 (§3.3): «Новый чат», «История» (lit while shown) and
    /// «Настройки» as icons, their names and keys in the tooltips; stacked in the rail.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if !app.limitRows.isEmpty {
                if collapsed { LimitsRailTile(app: app) } else { LimitsBlock(app: app) }
            }
            Group {
                if collapsed {
                    VStack(spacing: Theme.Space.s1) { footerButtons(spacer: false) }
                        .padding(.vertical, Theme.Space.s2)
                        .frame(width: Theme.sidebarRailWidth)
                } else {
                    HStack(spacing: Theme.Space.s1) { footerButtons(spacer: true) }
                        .padding(.horizontal, Theme.Space.s3)
                        .frame(height: Theme.sidebarFooterHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
        }
        .background(Theme.ui.bg1)
    }

    @ViewBuilder private func footerButtons(spacer: Bool) -> some View {
        IconButton(icon: .add, size: .regular, help: L10n.help(L10n.newTaskHelp, .newTask)) { ctx.newTask(nil) }
        IconButton(icon: .history, size: .regular, on: app.sessionsViewVisible, help: L10n.help(L10n.sessionsViewHelp, .sessions)) {
            app.showSessionsView()
        }
        if spacer { Spacer(minLength: 0) }
        IconButton(icon: .settings, size: .regular, help: L10n.help(L10n.settingsHelp, .settings), action: ctx.openSettings)
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
