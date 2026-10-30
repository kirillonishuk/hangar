import AppKit
import Foundation
import Git
import Workspace

/// The toolbar's branch switcher (spec design-system §3.2, decision #114) for one chat: its lists, the new-branch
/// step, the action running, the last refusal. The menu closes after a switch or a new branch; a refusal stays in it.
@MainActor @Observable final class BranchSwitcher {
    let taskId: UUID
    private(set) var choices: BranchChoices?
    private(set) var loadError: String?
    /// «Новая ветка от …» was picked: the field takes the new branch's name.
    var creating = false
    /// «Переключаю на x…» while git runs; everything is inactive.
    private(set) var progress: String?
    private(set) var refusal: PopoverMenuNote?
    @ObservationIgnored private weak var app: AppState?
    /// The menu this switcher is shown in: closed after a done action, if still open.
    @ObservationIgnored weak var panel: PopoverMenuPanel?

    init(app: AppState, taskId: UUID) {
        self.app = app
        self.taskId = taskId
    }

    private var task: HangarTask? { app?.state.tasks.first { $0.id == taskId } }

    func load() async {
        guard let app, let task else { return }
        do {
            choices = try await app.branchChoices(of: task)
            loadError = nil
        } catch {
            if choices == nil { loadError = error.localizedDescription }
        }
    }

    func entries(_ query: String) -> [PopoverMenuEntry] {
        branchSwitcherEntries(choices, query: query, creating: creating, busy: progress != nil, now: Date(),
                              switchTo: { [weak self] in self?.switchTo($0) },
                              startCreating: { [weak self] in self?.startCreating() },
                              create: { [weak self] in self?.create($0) })
    }

    var note: PopoverMenuNote? {
        branchSwitcherNote(choices, loadError: loadError, creating: creating, progress: progress, refusal: refusal)
    }

    func startCreating() {
        refusal = nil
        creating = true
    }

    /// Esc in the new-branch step goes back to the list.
    func back() -> Bool {
        guard creating, progress == nil else { return false }
        creating = false
        refusal = nil
        return true
    }

    func switchTo(_ branch: Branch) {
        guard progress == nil, let app, let task else { return }
        if !branch.isRemote, choices?.head == .branch(branch.name) { return PopoverMenu.close(ifShowing: panel) }
        run(L10n.branchSwitching(branch.name)) { await app.switchBranchError(of: task, to: branch) }
    }

    func create(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard progress == nil, !name.isEmpty, let app, let task else { return }
        run(L10n.branchCreating(name)) { await app.createBranchError(of: task, name: name) }
    }

    private func run(_ what: String, _ action: @escaping () async -> Error?) {
        refusal = nil
        progress = what
        Task {
            let error = await action()
            progress = nil
            guard let error else { return PopoverMenu.close(ifShowing: panel) }
            refusal = branchRefusalNote(error, text: app?.branchText(error, projectId: task?.projectId ?? UUID()) ?? error.localizedDescription)
            await load()  // the count of changes or the taken branches may have moved meanwhile
        }
    }
}

/// Opens the switcher under the branch button. `onClose` runs when the menu goes away.
@MainActor func showBranchSwitcher(app: AppState, task: HangarTask, below view: NSView?, onClose: @escaping () -> Void) {
    let switcher = BranchSwitcher(app: app, taskId: task.id)
    var search = PopoverMenuContent.Search(placeholder: L10n.switcherSearch, mono: true, highlightFirst: true)
    search.prompt = { switcher.creating ? L10n.branchNamePrompt : nil }
    search.cancel = { switcher.back() }
    var content = PopoverMenuContent(search: search, width: Theme.menuWidthWide) { switcher.entries($0) }
    content.note = { switcher.note }
    content.iconSlot = true
    content.onClose = onClose
    let before = PopoverMenu.panel
    PopoverMenu.show(content, below: view)
    // A click on the open switcher's button only closes it.
    guard let panel = PopoverMenu.panel, panel !== before else { return onClose() }
    switcher.panel = panel
    Task { await switcher.load() }
}

/// Filtered (case-insensitive substring) lists: the current branch first among the local ones, then newest commit
/// first as `listBranches` gives them; remote branches after, in the same order.
func branchSwitcherRows(_ c: BranchChoices, query: String) -> (local: [Branch], remote: [Branch]) {
    let q = query.trimmingCharacters(in: .whitespaces)
    let match: (Branch) -> Bool = { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
    let local = c.local.filter(match)
    let current = local.filter { c.head == .branch($0.name) }
    return (current + local.filter { c.head != .branch($0.name) }, c.remote.filter(match))
}

/// The menu's entries (spec §3.2): «Локальные» / «Удалённые» with the current one checked («текущая»), the age or the
/// chat that has the branch on the right; a taken branch is inactive, and every switch is while there are uncommitted
/// changes or an action runs. Last: «Новая ветка от <текущей>…» (empty field), or «Создать ветку <текст>» when no
/// local branch is called so. In the new-branch step: where it starts and «Создать ветку <имя>».
@MainActor func branchSwitcherEntries(_ c: BranchChoices?, query: String, creating: Bool, busy: Bool, now: Date,
                                      switchTo: @escaping (Branch) -> Void, startCreating: @escaping () -> Void,
                                      create: @escaping (String) -> Void) -> [PopoverMenuEntry] {
    guard let c, let head = c.head else { return [] }
    let name = query.trimmingCharacters(in: .whitespaces)
    if creating {
        return [.header(L10n.branchFromCurrent(head.title)),
                .item(PopoverMenuItem(title: name.isEmpty ? L10n.branchCreate : L10n.branchCreateNamed(name), icon: .add,
                                      enabled: !busy && !name.isEmpty, keepsOpen: true) { create(name) })]
    }
    let rows = branchSwitcherRows(c, query: query)
    var entries: [PopoverMenuEntry] = []
    for (title, branches) in [(L10n.switcherLocal, rows.local), (L10n.switcherRemote, rows.remote)] where !branches.isEmpty {
        entries.append(.header(title))
        for b in branches {
            let current = !b.isRemote && head == .branch(b.name)
            let taken = b.isRemote ? nil : c.elsewhere[b.name]
            let note = current ? L10n.branchCurrent
                : taken.map { $0.hasPrefix("/") ? L10n.branchInFolderNote : L10n.branchInChatNote($0) }
                ?? ageLabel(since: b.lastCommit, now: now)
            let help = current ? nil : taken != nil ? note : c.uncommitted > 0 ? L10n.branchDirtyHint : nil
            entries.append(.item(PopoverMenuItem(title: b.name, enabled: !busy && (current || (taken == nil && c.uncommitted == 0)),
                                                 checked: current, note: note, mono: true, help: help,
                                                 keepsOpen: !current) { switchTo(b) }))
        }
    }
    let exists = c.local.contains { $0.name == name }
    if name.isEmpty || !exists {
        if !entries.isEmpty { entries.append(.separator) }
        let title = name.isEmpty ? L10n.branchNewFrom(head.title) : L10n.branchCreateNamed(name)
        entries.append(.item(PopoverMenuItem(title: title, icon: .add, enabled: !busy, keepsOpen: true) {
            if name.isEmpty { startCreating() } else { create(name) }
        }))
    }
    return entries
}

/// Under the list, by priority: the action running, its refusal, a failed load, loading, uncommitted changes
/// («Есть незакоммиченные изменения (N файлов).» `waiting` + what to do).
@MainActor func branchSwitcherNote(_ c: BranchChoices?, loadError: String?, creating: Bool, progress: String?,
                                   refusal: PopoverMenuNote?) -> PopoverMenuNote? {
    if let progress { return PopoverMenuNote(text: progress, busy: true) }
    if let refusal { return refusal }
    if let loadError { return PopoverMenuNote(text: loadError, tone: .failed) }
    guard let c else { return PopoverMenuNote(text: L10n.branchesLoading, busy: true) }
    guard c.uncommitted > 0 else { return nil }
    return PopoverMenuNote(lead: L10n.branchDirty(L10n.fileCount(c.uncommitted)),
                           text: creating ? L10n.branchDirtyNewHint : L10n.branchDirtyHint + " " + L10n.branchDirtyNewHint, tone: .waiting)
}

/// A refused or failed action: uncommitted changes as the list shows them (count + what to do), the rest — the
/// refusal's text (#114) or git's own — as a failure.
@MainActor func branchRefusalNote(_ error: Error, text: String) -> PopoverMenuNote {
    if case .dirty(let n) = error as? BranchSwitchError {
        return PopoverMenuNote(lead: L10n.branchDirty(L10n.fileCount(n)), text: L10n.branchDirtyHint, tone: .waiting)
    }
    return PopoverMenuNote(text: text, tone: .failed)
}
