import Foundation

/// Language features beyond TS/JS (#90): one LSP server per (language, project root, executable) — pyright / pylsp,
/// sourcekit-lsp, gopls, rust-analyzer, whichever is found. Same lifecycle as tsserver (#82): started when the first file
/// of the language opens, stopped `grace` after the last one closes (one one-shot task, no polling), restarted once
/// after a crash. Not found → a calm status, the editor works as before. shortcut: this Mac only — remote files get
/// no LSP server; add an ssh launch like tsserver's when asked.
@MainActor final class LspLanguages {
    typealias Owner = Languages.Owner

    private struct ServerKey: Hashable { var language: String; var root: String; var found: LspFound }

    @MainActor private final class Doc {
        var owners: [UUID: Owner] = [:]
        let root: String
        let language: LspLanguage
        var server: ServerKey?
        /// The loaded text and the edits made since, until the server is initialized.
        var text: String?
        var edits: [EditorEdit] = []
        var version = 1
        /// `didOpen` went to the current process.
        var opened = false
        var reopening = false
        var status: LanguageStatus?
        /// The last completion list's raw items, by label (for `completionItem/resolve`).
        var completions: [String: [String: Any]] = [:]
        /// A full-text sync is on its way (servers without incremental sync).
        var syncing: Task<Void, Never>?
        init(root: String, language: LspLanguage, text: String) { self.root = root; self.language = language; self.text = text }
    }

    @MainActor private final class Entry {
        let launch: LspLaunch
        var server: LspServer
        var docs: Set<String> = []
        var caps = LspMap.Capabilities()
        var ready = false
        var crashes = 0
        /// When the current process finished `initialize`: one that has run a while counts its next crash afresh.
        var upSince: ContinuousClock.Instant?
        var failed = false
        var grace: Task<Void, Never>?
        init(launch: LspLaunch) { self.launch = launch; server = LspServer(launch: launch) }
    }

    private let find: (LspLanguage, String) async -> LspFound?
    private let path: () async -> String?
    private let grace: Duration
    private let dependencies: (LspLanguage) async -> [String]
    /// A crash this long after a successful `initialize` is a new first crash (restarted again), not a second one.
    private let stableAfter: Duration
    private let isExecutable: (String) -> Bool
    /// Languages whose extra dependency roots were looked up.
    private var dependenciesAsked: Set<String> = []
    private var docs: [String: Doc] = [:]
    private var entries: [ServerKey: Entry] = [:]
    private var lookups: [String: Task<LspFound?, Never>] = [:]
    private static let maxPreviews = 30

    /// `find(language, projectRoot)` looks for a server; `path()` is the PATH it runs with (nil: the app's own).
    /// `dependencies(language, found)`: folders definitions may open read-only beyond the usual ones (GOROOT, the
    /// Xcode developer folder), registered in `LspMap.dependencyRoots`.
    init(find: @escaping (LspLanguage, String) async -> LspFound?, path: @escaping () async -> String? = { nil },
         dependencies: @escaping (LspLanguage) async -> [String] = { _ in [] },
         grace: Duration = .seconds(120), stableAfter: Duration = .seconds(60),
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.find = find; self.path = path; self.dependencies = dependencies; self.grace = grace; self.stableAfter = stableAfter
        self.isExecutable = isExecutable
    }

    var runningCount: Int { entries.values.filter { $0.server.isRunning }.count }

    // MARK: Documents

    func opened(_ path: String, text: String, host: String?, owner: Owner) {
        guard host == nil, let language = LspLanguage.of(path) else { return }
        if let doc = docs[path] {
            doc.owners[owner.id] = owner
            owner.send(.language(path: path, doc.status))
            return
        }
        let doc = Doc(root: owner.root, language: language, text: text)
        doc.owners[owner.id] = owner
        docs[path] = doc
        Task { await resolve(path) }
    }

    func edited(_ path: String, _ edits: [EditorEdit], host: String?) {
        guard host == nil, let doc = docs[path], !doc.reopening else { return }
        guard doc.opened, let sk = doc.server, let entry = entries[sk] else { doc.edits += edits; return }
        send(edits, path, doc, entry)
    }

    func closed(_ path: String, host: String?, owner: UUID) {
        guard host == nil, let doc = docs[path] else { return }
        doc.owners[owner] = nil
        guard doc.owners.isEmpty else { return }
        docs[path] = nil
        doc.syncing?.cancel()
        guard let sk = doc.server, let entry = entries[sk] else { return }
        if doc.opened { entry.server.notify("textDocument/didClose", ["textDocument": ["uri": LspMap.uri(path)]]) }
        entry.docs.remove(path)
        if entry.docs.isEmpty { scheduleStop(sk) }
    }

    func closedAll(owner: UUID) {
        for (path, doc) in docs where doc.owners[owner] != nil { closed(path, host: nil, owner: owner) }
    }

    /// The status item's click: a stopped server starts afresh; a missing one is looked up again.
    func restart(_ path: String, host: String?) {
        guard host == nil, let doc = docs[path] else { return }
        guard let sk = doc.server, entries[sk] != nil else {
            lookups = [:]
            Task { await resolve(path) }
            return
        }
        // The next file of this language and root looks again (a server installed or removed meanwhile).
        lookups[sk.language + "\u{0}" + sk.root] = nil
        guard isExecutable(sk.found.executable) else { rediscover(sk); return }
        entries[sk]?.crashes = 0
        relaunch(sk)
    }

    /// The server's executable is gone (uninstalled, a venv rebuilt): its files look for one again and get a new
    /// launch (another path, or the «no language server» status); their text comes back from the page.
    private func rediscover(_ sk: ServerKey) {
        guard let entry = entries.removeValue(forKey: sk) else { return }
        entry.grace?.cancel()
        entry.server.onExit = nil
        entry.server.stop()
        for path in entry.docs {
            guard let doc = docs[path] else { continue }
            doc.syncing?.cancel()
            (doc.server, doc.opened, doc.text, doc.edits, doc.syncing) = (nil, false, nil, [], nil)
            Task { await resolve(path) }
        }
    }

    /// Settings installed or removed a server (#100): every lookup is forgotten, files without a server look again
    /// (the new one starts without reopening them), and servers whose executable is gone are replaced.
    func serversChanged() {
        lookups = [:]
        for (path, doc) in docs where doc.server == nil { Task { await resolve(path) } }
        for (sk, _) in entries where !isExecutable(sk.found.executable) { rediscover(sk) }
    }

    func stopAll() {
        for entry in entries.values {
            entry.grace?.cancel()
            entry.server.stop()
        }
        entries = [:]
        for doc in docs.values { (doc.server, doc.opened) = (nil, false) }
    }

    // MARK: Requests

    func request(_ r: ProviderRequest, host: String?, read: (String) async -> String?) async -> ProviderResult? {
        guard host == nil, let doc = docs[r.file], let sk = doc.server, let entry = entries[sk], entry.ready, !entry.failed else { return nil }
        let server = entry.server, caps = entry.caps
        var roots = [doc.root, sk.root]
        let real = realPath(doc.root)
        if real != doc.root { roots.append(real) }
        // sourcekit-lsp answers with real paths (/private/tmp/…): back to the session's own, so the tab is found.
        func local(_ list: [EditorLocation]) -> [EditorLocation] {
            guard real != doc.root else { return list }
            return list.map { l in
                var l = l
                if l.path.hasPrefix(real + "/") { l.path = doc.root + l.path.dropFirst(real.count) }
                return l
            }
        }
        let at: [String: Any] = ["textDocument": ["uri": LspMap.uri(r.file)], "position": LspMap.lspPosition(line: r.line, column: r.column)]
        func ask(_ method: String, _ extra: [String: Any] = [:]) async -> LspServer.Reply? {
            await server.request(method, at.merging(extra) { $1 })
        }
        switch r.kind {
        case .definition:
            guard caps.definition else { return nil }
            let list = local(LspMap.locations(await ask("textDocument/definition")?.result, roots: roots))
            return list.isEmpty ? nil : .locations(list, previews: [:])
        case .references:
            guard caps.references else { return nil }
            let list = local(LspMap.locations(await ask("textDocument/references", ["context": ["includeDeclaration": true]])?.result,
                                              roots: roots))
            guard !list.isEmpty else { return nil }
            var previews: [String: String] = [:]
            var seen: [String] = []
            for path in list.map(\.path) where path != r.file && !seen.contains(path) { seen.append(path) }
            for path in seen.prefix(Self.maxPreviews) { if let text = await read(path) { previews[path] = text } }
            return .locations(list, previews: previews)
        case .hover:
            guard caps.hover else { return nil }
            return LspMap.hover(await ask("textDocument/hover")?.result).map { .hover(markdown: $0) }
        case .completion:
            guard caps.completion else { return nil }
            let (list, raw) = LspMap.completions(await ask("textDocument/completion")?.result, line: r.line, column: r.column)
            doc.completions = raw
            return list.isEmpty ? nil : .completions(list)
        case .details:
            guard let name = r.name, let item = doc.completions[name] else { return nil }
            let resolved = caps.resolve ? await server.request("completionItem/resolve", item)?.result ?? item : item
            return LspMap.details(resolved, language: doc.language.id).map { .hover(markdown: $0) }
        case .rename:
            guard caps.rename else { return nil }
            guard let name = r.name else {
                // Monaco asks where the rename applies first: the server may refuse here.
                guard caps.prepareRename, let reply = await ask("textDocument/prepareRename") else { return nil }
                if let error = reply.error { return .rejected(error) }
                return reply.result == nil ? .rejected(L10n.editorRenameRefused) : nil
            }
            guard let reply = await ask("textDocument/rename", ["newName": name]) else { return nil }
            if let error = reply.error { return .rejected(error) }
            return LspMap.rename(reply.result, file: r.file, newName: name)
        case .format:
            guard caps.formatting else { return nil }
            let options: [String: Any] = ["tabSize": r.tabSize ?? 4, "insertSpaces": r.insertSpaces ?? true]
            let edits = LspMap.edits(await server.request("textDocument/formatting",
                                                          ["textDocument": ["uri": LspMap.uri(r.file)], "options": options])?.result)
            return edits.isEmpty ? nil : .edits(edits)
        case .semantic: return nil
        }
    }

    // MARK: Servers

    private func resolve(_ path: String) async {
        guard let doc = docs[path] else { return }
        let root = LspMap.projectRoot(file: path, sessionRoot: doc.root, markers: doc.language.markers) {
            FileManager.default.fileExists(atPath: $0)
        }
        let cacheKey = doc.language.id + "\u{0}" + root
        let task = lookups[cacheKey] ?? Task { [find, language = doc.language] in await find(language, root) }
        lookups[cacheKey] = task
        let found = await task.value
        guard docs[path] === doc, doc.server == nil else { return }
        guard let found else {
            setStatus(doc, path, LanguageStatus(text: L10n.lspMissing(doc.language.name),
                                                tooltip: L10n.lspMissingTip(doc.language.servers.map(\.name).joined(separator: ", ")), level: .off))
            return
        }
        if dependenciesAsked.insert(doc.language.id).inserted {
            let language = doc.language
            Task { LspMap.dependencyRoots.add(await dependencies(language)) }
        }
        let sk = ServerKey(language: doc.language.id, root: root, found: found)
        if entries[sk] == nil {
            let launch = LspLaunch(executable: found.executable, args: found.args, cwd: root, path: await self.path())
            guard docs[path] === doc, doc.server == nil else { return }
            if entries[sk] == nil {
                let entry = Entry(launch: launch)
                entries[sk] = entry
                start(sk, entry)
            }
        }
        guard let entry = entries[sk] else { return }
        entry.grace?.cancel()
        entry.grace = nil
        entry.docs.insert(path)
        doc.server = sk
        if entry.ready { open(path, doc, entry) }
        setStatus(doc, path, status(entry))
    }

    @discardableResult private func start(_ sk: ServerKey, _ entry: Entry) -> Bool {
        let server = LspServer(launch: entry.launch)
        entry.server = server
        entry.ready = false
        entry.failed = false
        server.folders = [["uri": LspMap.uri(sk.root), "name": (sk.root as NSString).lastPathComponent]]
        server.onNotification = { [weak self] method, params in self?.notification(sk, server, method, params) }
        server.onExit = { [weak self] _ in self?.crashed(sk, server) }
        do {
            try server.start()
        } catch {
            uiLog.error("lsp start failed: \(String(describing: error), privacy: .public)")
            entry.failed = true
            broadcast(entry)
            return false
        }
        let locale = L10n.resolve(L10n.language).rawValue
        Task {
            let reply = await server.request("initialize", LspMap.initialize(root: sk.root, processId: getpid(), locale: locale),
                                             timeout: .seconds(30))
            guard let reply, reply.error == nil, entries[sk]?.server === server else {
                if entries[sk]?.server === server { entry.failed = true; server.stop(); broadcast(entry) }
                return
            }
            entry.caps = LspMap.Capabilities(reply.result)
            entry.upSince = .now
            server.notify("initialized", [String: Any]())
            entry.ready = true
            for path in entry.docs {
                guard let doc = docs[path] else { continue }
                if doc.text == nil, let owner = doc.owners.values.first {
                    // A restart: the page has the current text.
                    doc.reopening = true
                    let text = await owner.text(path)
                    doc.reopening = false
                    guard let text, entries[sk]?.server === server, entry.docs.contains(path) else { continue }
                    doc.text = text
                    doc.edits = []
                }
                open(path, doc, entry)
            }
            broadcast(entry)
        }
        return true
    }

    /// `didOpen` with the loaded text, then the edits made while the server was starting.
    private func open(_ path: String, _ doc: Doc, _ entry: Entry) {
        guard let text = doc.text else { return }
        doc.version = 1
        doc.opened = true
        entry.server.notify("textDocument/didOpen", ["textDocument": ["uri": LspMap.uri(path), "languageId": doc.language.id,
                                                                      "version": doc.version, "text": text]])
        let edits = doc.edits
        doc.text = nil
        doc.edits = []
        if !edits.isEmpty { send(edits, path, doc, entry) }
    }

    private func send(_ edits: [EditorEdit], _ path: String, _ doc: Doc, _ entry: Entry) {
        let uri = LspMap.uri(path)
        switch entry.caps.sync {
        case 2:
            doc.version += 1
            entry.server.notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": doc.version],
                                                           "contentChanges": edits.map { ["range": LspMap.lspRange($0), "text": $0.text] }])
        case 1:
            // The whole text, read back from the page once typing pauses.
            guard doc.syncing == nil, let owner = doc.owners.values.first else { return }
            let server = entry.server
            doc.syncing = Task { [weak doc] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let doc, !Task.isCancelled else { return }
                doc.syncing = nil
                guard let text = await owner.text(path) else { return }
                doc.version += 1
                server.notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": doc.version],
                                                         "contentChanges": [["text": text]]])
            }
        default: break
        }
    }

    private func crashed(_ sk: ServerKey, _ server: LspServer) {
        guard let entry = entries[sk], entry.server === server else { return }
        // Up and initialized for a while: a fresh first crash. Not at once — a server dying on every `didOpen`
        // would restart forever.
        if let up = entry.upSince, up.duration(to: .now) > stableAfter { entry.crashes = 0 }
        entry.upSince = nil
        entry.crashes += 1
        uiLog.error("lsp exited (\(entry.crashes, privacy: .public)) \(sk.found.executable, privacy: .public)")
        if entry.crashes <= 1 {
            relaunch(sk)
        } else {
            entry.failed = true
            broadcast(entry)
        }
    }

    /// A new process for the same files: each one's text is read back from its page once it is initialized.
    private func relaunch(_ sk: ServerKey) {
        guard let entry = entries[sk] else { return }
        let old = entry.server
        old.onExit = nil
        old.stop()
        for path in entry.docs {
            guard let doc = docs[path] else { continue }
            (doc.text, doc.edits, doc.opened) = (nil, [], false)
            doc.syncing?.cancel()
            doc.syncing = nil
        }
        start(sk, entry)
        broadcast(entry)
    }

    private func scheduleStop(_ sk: ServerKey) {
        guard let entry = entries[sk] else { return }
        entry.grace?.cancel()
        let grace = grace
        entry.grace = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, let e = self.entries[sk], e === entry, e.docs.isEmpty else { return }
            e.server.stop()
            self.entries[sk] = nil
        }
    }

    private func notification(_ sk: ServerKey, _ server: LspServer, _ method: String, _ params: Any?) {
        guard let entry = entries[sk], entry.server === server, method == "textDocument/publishDiagnostics",
              let (file, list) = LspMap.diagnostics(params) else { return }
        let path = entry.docs.contains(file) ? file : entry.docs.first { realPath($0) == realPath(file) }
        guard let path, let doc = docs[path], doc.server == sk else { return }
        for owner in doc.owners.values { owner.send(.markers(path: path, list)) }
    }

    // MARK: Status

    private func broadcast(_ entry: Entry) {
        let s = status(entry)
        for path in entry.docs { if let doc = docs[path] { setStatus(doc, path, s) } }
    }

    private func setStatus(_ doc: Doc, _ path: String, _ s: LanguageStatus) {
        doc.status = s
        for owner in doc.owners.values { owner.send(.language(path: path, s)) }
    }

    private func status(_ entry: Entry) -> LanguageStatus {
        let name = (entry.launch.executable as NSString).lastPathComponent
        let tip = L10n.lspTooltip(entry.launch.executable)
        if entry.failed { return LanguageStatus(text: L10n.lspStopped(name), tooltip: tip, level: .off) }
        if !entry.ready { return LanguageStatus(text: L10n.lspLoading(name), tooltip: tip, level: .busy) }
        return LanguageStatus(text: name, tooltip: tip, level: .ready)
    }
}
