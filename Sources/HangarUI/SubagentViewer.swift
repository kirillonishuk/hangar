import AgentStatus
import Exec
import History
import Observation
import SwiftUI

/// One subagent's transcript in the inspector's «Субагент» view (spec agent-subagents §5): read when it comes on screen, then
/// only the lines appended, on FSEvents of that one file. Off screen (closed, inspector hidden, window covered) — no watch.
@MainActor @Observable final class SubagentViewerModel {
    let leaf: UUID
    let id: String
    private(set) var entries: [TranscriptEntry] = []
    /// The transcript this viewer reads; nil — none on this Mac (remote, or the agent id isn't known yet).
    private(set) var url: URL?
    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var reader = TranscriptReader()
    @ObservationIgnored private(set) var watcher: FileWatcher?
    /// On screen (`AppState.syncSubagentPanel`): only then is the transcript read and watched.
    @ObservationIgnored private(set) var visible = false

    /// Entries kept: a runaway transcript shows its newest steps (the prompt is the first entry and stays).
    static let maxEntries = 2000

    init(app: AppState, leaf: UUID, id: String) {
        self.app = app
        self.leaf = leaf
        self.id = id
    }

    var item: Subagent? { app?.subagent(leaf: leaf, id: id) }
    var remote: Bool { app?.remoteLeafHost(leaf) != nil }

    /// Opens (or re-resolves after the row got its agent id): reads what is there and watches the file.
    func start() {
        guard watcher == nil, let app, let agentId = item?.agentId,
              let target = app.subagentTranscriptURL(leaf: leaf, agentId: agentId) else { return }
        url = target
        load()
        // The folder, not the file: an atomic replace keeps being seen. Only this file's events reach `load`.
        let path = realPath(target.deletingLastPathComponent().path) + "/" + target.lastPathComponent
        watcher = FileWatcher(paths: [target.deletingLastPathComponent().path], onChange: { [weak self] _ in self?.load() },
                              classify: { events in events.contains { $0.path == path } ? .status : [] })
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Shown again: what was appended meanwhile is read once (the reader keeps its offset), then the watch resumes.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        if on { start() } else { stop() }
    }

    /// The row got its agent id or finished: look for the transcript again, or read the rest — only while on screen.
    func itemChanged() {
        guard visible else { return }
        if watcher == nil { start() } else { load() }
    }

    func load() {
        guard let url else { return }
        let new = reader.read(url)
        guard !new.isEmpty else { return }
        entries += new
        if entries.count > Self.maxEntries { entries.removeSubrange(1..<(entries.count - Self.maxEntries + 1)) }
    }

    /// The orchestrator's prompt: the transcript's first message, else what the hook carried.
    var prompt: String? {
        if let first = entries.first, first.kind == .prompt { return first.text }
        return item?.prompt
    }

    /// The steps between the prompt and the report.
    var steps: [TranscriptEntry] {
        entries.enumerated().filter { i, e in !(i == 0 && e.kind == .prompt) && e.kind != .report }.map(\.element)
    }

    /// Its final report (`SubagentHandback`), else SubagentStop's last message once it finished.
    var report: String? {
        entries.last { $0.kind == .report }?.text ?? (item?.state == .done ? item?.result : nil)
    }
}

/// The inspector's «Субагент» view (read-only, non-modal): a header with «×», the name and type, the state, the prompt,
/// the steps as they come, the result. Closed by «×», Esc, a segment shortcut or another chat.
struct SubagentPanel: View {
    let app: AppState
    @Bindable var model: SubagentViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s2) {
                        if let item = model.item { title(item) }
                        if let prompt = model.prompt { block(L10n.subagentPrompt, prompt) }
                        ForEach(model.steps) { entry in row(entry) }
                        if model.url == nil {
                            Text(model.remote ? L10n.subagentRemoteNote : L10n.subagentPendingNote)
                                .font(Theme.Typography.secondary.font()).foregroundStyle(Theme.ui.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let report = model.report { block(L10n.subagentReport, report) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.rowPaddingH)
                    .padding(.vertical, Theme.Space.s3)
                    .textSelection(.enabled)
                }
                .onChange(of: model.entries.count) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The segment's row, same height and line: «Субагент» and «×».
    private var header: some View {
        HStack(spacing: Theme.Space.iconGap) {
            Text(L10n.subagentPanelTitle)
                .font(Theme.Typography.secondary.font(.semibold))
                .foregroundStyle(Theme.ui.text1)
            Spacer(minLength: 0)
            IconButton(icon: .close, help: L10n.subagentPanelClose) { app.closeSubagentPanel() }
        }
        .padding(.horizontal, Theme.inspectorSegmentPaddingH)
        .frame(maxWidth: .infinity, minHeight: Theme.Height.barTabs, maxHeight: Theme.Height.barTabs)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ui.line).frame(height: 1) }
    }

    private func title(_ item: Subagent) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            Text(verbatim: item.title)
                .font(Theme.Typography.body.font(.semibold))
                .foregroundStyle(Theme.ui.text0)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.iconGap) {
                StatusDot(state: item.dotState, seen: item.dotSeen)
                Text(verbatim: [item.type, L10n.subagentState(item.state), L10n.subagentElapsed(item.elapsed(now: Date()))].joined(separator: " · "))
                    .font(Theme.Typography.secondary.font())
                    .foregroundStyle(Theme.ui.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.bottom, Theme.Space.s1)
    }

    private func block(_ title: String, _ text: String) -> some View {
        CardSection(title: title) {
            Text(verbatim: text)
                .font(Theme.Typography.body.font())
                .foregroundStyle(Theme.ui.text1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s3)
        }
    }

    @ViewBuilder private func row(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .prompt, .text, .report:
            Text(verbatim: entry.text)
                .font(Theme.Typography.body.font())
                .foregroundStyle(entry.kind == .prompt ? Theme.ui.text2 : Theme.ui.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.iconGap) {
                Text(verbatim: name).font(Theme.Typography.mono.font(.semibold)).foregroundStyle(Theme.ui.text1)
                Text(verbatim: entry.text).font(Theme.Typography.mono.font()).foregroundStyle(Theme.ui.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .result(let error):
            Text(verbatim: entry.text)
                .font(Theme.Typography.monoSmall.font())
                .foregroundStyle(error ? Theme.ui.failedText : Theme.ui.text3)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.Space.s4)
        }
    }
}

extension Subagent {
    /// The row's dot: the chat dot's colours (running = working).
    var dotState: AgentState {
        switch state {
        case .running: .working
        case .done: .done
        case .failed: .failed
        }
    }

    /// A finished one is quiet — the seen-done ring (#135): its result is in the panel, not something to attend to.
    var dotSeen: Bool { state == .done }

    /// Running: since the start; finished: how long it ran.
    func elapsed(now: Date) -> TimeInterval { (ended ?? now).timeIntervalSince(started) }
}
