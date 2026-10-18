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

/// Window-level actions the sidebar triggers (panels, sheets, alerts live in MainWindowController).
struct SidebarActions {
    var addProject: () -> Void
    var newTask: (UUID?) -> Void  // project id; nil = selected/last project
    var renameTask: (HangarTask) -> Void
    var renameProject: (Project) -> Void
    var toggleCollapsed: () -> Void
    var openSettings: () -> Void
}

/// Every row action (context menus) lives here, so Task 6b extends one place.
@MainActor struct SidebarMenus {
    let app: AppState
    let actions: SidebarActions

    @ViewBuilder func task(_ task: HangarTask) -> some View {
        if task.archived {
            Button(L10n.restore) { app.restore(taskId: task.id) }
        } else {
            Button(L10n.renameEllipsis) { actions.renameTask(task) }
            Button(task.pinned ? L10n.unpin : L10n.pin) { app.setPinned(task.id, !task.pinned) }
            Divider()
            Button(L10n.archive) { app.archive(taskId: task.id) }
        }
    }

    @ViewBuilder func project(_ project: Project) -> some View {
        Button(L10n.newTask) { actions.newTask(project.id) }
        Button(L10n.renameEllipsis) { actions.renameProject(project) }
    }
}

private func folderExists(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

struct SidebarView: View {
    let app: AppState
    let actions: SidebarActions
    @State private var archiveOpen = false

    private var collapsed: Bool { app.state.sidebarCollapsed }
    private var menus: SidebarMenus { SidebarMenus(app: app, actions: actions) }

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
                        // SSH HOSTS section slot: stage 6.
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
        .background(Theme.ui.sidebar)
        .ignoresSafeArea()
    }

    // MARK: Top

    /// Filled full-width button; the fill is inset so the `+` keeps the shared marker x.
    private func newTaskButton(visibleWidth: CGFloat) -> some View {
        Button { actions.newTask(nil) } label: {
            GutterRow(collapsed: collapsed) {
                IconView(icon: .newTask, active: true)
            } expanded: {
                HStack(spacing: 0) {
                    Text(L10n.newTask).foregroundStyle(Theme.ui.textStrong)
                    Spacer(minLength: 0)
                    Text("⌘N").font(.system(size: Theme.fontSize.footer)).foregroundStyle(Theme.ui.text2)
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

    // MARK: Projects

    @ViewBuilder private var projectsSection: some View {
        SectionHeader(title: L10n.sectionProjects, collapsed: collapsed, plusHelp: L10n.addProject,
                      plusAlwaysVisible: app.state.projects.isEmpty, plus: actions.addProject)
        ForEach(app.state.projects) { project in
            projectRow(project)
            if !project.collapsed {
                ForEach(app.groupTasks(project.id)) { task in taskRow(task, projectName: nil, indent: true) }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let exists = folderExists(project.path)
        return HoverRow(action: { app.setCollapsed(projectId: project.id, !project.collapsed) }) { hover in
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    IconView(icon: project.collapsed ? .chevronRight : .chevronDown, size: Theme.smallIconSize)
                        .frame(width: Theme.smallIconSize)
                        .padding(.leading, Theme.projectChevronX - Theme.smallIconSize / 2)
                    Text(project.name)
                        .font(.system(size: Theme.fontSize.sidebarRow, weight: .semibold))
                        .foregroundStyle(Theme.ui.text)
                        .lineLimit(1)
                        .padding(.leading, Theme.projectTextX - Theme.projectChevronX - Theme.smallIconSize / 2)
                    Spacer(minLength: Theme.statusDot)
                    if exists {
                        Button { actions.newTask(project.id) } label: {
                            IconView(icon: .newTask, size: Theme.smallIconSize).padding(Theme.railInset)
                        }
                        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                        .opacity(hover ? 1 : 0)
                        .help(L10n.newTaskIn(project.name))
                    } else {
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
        .help(collapsed ? project.name : (exists ? project.path : L10n.folderMissing(project.path)))
        .contextMenu { menus.project(project) }
    }

    // MARK: Tasks

    /// `projectName` set → pinned row (project shown after the name); `indent` → under its project.
    private func taskRow(_ task: HangarTask, projectName: String?, indent: Bool) -> some View {
        let selected = task.id == app.state.selectedTaskId
        return HoverRow(selected: selected, action: { app.select(taskId: task.id) }) { hover in
            GutterRow(collapsed: collapsed) {
                if case .worktree = task.mode { IconView(icon: .worktree, active: selected) } else { StatusDot() }
            } expanded: {
                HStack(spacing: Theme.railInset * 1.5) {
                    Text(task.name).lineLimit(1).truncationMode(.tail)
                    if let projectName {
                        Text(projectName).lineLimit(1).foregroundStyle(Theme.ui.text3)
                    }
                    Spacer(minLength: 0)
                    if task.pinned || hover {
                        Button { app.setPinned(task.id, !task.pinned) } label: {
                            IconView(icon: task.pinned ? .pinned : .pin, active: selected, size: Theme.smallIconSize)
                        }
                        .buttonStyle(.plain)
                        .help(task.pinned ? L10n.unpin : L10n.pin)
                    }
                }
            } rail: {
                Text(monogram(task.name))
                    .font(.system(size: Theme.fontSize.small, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: Theme.fontSize.sidebarRow))
            .foregroundStyle(selected ? Theme.ui.selectionText : Theme.ui.textRow)
        }
        .help(collapsed ? "\(app.project(task.projectId)?.name ?? "") › \(task.name)" : "")
        .contextMenu { menus.task(task) }
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
                        HStack(spacing: Theme.railInset * 1.5) {
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
                        HoverRow { _ in
                            GutterRow(collapsed: collapsed) { EmptyView() } expanded: {
                                HStack(spacing: Theme.railInset * 1.5) {
                                    Text(task.name).lineLimit(1)
                                    Text(app.project(task.projectId)?.name ?? "").lineLimit(1).foregroundStyle(Theme.ui.text3)
                                }
                                .font(.system(size: Theme.fontSize.sidebarRow))
                                .foregroundStyle(Theme.ui.text2)
                            } rail: { EmptyView() }
                        }
                        .contextMenu { menus.task(task) }
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
            HoverRow(action: actions.openSettings) { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .settings)
                } expanded: {
                    HStack(spacing: 0) {
                        Text(L10n.settings)
                        Spacer(minLength: 0)
                        Menu {
                            Button(L10n.addProjectEllipsis, action: actions.addProject)
                            // shortcut: keep-awake arrives in stage 5.2
                            Button(L10n.keepAwake) {}.disabled(true)
                        } label: { Image(nsImage: Icon.more.image).renderingMode(.template) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(L10n.more)
                    }
                    .font(.system(size: Theme.fontSize.sidebarFooter))
                    .foregroundStyle(Theme.ui.text3)
                } rail: { EmptyView() }
            }
            .help(L10n.settingsHelp)
            HoverRow(action: actions.toggleCollapsed) { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .sidebarToggle)
                } expanded: {
                    HStack(spacing: 0) {
                        Text(L10n.collapse)
                        Spacer(minLength: 0)
                        Text("⌘0")
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
