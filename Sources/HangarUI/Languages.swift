import Foundation

/// TS/JS language features of the editor (#82): one tsserver per (host, project TypeScript), started when the first
/// TS/JS file opens in an editor, stopped `grace` after the last one closes (one one-shot task, no polling),
/// restarted once after a crash. Editor panes tell it what they open, edit and close; it answers their requests and
/// pushes diagnostics and a status to them.
/// Other languages' files go to `lsp` (#90).
@MainActor final class Languages {
    /// An editor pane that shows the file: where its markers and status go, and how to read its buffer back.
    struct Owner {
        var id: UUID
        /// The session folder: answers' paths must be inside it (or a node_modules).
        var root: String
        var send: (EditorCommand) -> Void
        var text: (String) async -> String?
    }

    private struct DocKey: Hashable { var host: String?; var path: String }
    private struct ServerKey: Hashable { var host: String?; var tsserver: String }

    @MainActor private final class Doc {
        var owners: [UUID: Owner] = [:]
        let root: String
        /// Set once `open` went to the server.
        var server: ServerKey?
        /// The loaded text and the edits made since, until the server is up.
        var text: String?
        var edits: [EditorEdit] = []
        /// After a crash the page's buffer is read back; edits until then are already in it.
        var reopening = false
        var status: LanguageStatus?
        var syntax: [EditorDiagnostic] = [], semantic: [EditorDiagnostic] = []
        init(root: String, text: String) { self.root = root; self.text = text }
    }

    @MainActor private final class Entry {
        let install: TsInstall
        let launch: TsLaunch
        var server: TsServer
        var docs: Set<DocKey> = []
        var crashes = 0
        var loading = true
        var failed = false
        var grace: Task<Void, Never>?
        var diagnostics: Task<Void, Never>?
        init(install: TsInstall, launch: TsLaunch) {
            self.install = install; self.launch = launch; server = TsServer(launch: launch)
        }
    }

    private let lookup: (String?, String, String) async -> TsLookup
    private let launch: (String?, TsInstall) -> TsLaunch?
    private let grace: Duration
    private let debounce: Duration
    private let lsp: LspLanguages?
    private var docs: [DocKey: Doc] = [:]
    private var entries: [ServerKey: Entry] = [:]
    private var lookups: [String: Task<TsLookup, Never>] = [:]
    private static let maxPreviews = 30
    private static let maxDiagnosticFiles = 50

    /// `lookup(host, folder, root)` finds the project's TypeScript; `launch(host, install)` says how to run it
    /// (nil: the host is not connected).
    init(lookup: @escaping (String?, String, String) async -> TsLookup, launch: @escaping (String?, TsInstall) -> TsLaunch?,
         grace: Duration = .seconds(120), debounce: Duration = .milliseconds(400), lsp: LspLanguages? = nil) {
        self.lookup = lookup; self.launch = launch; self.grace = grace; self.debounce = debounce; self.lsp = lsp
    }

    var runningCount: Int { entries.values.filter { $0.server.isRunning }.count + (lsp?.runningCount ?? 0) }

    // MARK: Documents

    func opened(_ path: String, text: String, host: String?, owner: Owner) {
        guard TsMap.scriptKind(path) != nil else { lsp?.opened(path, text: text, host: host, owner: owner); return }
        let key = DocKey(host: host, path: path)
        if let doc = docs[key] {
            doc.owners[owner.id] = owner
            owner.send(.language(path: path, doc.status))
            return
        }
        let doc = Doc(root: owner.root, text: text)
        doc.owners[owner.id] = owner
        docs[key] = doc
        Task { await resolve(key) }
    }

    func edited(_ path: String, _ edits: [EditorEdit], host: String?) {
        guard TsMap.scriptKind(path) != nil else { lsp?.edited(path, edits, host: host); return }
        let key = DocKey(host: host, path: path)
        guard let doc = docs[key], !doc.reopening else { return }
        guard let sk = doc.server, let entry = entries[sk] else { doc.edits += edits; return }
        for e in edits { entry.server.notify("change", TsMap.change(file: path, e)) }
        scheduleDiagnostics(entry, first: path)
    }

    func closed(_ path: String, host: String?, owner: UUID) {
        guard TsMap.scriptKind(path) != nil else { lsp?.closed(path, host: host, owner: owner); return }
        let key = DocKey(host: host, path: path)
        guard let doc = docs[key] else { return }
        doc.owners[owner] = nil
        guard doc.owners.isEmpty else { return }
        docs[key] = nil
        guard let sk = doc.server, let entry = entries[sk] else { return }
        entry.server.notify("close", ["file": path])
        entry.docs.remove(key)
        if entry.docs.isEmpty { scheduleStop(sk) }
    }

    /// The pane went away or its page reloaded.
    func closedAll(owner: UUID) {
        lsp?.closedAll(owner: owner)
        for (key, doc) in docs where doc.owners[owner] != nil { closed(key.path, host: key.host, owner: owner) }
    }

    /// The status item's click: a stopped or stuck server starts afresh; a missing TypeScript is looked up again.
    func restart(_ path: String, host: String?) {
        guard TsMap.scriptKind(path) != nil else { lsp?.restart(path, host: host); return }
        let key = DocKey(host: host, path: path)
        guard let doc = docs[key] else { return }
        guard let sk = doc.server, let entry = entries[sk] else {
            lookups = lookups.filter { !$0.key.hasPrefix((host ?? "") + "\u{0}") }
            Task { await resolve(key) }
            return
        }
        entry.crashes = 0
        relaunch(sk)
    }

    /// App quit.
    func stopAll() {
        lsp?.stopAll()
        for entry in entries.values {
            entry.grace?.cancel()
            entry.diagnostics?.cancel()
            entry.server.stop()
        }
        entries = [:]
        for doc in docs.values { doc.server = nil }
    }

    // MARK: Requests

    /// `read`: a file's text for the references peek (files the page has no model of).
    func request(_ r: ProviderRequest, host: String?, read: (String) async -> String?) async -> ProviderResult? {
        if TsMap.scriptKind(r.file) == nil { return await lsp?.request(r, host: host, read: read) }
        let key = DocKey(host: host, path: r.file)
        guard let doc = docs[key], let sk = doc.server, let entry = entries[sk], !entry.failed else { return nil }
        let server = entry.server
        var roots = [doc.root]
        if host == nil { let real = realPath(doc.root); if real != doc.root { roots.append(real) } }
        let at: [String: Any] = ["file": r.file, "line": r.line, "offset": r.column]
        func ask(_ command: String, _ extra: [String: Any] = [:]) async -> Any? {
            guard let response = await server.request(command, at.merging(extra) { $1 }), response.success else { return nil }
            answered(sk)
            return response.body
        }
        switch r.kind {
        case .definition:
            let list = TsMap.definition(await ask("definitionAndBoundSpan"), roots: roots)
            return list.isEmpty ? nil : .locations(list, previews: [:])
        case .references:
            let list = TsMap.references(await ask("references"), roots: roots)
            guard !list.isEmpty else { return nil }
            var previews: [String: String] = [:]
            var seen: [String] = []
            for path in list.map(\.path) where path != r.file && !seen.contains(path) { seen.append(path) }
            for path in seen.prefix(Self.maxPreviews) { if let text = await read(path) { previews[path] = text } }
            return .locations(list, previews: previews)
        case .hover:
            return TsMap.hover(await ask("quickinfo")).map { .hover(markdown: $0) }
        case .completion:
            let list = TsMap.completions(await ask("completionInfo", ["includeExternalModuleExports": false,
                                                                       "includeInsertTextCompletions": true]))
            return list.isEmpty ? nil : .completions(list)
        case .details:
            guard let name = r.name else { return nil }
            return TsMap.details(await ask("completionEntryDetails", ["entryNames": [name]])).map { .hover(markdown: $0) }
        case .rename:
            return TsMap.rename(await ask("rename", ["findInStrings": false, "findInComments": false]), file: r.file)
        case .semantic:
            let spans = TsMap.semantic(await ask("encodedSemanticClassifications-full",
                                                 ["start": 0, "length": r.length ?? 0, "format": "2020"]))
            return spans.isEmpty ? nil : .semantic(spans)
        case .format:
            let tab = r.tabSize ?? 4, spaces = r.insertSpaces ?? true
            _ = await server.request("configure", ["file": r.file, "formatOptions": ["tabSize": tab, "indentSize": tab,
                                                                                        "convertTabsToSpaces": spaces]])
            // The whole file: the page sends its end as the position (tsserver fails on a line past the end).
            let edits = TsMap.format(await ask("format", ["line": 1, "offset": 1, "endLine": r.line, "endOffset": r.column]))
            return edits.isEmpty ? nil : .edits(edits)
        }
    }

    // MARK: Servers

    private func resolve(_ key: DocKey) async {
        guard let root = docs[key]?.root else { return }
        let dir = (key.path as NSString).deletingLastPathComponent
        let cacheKey = (key.host ?? "") + "\u{0}" + dir
        let task = lookups[cacheKey] ?? Task { [lookup] in await lookup(key.host, dir, root) }
        lookups[cacheKey] = task
        let result = await task.value
        if result == .notConnected, lookups[cacheKey] == task { lookups[cacheKey] = nil }  // try again on the next open
        guard let doc = docs[key], doc.server == nil else { return }
        guard case .found(let install) = result else {
            setStatus(doc, key.path, Self.status(result))
            return
        }
        attach(key, doc, install)
    }

    private func attach(_ key: DocKey, _ doc: Doc, _ install: TsInstall) {
        let sk = ServerKey(host: key.host, tsserver: install.tsserver)
        if entries[sk] == nil {
            guard let launch = launch(key.host, install) else { setStatus(doc, key.path, Self.status(.notConnected)); return }
            let entry = Entry(install: install, launch: launch)
            entries[sk] = entry
            guard start(sk, entry) else { return }
        }
        guard let entry = entries[sk] else { return }
        entry.grace?.cancel()
        entry.grace = nil
        entry.docs.insert(key)
        doc.server = sk
        entry.server.notify("open", Self.openArgs(key.path, doc.text ?? "", root: doc.root))
        for e in doc.edits { entry.server.notify("change", TsMap.change(file: key.path, e)) }
        doc.text = nil
        doc.edits = []
        setStatus(doc, key.path, status(entry))
        scheduleDiagnostics(entry, first: key.path)
    }

    /// false: the process didn't start (the entry shows as stopped).
    @discardableResult private func start(_ sk: ServerKey, _ entry: Entry) -> Bool {
        let server = TsServer(launch: entry.launch)
        entry.server = server
        entry.loading = true
        entry.failed = false
        server.onEvent = { [weak self] name, body in self?.event(sk, server, name, body) }
        server.onExit = { [weak self] _ in self?.crashed(sk, server) }
        do {
            try server.start()
            return true
        } catch {
            uiLog.error("tsserver start failed: \(String(describing: error), privacy: .public)")
            entry.failed = true
            broadcast(entry)
            return false
        }
    }

    private func crashed(_ sk: ServerKey, _ server: TsServer) {
        guard let entry = entries[sk], entry.server === server else { return }
        entry.crashes += 1
        uiLog.error("tsserver exited (\(entry.crashes, privacy: .public)) \(sk.tsserver, privacy: .public)")
        if entry.crashes <= 1 {
            relaunch(sk)
        } else {
            entry.failed = true
            broadcast(entry)
        }
    }

    /// A new process for the same files: each one's text is read back from its page.
    private func relaunch(_ sk: ServerKey) {
        guard let entry = entries[sk] else { return }
        let old = entry.server
        old.onExit = nil
        old.stop()
        guard start(sk, entry) else { return }
        broadcast(entry)
        let server = entry.server
        for key in entry.docs {
            guard let doc = docs[key], let owner = doc.owners.values.first else { continue }
            doc.reopening = true
            Task {
                let text = await owner.text(key.path)
                doc.reopening = false
                guard let text, entries[sk]?.server === server, entry.docs.contains(key) else { return }
                server.notify("open", Self.openArgs(key.path, text, root: doc.root))
                scheduleDiagnostics(entry, first: key.path)
            }
        }
    }

    private func scheduleStop(_ sk: ServerKey) {
        guard let entry = entries[sk] else { return }
        entry.grace?.cancel()
        entry.diagnostics?.cancel()
        let grace = grace
        entry.grace = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, let e = self.entries[sk], e === entry, e.docs.isEmpty else { return }
            e.server.stop()
            self.entries[sk] = nil
        }
    }

    /// `geterr` for the open files (the edited one first) once edits pause.
    private func scheduleDiagnostics(_ entry: Entry, first: String) {
        entry.diagnostics?.cancel()
        let debounce = debounce
        entry.diagnostics = Task { [weak entry] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let entry else { return }
            let others = entry.docs.map(\.path).filter { $0 != first }.sorted()
            let files = Array(([first] + others).prefix(Self.maxDiagnosticFiles))
            entry.server.notify("geterr", ["files": files, "delay": 0])
        }
    }

    private func event(_ sk: ServerKey, _ server: TsServer, _ name: String, _ body: Any?) {
        guard let entry = entries[sk], entry.server === server else { return }
        switch name {
        case "syntaxDiag", "semanticDiag":
            guard let (file, list) = TsMap.diagnostics(body), let doc = docs[DocKey(host: sk.host, path: file)],
                  doc.server == sk else { return }
            if name == "syntaxDiag" { doc.syntax = list } else { doc.semantic = list }
            for owner in doc.owners.values { owner.send(.markers(path: file, doc.syntax + doc.semantic)) }
            answered(sk)
        case "projectLoadingStart":
            entry.loading = true
            broadcast(entry)
        case "projectLoadingFinish": answered(sk)
        default: break  // unknown and unused events
        }
    }

    /// The server answered: the project is loaded.
    private func answered(_ sk: ServerKey) {
        guard let entry = entries[sk], entry.loading else { return }
        entry.loading = false
        broadcast(entry)
    }

    // MARK: Status

    private func broadcast(_ entry: Entry) {
        let s = status(entry)
        for key in entry.docs { if let doc = docs[key] { setStatus(doc, key.path, s) } }
    }

    private func setStatus(_ doc: Doc, _ path: String, _ s: LanguageStatus) {
        doc.status = s
        for owner in doc.owners.values { owner.send(.language(path: path, s)) }
    }

    private func status(_ entry: Entry) -> LanguageStatus {
        let i = entry.install
        let version = i.version.split(separator: ".").prefix(2).joined(separator: ".")
        let tip = L10n.tsTooltip(i.tsserver, i.node)
        if entry.failed { return LanguageStatus(text: L10n.tsStopped, tooltip: tip, level: .off) }
        if entry.loading { return LanguageStatus(text: L10n.tsLoading(version), tooltip: tip, level: .busy) }
        return LanguageStatus(text: L10n.tsReady(version), tooltip: tip, level: .ready)
    }

    private static func status(_ lookup: TsLookup) -> LanguageStatus {
        let text: String
        switch lookup {
        case .noNode: text = L10n.tsNoNode
        case .notConnected: text = L10n.tsNotConnected
        case .noTypeScript, .found: text = L10n.tsNoTypeScript
        }
        return LanguageStatus(text: text, tooltip: L10n.tsUnavailableTip, level: .off)
    }

    private static func openArgs(_ path: String, _ text: String, root: String) -> [String: Any] {
        ["file": path, "fileContent": text, "scriptKindName": TsMap.scriptKind(path) ?? "TS", "projectRootPath": root]
    }
}
