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
}

/// Every row action (context menus) lives here, so Task 6b extends one place.
@MainActor struct SidebarMenus {
    let app: AppState
    let actions: SidebarActions

    @ViewBuilder func task(_ task: HangarTask) -> some View {
        if task.archived {
            Button("Восстановить") { app.restore(taskId: task.id) }
        } else {
            Button("Переименовать…") { actions.renameTask(task) }
            Button(task.pinned ? "Открепить" : "Закрепить") { app.setPinned(task.id, !task.pinned) }
            Divider()
            Button("Архивировать") { app.archive(taskId: task.id) }
        }
    }

    @ViewBuilder func project(_ project: Project) -> some View {
        Button("Новая задача") { actions.newTask(project.id) }
        Button("Переименовать…") { actions.renameProject(project) }
    }
}

private func folderExists(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// One sidebar row. The marker (dot/icon) sits at `Theme.gutterMarkerX` in both expanded and rail mode;
/// collapsing only cross-fades the labels, so nothing moves (only the sidebar width animates).
private struct GutterRow<Marker: View, Expanded: View, Rail: View>: View {
    let collapsed: Bool
    var height = Theme.railRowHeight
    var textX = Theme.gutterTextX
    @ViewBuilder var marker: Marker
    @ViewBuilder var expanded: Expanded
    @ViewBuilder var rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            marker
                .frame(width: Theme.iconSize, height: Theme.iconSize)
                .offset(x: Theme.gutterMarkerX - Theme.iconSize / 2)
            rail
                .padding(.leading, Theme.railTextX)
                .opacity(collapsed ? 1 : 0)
            expanded
                .padding(.leading, textX)
                .padding(.trailing, Theme.rowPaddingH)
                .opacity(collapsed ? 0 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
    }
}

/// Section header (caps, `text3`, 11): fades out in rail mode but keeps its height so rows don't jump.
private struct SectionHeader: View {
    let title: String
    let collapsed: Bool
    var plusHelp = ""
    var plus: (() -> Void)?

    var body: some View {
        HoverRow { hover in
            HStack(spacing: 0) {
                Text(title.uppercased()).tracking(Theme.fontSize.small * Theme.fontSize.projectTracking)
                Spacer(minLength: 0)
                if let plus {
                    Button(action: plus) { IconView(icon: .newTask, size: Theme.smallIconSize).padding(Theme.railInset) }
                        .buttonStyle(HoverButtonStyle(radius: Theme.railItemRadius))
                        .opacity(hover ? 1 : 0)
                        .help(plusHelp)
                }
            }
            .font(.system(size: Theme.fontSize.small))
            .foregroundStyle(Theme.ui.text3)
            .padding(.leading, Theme.sectionTextX)
            .padding(.trailing, Theme.rowPaddingH - Theme.railInset)
            .frame(height: Theme.projectRowHeight)
            .opacity(collapsed ? 0 : 1)
            .animation(Motion.ease(Theme.sidebarAnimation), value: collapsed)
        }
        .allowsHitTesting(!collapsed)
        .padding(.top, Theme.sectionGap)
    }
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
        .font(.system(size: Theme.fontSize.base))
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
                    Text("Новая задача").foregroundStyle(Theme.ui.textStrong)
                    Spacer(minLength: 0)
                    Text("⌘N").font(.system(size: Theme.fontSize.footer)).foregroundStyle(Theme.ui.text2)
                }
            } rail: { EmptyView() }
            .contentShape(Rectangle())
        }
        .buttonStyle(FilledRowStyle(width: visibleWidth - 2 * Theme.railInset))
        .help("Новая задача ⌘N")
    }

    // MARK: Pinned

    @ViewBuilder private var pinnedSection: some View {
        let pinned = app.pinnedTasks
        if !pinned.isEmpty {
            SectionHeader(title: "Закреплённые", collapsed: collapsed)
            ForEach(pinned) { task in taskRow(task, projectName: app.project(task.projectId)?.name, indent: false) }
        }
    }

    // MARK: Projects

    @ViewBuilder private var projectsSection: some View {
        SectionHeader(title: "Проекты", collapsed: collapsed, plusHelp: "Добавить проект", plus: actions.addProject)
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
                        .font(.system(size: Theme.fontSize.row, weight: .semibold))
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
                        .help("Новая задача в \(project.name)")
                    } else {
                        Text("папка не найдена").font(.system(size: Theme.fontSize.small)).foregroundStyle(Theme.ui.text3)
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
        .help(collapsed ? project.name : (exists ? project.path : "папка не найдена: \(project.path)"))
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
                        .help(task.pinned ? "Открепить" : "Закрепить")
                    }
                }
            } rail: {
                Text(monogram(task.name))
                    .font(.system(size: Theme.fontSize.small, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: Theme.fontSize.row))
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
                            Text("АРХИВ").tracking(Theme.fontSize.small * Theme.fontSize.projectTracking)
                            Text("\(archived.count)").font(.system(size: Theme.fontSize.counter))
                            Spacer(minLength: 0)
                            IconView(icon: archiveOpen ? .chevronDown : .chevronRight, size: Theme.smallIconSize)
                        }
                        .font(.system(size: Theme.fontSize.small))
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
                                .font(.system(size: Theme.fontSize.row))
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
            HoverRow { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .settings)
                } expanded: {
                    HStack(spacing: 0) {
                        Text("Настройки")
                        Spacer(minLength: 0)
                        Menu {
                            Button("Добавить проект…", action: actions.addProject)
                            // shortcut: keep-awake arrives in stage 5.2
                            Button("Не засыпать") {}.disabled(true)
                        } label: { Image(nsImage: Icon.more.image).renderingMode(.template) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Ещё")
                    }
                    .font(.system(size: Theme.fontSize.footer))
                    .foregroundStyle(Theme.ui.text3)
                } rail: { EmptyView() }
            }
            // shortcut: settings screen is a later stage; config lives in ~/.config/hangar/config.toml
            .help("Настройки — ~/.config/hangar/config.toml")
            HoverRow(action: actions.toggleCollapsed) { _ in
                GutterRow(collapsed: collapsed, height: Theme.footerRowHeight) {
                    IconView(icon: .sidebarToggle)
                } expanded: {
                    HStack(spacing: 0) {
                        Text("Свернуть")
                        Spacer(minLength: 0)
                        Text("⌘0")
                    }
                    .font(.system(size: Theme.fontSize.footer))
                    .foregroundStyle(Theme.ui.text3)
                } rail: { EmptyView() }
            }
            .help(collapsed ? "Развернуть сайдбар ⌘0" : "Свернуть сайдбар ⌘0")
        }
        .padding(.vertical, Theme.railInset)
        .background(Theme.ui.bottomBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }
}

/// Fill follows the visible sidebar width (content is laid out wider and clipped in rail mode).
private struct FilledRowStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Body(label: configuration.label, pressed: configuration.isPressed, width: width)
    }

    private struct Body<Label: View>: View {
        let label: Label
        let pressed: Bool
        let width: CGFloat
        @State private var hover = false

        var body: some View {
            label
                .background(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.railItemRadius)
                        .fill(Theme.ui.hoverStrong)
                        .brightness(pressed ? -0.03 : hover ? 0.04 : 0)
                        .frame(width: max(0, width))
                        .padding(.leading, Theme.railInset)
                }
                .onHover { h in withAnimation(Motion.ease(Theme.hoverFade)) { hover = h } }
        }
    }
}
