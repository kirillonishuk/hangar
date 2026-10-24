import AgentStatus
import AppKit
import Observation
import SwiftUI
import Workspace

/// The open palette's query, results and highlighted row. Built on open from snapshots; gone when closed (no work idle).
@MainActor @Observable final class PaletteModel {
    private(set) var query = ""
    private(set) var filesOnly: Bool
    private(set) var sections: [PaletteSection] = []
    var highlight: String?
    @ObservationIgnored private let tasks: [PaletteItem]
    @ObservationIgnored private let files: [String]
    @ObservationIgnored private let commands: [PaletteItem]

    init(tasks: [PaletteItem], files: [String], commands: [PaletteItem], filesOnly: Bool) {
        self.tasks = tasks
        self.files = files
        self.commands = commands
        self.filesOnly = filesOnly
        update()
    }

    func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        update()
    }

    func setFilesOnly(_ on: Bool) {
        guard on != filesOnly else { return }
        filesOnly = on
        update()
    }

    private func update() {
        sections = paletteSections(query: query, tasks: tasks, files: files, commands: commands, filesOnly: filesOnly)
        highlight = sections.first?.items.first?.id
    }

    func move(_ delta: Int) { highlight = movedHighlight(highlight, by: delta, in: sections.flatMap(\.items).map(\.id)) }

    /// No list from the inspector (no task, or it hasn't loaded this one: it loads only while shown).
    var hasFiles: Bool { !files.isEmpty }

    var highlighted: PaletteItem? { sections.lazy.flatMap(\.items).first { $0.id == self.highlight } }
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
        if Motion.reduced {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
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
            PickerSearchField(text: Binding(get: { model.query }, set: { model.setQuery($0) }),
                              placeholder: model.filesOnly ? L10n.paletteSearchFiles : L10n.paletteSearch,
                              font: .systemFont(ofSize: Theme.paletteQueryFont),
                              onMove: { model.move($0) },
                              onSubmit: { if let item = model.highlighted { choose(item) } },
                              onCancel: close)
                .padding(.vertical, Theme.paletteQueryPaddingV)
                .padding(.horizontal, Theme.palettePaddingH)
            Rectangle().fill(Theme.ui.lineSheet).frame(height: 1)
            list.frame(height: Theme.paletteListHeight)
        }
        .frame(width: Theme.paletteWidth)
        .background(Theme.ui.sheet)
        .clipShape(RoundedRectangle(cornerRadius: Theme.paletteRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.paletteRadius).strokeBorder(Theme.ui.controlBorderStrong, lineWidth: 1))
    }

    @ViewBuilder private var list: some View {
        if model.sections.isEmpty {
            Text(model.filesOnly && !model.hasFiles ? L10n.help(L10n.paletteNoFiles, .toggleInspector) : L10n.paletteEmpty)
                .font(.system(size: Theme.paletteRowFont))
                .foregroundStyle(Theme.ui.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.sections, id: \.kind) { section in
                            Text(L10n.paletteSection(section.kind))
                                .font(.system(size: Theme.fontSize.small, weight: .semibold))
                                .foregroundStyle(Theme.ui.text3)
                                .frame(maxWidth: .infinity, minHeight: Theme.paletteSectionHeight, alignment: .bottomLeading)
                                .padding(.horizontal, Theme.palettePaddingH)
                            ForEach(section.items) { row($0) }
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
            title(item, on: on)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: Theme.paletteDetailFont, design: item.kind == .file ? .monospaced : .default))
                    .foregroundStyle(Theme.ui.text3)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            trailing(item)
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.palettePaddingH - Theme.paletteRowInset)
        .frame(height: Theme.paletteRowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.paletteRowRadius).fill(on ? Theme.ui.selection : .clear))
        .padding(.horizontal, Theme.paletteRowInset)
        .contentShape(Rectangle())
        .onHover { if $0 { model.highlight = item.id } }
        .onTapGesture { choose(item) }
        .pointingHand()
        .id(item.id)
    }

    /// Matched characters bright and semibold, the rest `text`.
    private func title(_ item: PaletteItem, on: Bool) -> some View {
        var s = AttributedString()
        let hits = Set(item.positions)
        for (i, ch) in item.title.enumerated() {
            var part = AttributedString(String(ch))
            if hits.contains(i) {
                part.foregroundColor = Theme.ui.textStrong
                part.font = .system(size: Theme.paletteRowFont, weight: .semibold)
            }
            s += part
        }
        return Text(s)
            .font(.system(size: Theme.paletteRowFont))
            .foregroundStyle(on ? Theme.ui.selectionText : Theme.ui.text)
            .truncationMode(.tail)
    }

    @ViewBuilder private func marker(_ item: PaletteItem) -> some View {
        switch item.target {
        case .task(let id):
            StatusDot(state: app.state.tasks.first { $0.id == id }.map { app.state(of: $0) } ?? .idle)
        case .file: IconView(icon: .editor)
        case .command(let sc): IconView(icon: paletteIcon(sc))
        }
    }

    /// Task: `⎇ branch` and the SSH host; command: its key.
    @ViewBuilder private func trailing(_ item: PaletteItem) -> some View {
        switch item.target {
        case .task(let id):
            let task = app.state.tasks.first { $0.id == id }
            HStack(spacing: Theme.paletteGap) {
                if let branch = task?.branch {
                    HStack(spacing: Theme.paletteIconGap) {
                        IconView(icon: .branch, size: Theme.worktreeEndIcon)
                        Text(branch).font(.system(size: Theme.paletteDetailFont, design: .monospaced)).truncationMode(.middle)
                    }
                }
                if let host = task.flatMap({ app.project($0.projectId)?.host }) {
                    HStack(spacing: Theme.paletteIconGap) {
                        IconView(icon: .sshHost, size: Theme.worktreeEndIcon)
                        Text(host).font(.system(size: Theme.paletteDetailFont))
                    }
                }
            }
            .foregroundStyle(Theme.ui.text3)
        case .command(let sc): ShortcutHint(text: sc.label)
        case .file: EmptyView()
        }
    }
}

/// Command glyphs: the same icons as the buttons and menus that run them.
func paletteIcon(_ sc: Shortcut) -> Icon {
    switch sc {
    case .newTask, .newTab: .add
    case .addProject, .inspectorFiles: .project
    case .closeTab: .close
    case .splitRight: .splitRight
    case .splitDown: .splitDown
    case .archiveTask: .archive
    case .rename: .rename
    case .prevTask: .chevronUp
    case .nextTask: .chevronDown
    case .prevTab, .nextTab, .tab, .focusSplit, .palette, .paletteFiles: .chevronRight
    case .toggleSidebar: .sidebarLeft
    case .toggleInspector: .sidebarRight
    case .inspectorChanges: .diff
    case .toggleDrawer: .shell
    case .limits: .limits
    case .revealInFinder: .finder
    case .copyPath: .copy
    case .settings: .settings
    }
}
