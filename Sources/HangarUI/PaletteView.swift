import AgentStatus
import AppKit
import Observation
import SwiftUI
import Workspace

/// Why a `/…` query can't open a file here: no chat selected, or the chat is on a server (paths are this Mac's).
enum PalettePathBlock: Equatable { case noSession, remote }

/// The open palette's query, results and highlighted row. Built on open from snapshots; gone when closed (no work idle).
@MainActor @Observable final class PaletteModel {
    private(set) var query: String
    private(set) var sections: [PaletteSection] = []
    var highlight: String?
    /// Path mode: the listed folder's entries; nil while it is listed, or when it is not a folder (`pathMissing`).
    private(set) var pathEntries: [PathEntry]?
    private(set) var pathMissing = false
    /// nil: not loaded yet. Asked for once, the first time quick open (not `>`) is shown.
    @ObservationIgnored private var files: [String]?
    @ObservationIgnored private let tasks: [PaletteItem]
    @ObservationIgnored private let commands: [PaletteItem]
    @ObservationIgnored private var loadFiles: (() -> Void)?
    @ObservationIgnored let pathBlock: PalettePathBlock?
    @ObservationIgnored let home: String
    @ObservationIgnored private let listDirectory: @Sendable (String) -> [PathEntry]?
    /// The folder `pathEntries` belong to (or is being listed): typing within one folder lists it once.
    @ObservationIgnored private var listedDir: String?
    @ObservationIgnored private var listing: Task<Void, Never>?

    init(tasks: [PaletteItem], files: [String]?, commands: [PaletteItem], query: String, loadFiles: (() -> Void)? = nil,
         pathBlock: PalettePathBlock? = nil, home: String = NSHomeDirectory(),
         listDirectory: @escaping @Sendable (String) -> [PathEntry]? = paletteListDirectory) {
        self.tasks = tasks
        self.files = files
        self.commands = commands
        self.query = query
        self.loadFiles = loadFiles
        self.pathBlock = pathBlock
        self.home = home
        self.listDirectory = listDirectory
        update()
    }

    var mode: PaletteMode { paletteMode(query) }
    /// ⇧⌘P and a typed `>`: commands only.
    var isCommands: Bool { mode == .commands }

    /// The «загрузка…» row: quick open with a query while the task's files are still being listed.
    var showsLoading: Bool { files == nil && mode == .quick && !query.allSatisfy(\.isWhitespace) }

    /// The folder a path query lists, for the section header (`~/…`).
    var pathDir: String? { palettePathQuery(query, home: home).map { paletteAbbreviated($0.dir, home: home) } }

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        update()
    }

    func setFiles(_ list: [String]) {
        files = list
        update(keepHighlight: true)
    }

    /// ↩ / Tab on a path row: a folder becomes the query (true); a file is left to the caller.
    func completePath(_ item: PaletteItem) -> Bool {
        guard case .path(let path, let isDir) = item.target, isDir else { return false }
        setQuery(palettePathCompletion(query, entry: (path as NSString).lastPathComponent, isDir: true))
        return true
    }

    private func update(keepHighlight: Bool = false) {
        if files == nil, mode == .quick, let load = loadFiles {
            loadFiles = nil
            load()
        }
        if pathBlock == nil, let p = palettePathQuery(query, home: home) {
            if p.dir != listedDir { list(p.dir) }
            sections = pathEntries.map { entries in
                let items = palettePathItems(dir: p.dir, name: p.name, entries: entries)
                return items.isEmpty ? [] : [PaletteSection(kind: .path, items: items)]
            } ?? []
        } else {
            sections = mode == .path ? [] : paletteSections(query: query, tasks: tasks, files: files ?? [], commands: commands)
        }
        let ids = sections.flatMap(\.items).map(\.id)
        if !(keepHighlight && highlight.map(ids.contains) == true) { highlight = ids.first }
    }

    /// One folder listing off the main thread; a newer folder wins.
    private func list(_ dir: String) {
        listing?.cancel()
        listedDir = dir
        pathEntries = nil
        pathMissing = false
        let read = listDirectory
        listing = Task { [weak self] in
            let entries = await Task.detached { read(dir) }.value
            guard let self, !Task.isCancelled, self.listedDir == dir else { return }
            self.pathEntries = entries ?? []
            self.pathMissing = entries == nil
            self.update(keepHighlight: true)
        }
    }

    func move(_ delta: Int) { highlight = movedHighlight(highlight, by: delta, in: sections.flatMap(\.items).map(\.id)) }

    var highlighted: PaletteItem? { sections.lazy.flatMap(\.items).first { $0.id == self.highlight } }
}

/// ↑/↓ over the visible rows (all sections as one list), clamped at the ends; an unknown or nil highlight lands on
/// the first row.
func movedHighlight(_ current: String?, by delta: Int, in ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let i = ids.firstIndex(of: current) else { return ids[0] }
    return ids[min(max(i + delta, 0), ids.count - 1)]
}

/// Borderless panels refuse key status by default; the search field needs it.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A child panel over the main window: centered, near the top; closes on Esc, on a choice and when it loses key.
@MainActor final class PaletteController {
    let model: PaletteModel
    let panel: PalettePanel
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private let onClose: () -> Void

    init(app: AppState, model: PaletteModel, parent: NSWindow, choose: @escaping (PaletteItem) -> Void, close: @escaping () -> Void) {
        self.model = model
        self.parent = parent
        onClose = close
        panel = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = parent.appearance
        let host = NSHostingView(rootView: PaletteView(app: app, model: model, choose: choose, close: close))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        place()
        parent.addChildWindow(panel, ordered: .above)
        if !Motion.reduced { panel.alphaValue = 0 }
        #if DEBUG
        // A non-activating panel takes the keyboard even while another app is frontmost: a debug run must not.
        if ProcessInfo.processInfo.environment["HANGAR_DEBUG_NO_ACTIVATE"] != nil { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
        #else
        panel.makeKeyAndOrderFront(nil)
        #endif
        if !Motion.reduced {
            NSAnimationContext.runAnimationGroup { $0.duration = Theme.paletteFadeIn; panel.animator().alphaValue = 1 }
        }
        panel.invalidateShadow()
        let center = NotificationCenter.default
        observers = [
            // A click elsewhere (the window, another app) closes it, as in Raycast.
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
        ]
    }

    private func place() {
        guard let parent else { return }
        let size = panel.frame.size
        let top = parent.frame.maxY - parent.frame.height * Theme.paletteTopFraction
        panel.setFrameOrigin(NSPoint(x: (parent.frame.midX - size.width / 2).rounded(), y: (top - size.height).rounded()))
    }

    func dismiss() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

struct PaletteView: View {
    let app: AppState
    let model: PaletteModel
    let choose: (PaletteItem) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.paletteGap) {
                IconView(icon: modeIcon, tint: Theme.ui.text2)
                PickerSearchField(text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                                  placeholder: L10n.paletteSearch,
                                  font: Theme.Typography.title.nsFont(),
                                  onMove: { model.move($0) },
                                  onSubmit: { if let item = model.highlighted { choose(item) } },
                                  onCancel: close,
                                  onTab: complete)
                // Which list this is: the leading `>` / `/` alone is easy to miss.
                Text(L10n.paletteMode(model.mode))
                    .font(Theme.Typography.caption.font(.semibold))
                    .foregroundStyle(Theme.ui.text3)
                    .fixedSize()
            }
            .padding(.vertical, Theme.paletteQueryPaddingV)
            .padding(.horizontal, Theme.palettePaddingH)
            Rectangle().fill(Theme.ui.line2).frame(height: 1)
            list.frame(height: Theme.paletteListHeight)
            Rectangle().fill(Theme.ui.line2).frame(height: 1)
            Text(L10n.paletteHint(model.mode))
                .font(Theme.Typography.caption.font())
                .foregroundStyle(Theme.ui.text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Theme.paletteSectionHeight, alignment: .leading)
                .padding(.horizontal, Theme.palettePaddingH)
        }
        .frame(width: Theme.paletteWidth)
        .background(Theme.ui.bg2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.paletteRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paletteRadius).strokeBorder(Theme.ui.line2, lineWidth: 1))
    }

    private var modeIcon: Icon {
        switch model.mode {
        case .quick: .search
        case .commands: .chevronRight
        case .path: .project
        }
    }

    /// Tab in path mode: the highlighted entry's name into the query (a folder — and its entries); else nothing.
    private func complete() -> Bool {
        guard model.mode == .path else { return false }
        if let item = model.highlighted, !model.completePath(item), case .path(let path, _) = item.target {
            model.setQuery(palettePathCompletion(model.query, entry: (path as NSString).lastPathComponent, isDir: false))
        }
        return true
    }

    /// What an empty list says; nil — nothing yet (a folder being listed).
    private var emptyText: String? {
        switch model.mode {
        case .quick: return L10n.paletteEmpty
        case .commands: return L10n.paletteNoCommand
        case .path:
            if let block = model.pathBlock { return L10n.palettePathBlocked(block) }
            if model.pathMissing { return L10n.paletteNoFolder }
            return model.pathEntries == nil ? nil : L10n.paletteEmpty
        }
    }

    @ViewBuilder private var list: some View {
        if model.sections.isEmpty, !model.showsLoading {
            Text(emptyText ?? "")
                .font(Theme.Typography.body.font())
                .foregroundStyle(Theme.ui.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.palettePaddingH)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sections, id: \.kind) { section in
                            // A path's entries are headed by their folder.
                            Text(section.kind == .path ? model.pathDir ?? "" : L10n.paletteSection(section.kind))
                                .font(Theme.Typography.caption.font(.semibold))
                                .foregroundStyle(Theme.ui.text3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(section.kind == .path ? model.pathDir ?? "" : "")
                                .frame(maxWidth: .infinity, minHeight: Theme.paletteSectionHeight, alignment: .bottomLeading)
                                .padding(.horizontal, Theme.palettePaddingH)
                            ForEach(section.items) { row($0) }
                        }
                        if model.showsLoading {
                            Text(L10n.paletteLoading)
                                .font(Theme.Typography.secondary.font())
                                .foregroundStyle(Theme.ui.text3)
                                .frame(maxWidth: .infinity, minHeight: Theme.paletteRowHeight, alignment: .leading)
                                .padding(.horizontal, Theme.palettePaddingH)
                        }
                    }
                    .padding(.bottom, Theme.paletteRowInset)
                }
                .onChange(of: model.highlight) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        let on = model.highlight == item.id
        return HStack(spacing: Theme.paletteGap) {
            marker(item).frame(width: Theme.paletteMarker)
            // The title first; the project / folder and the branch share what is left (a Spacer only takes the rest).
            title(item, on: on).layoutPriority(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(Theme.Typography.secondary.font())  // a file's folder as in the inspector (§3.7)
                    .foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text3)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailing(item, on: on)
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.palettePaddingH - Theme.paletteRowInset)
        .frame(height: Theme.paletteRowHeight)
        .environment(\.rowSelectedText, on ? Theme.ui.onAccent : nil)
        .background(RoundedRectangle(cornerRadius: Theme.paletteRowRadius).fill(on ? Theme.ui.selectedFocus : .clear))
        .padding(.horizontal, Theme.paletteRowInset)
        .contentShape(Rectangle())
        .onHover { if $0 { model.highlight = item.id } }
        .onTapGesture { choose(item) }
        .pointingHand()
        .help(fullPath(item))
        .id(item.id)
    }

    /// The row's full text for the tooltip (the row truncates it): a file's path, a chat's name and project.
    private func fullPath(_ item: PaletteItem) -> String {
        switch item.target {
        case .file(let path): path
        case .path(let path, _): paletteAbbreviated(path, home: model.home)
        default: item.subtitle.isEmpty ? item.title : item.title + " · " + item.subtitle
        }
    }

    /// Matched characters bright and semibold, the rest `text`.
    private func title(_ item: PaletteItem, on: Bool) -> some View {
        var s = AttributedString()
        let hits = Set(item.positions)
        for (i, ch) in item.title.enumerated() {
            var part = AttributedString(String(ch))
            if hits.contains(i) {
                part.foregroundColor = on ? Theme.ui.onAccent : Theme.ui.text0
                part.font = Theme.Typography.body.font(.semibold)
            }
            s += part
        }
        return Text(s)
            .font(Theme.Typography.body.font())
            .foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text1)
            .truncationMode(.middle)
    }

    @ViewBuilder private func marker(_ item: PaletteItem) -> some View {
        switch item.target {
        case .task(let id):
            let task = app.state.tasks.first { $0.id == id }
            StatusDot(state: task.map { app.state(of: $0) } ?? .idle, seen: task.map(app.doneSeen) ?? false)
        case .file: FileIconView(name: item.title)  // the Files tab's theme icon
        case .path(_, isDir: true): IconView(icon: .project)  // a line glyph: readable on the highlighted row
        case .path: FileIconView(name: item.title)
        case .command(let sc): IconView(icon: paletteIcon(sc))
        case .action: IconView(icon: .play)
        }
    }

    /// Task: `⎇ branch` and the SSH host; command: its key.
    @ViewBuilder private func trailing(_ item: PaletteItem, on: Bool) -> some View {
        switch item.target {
        case .task(let id):
            let task = app.state.tasks.first { $0.id == id }
            HStack(spacing: Theme.paletteGap) {
                if let branch = task?.branch {
                    HStack(spacing: Theme.paletteIconGap) {
                        IconView(icon: .branch, size: Theme.Icon.inline)
                        Text(branch).font(Theme.Typography.mono.font()).truncationMode(.middle)
                    }
                }
                if let host = task.flatMap({ app.project($0.projectId)?.host }) {
                    HStack(spacing: Theme.paletteIconGap) {
                        IconView(icon: .sshHost, size: Theme.Icon.inline)
                        Text(host).font(Theme.Typography.secondary.font())
                    }
                }
            }
            .foregroundStyle(on ? Theme.ui.onAccent : Theme.ui.text3)
        case .command(let sc): ShortcutHint(text: sc.label)
        case .action, .file, .path: EmptyView()
        }
    }
}

/// Command glyphs: the same icons as the buttons and menus that run them.
func paletteIcon(_ sc: Shortcut) -> Icon {
    switch sc {
    case .newTask, .newFreeChat, .newSubSession, .newTab: .add
    case .addProject, .inspectorFiles: .project
    case .closeTab: .close
    case .splitRight: .splitRight
    case .splitDown: .splitDown
    case .archiveTask: .archive
    case .rename: .rename
    case .prevTask: .chevronUp
    case .nextTask: .chevronDown
    case .prevTab: .chevronLeft
    case .nextTab, .tab, .focusSplit, .quickOpen, .commandPalette, .attentionFilter: .chevronRight
    case .toggleSidebar: .sidebarLeft
    case .toggleInspector: .sidebarRight
    case .inspectorChanges: .diff
    case .inspectorGit: .branch
    case .toggleDrawer: .shell
    case .limits: .limits
    case .nextAttention: .bell
    case .runAction: .play
    case .nextWorking: .chevronDown
    case .revealInFinder: .finder
    case .copyPath: .copy
    case .settings: .settings
    case .sessions: .history
    case .findInFiles: .search
    case .shortcuts: .more
    }
}
