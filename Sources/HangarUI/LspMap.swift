import Foundation

/// A language with LSP servers (#90): Monaco's language id, a display name, the servers to look for (in order) and the
/// files that mark a project's root.
struct LspLanguage: Equatable, Sendable {
    struct Server: Equatable, Sendable {
        var name: String
        var args: [String]
        /// Project folders it is conventionally installed in (a venv, the npm bin); none for toolchain servers.
        var local: [String] = []
        /// Where Settings installs it, relative to Hangar's language-server folder (#100); nil: not downloadable.
        var hangar: String?
    }

    var id: String
    var name: String
    var servers: [Server]
    var markers: [String]

    private static let venv = [".venv/bin", "venv/bin"]
    static let python = LspLanguage(id: "python", name: "Python", servers: [
        Server(name: "pyright-langserver", args: ["--stdio"], local: venv + ["node_modules/.bin"],
               hangar: LspPackage.pyright.relativeExecutable),
        Server(name: "basedpyright-langserver", args: ["--stdio"], local: venv + ["node_modules/.bin"]),
        Server(name: "pylsp", args: [], local: venv),
    ], markers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg"])
    static let swift = LspLanguage(id: "swift", name: "Swift", servers: [Server(name: "sourcekit-lsp", args: [])],
                                   markers: ["Package.swift", "compile_commands.json", "buildServer.json"])
    static let go = LspLanguage(id: "go", name: "Go", servers: [Server(name: "gopls", args: [], hangar: LspPackage.gopls.relativeExecutable)], markers: ["go.work", "go.mod"])
    static let rust = LspLanguage(id: "rust", name: "Rust", servers: [Server(name: "rust-analyzer", args: [], hangar: LspPackage.rustAnalyzer.relativeExecutable)],
                                  markers: ["Cargo.toml"])

    /// nil: no LSP server for this file (TS/JS go to tsserver, #82).
    static func of(_ path: String) -> LspLanguage? {
        switch (path as NSString).pathExtension.lowercased() {
        case "py", "pyi": python
        case "swift": swift
        case "go": go
        case "rs": rust
        default: nil
        }
    }
}

/// The server found for a language (#90).
struct LspFound: Equatable, Hashable, Sendable {
    var executable: String
    var args: [String]
}

/// Language server answers → editor results (#90). Everything here reads untrusted JSON: wrong types are skipped,
/// lists and strings are capped, and a path from an answer must be inside the project (or a dependency folder).
enum LspMap {
    static let maxItems = TsMap.maxItems
    static let maxText = TsMap.maxText
    private static let maxPosition = 10_000_000

    // MARK: Finding a server

    /// Project-local first (only where the server is conventionally installed: a venv, node_modules/.bin — the same
    /// trust as tsserver from the project's node_modules), then the login shell's PATH, then the usual install places,
    /// then Hangar's own folder (`hangarDir`, Settings → Editor, #100: the user's own install wins);
    /// `toolchain(name)` last (sourcekit-lsp through `xcrun`). `/usr/bin` is skipped: its developer-tool shims open the
    /// «install command line tools» dialog on a Mac without them.
    static func find(_ language: LspLanguage, projectRoot: String, path: [String], home: String, hangarDir: String? = nil,
                     isExecutable: @Sendable (String) -> Bool, toolchain: @Sendable (String) async -> String?) async -> LspFound? {
        let searchPath = path.filter { $0.hasPrefix("/") && $0 != "/usr/bin" && $0 != "/usr/bin/" }
        for tier in 0..<4 {
            for server in language.servers {
                let candidates: [String]
                switch tier {
                case 0: candidates = server.local.map { projectRoot + "/" + $0 + "/" + server.name }
                case 1: candidates = searchPath.map { (($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/" + server.name) }
                case 2: candidates = knownDirs(home: home).map { $0 + "/" + server.name }
                default: candidates = [hangarDir.flatMap { dir in server.hangar.map { dir + "/" + $0 } }].compactMap { $0 }
                }
                for candidate in candidates where isExecutable(candidate) { return LspFound(executable: candidate, args: server.args) }
            }
        }
        for server in language.servers {
            if let found = await toolchain(server.name), found.hasPrefix("/"), isExecutable(found) {
                return LspFound(executable: found, args: server.args)
            }
        }
        return nil
    }

    /// The usual install places of language servers and their tools, after the login PATH.
    static func knownDirs(home: String) -> [String] {
        [home + "/.local/bin", home + "/go/bin", home + "/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The nearest folder with one of the language's markers, from the file's folder up to the session root (a Go or
    /// Rust module in a subfolder); the session root when there is none.
    static func projectRoot(file: String, sessionRoot: String, markers: [String], exists: (String) -> Bool) -> String {
        let root = sessionRoot.count > 1 && sessionRoot.hasSuffix("/") ? String(sessionRoot.dropLast()) : sessionRoot
        guard file.hasPrefix(root + "/") else { return root }
        var dir = (file as NSString).deletingLastPathComponent
        while dir.count >= root.count {
            if markers.contains(where: { exists(dir + "/" + $0) }) { return dir }
            if dir == root { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return root
    }

    /// `PATH` from the login shell's output (`HANGAR-PATH=…`; an interactive shell may print noise around it).
    static func parsePath(_ out: String) -> [String] {
        guard let line = out.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("HANGAR-PATH=") }) else { return [] }
        return line.dropFirst("HANGAR-PATH=".count).split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    // MARK: Paths

    static func uri(_ path: String) -> String { URL(fileURLWithPath: path, isDirectory: false).absoluteString }

    /// A `file://` URI's path; anything else (another scheme, a remote host) is nil.
    static func path(_ any: Any?) -> String? {
        guard let s = any as? String, s.utf8.count <= 8192, let url = URL(string: s), url.scheme == "file",
              (url.host ?? "").isEmpty || url.host == "localhost" else { return nil }
        let p = url.path
        return p.hasPrefix("/") && !p.contains("\0") ? p : nil
    }

    /// Toolchain folders found at run time (GOROOT, the Xcode developer folder), realpath'd.
    static let dependencyRoots = DependencyRoots()

    final class DependencyRoots: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [String] = []
        func add(_ list: [String]) {
            let real = list.filter { $0.hasPrefix("/") && $0.count > 1 }.map(LspMap.resolved)
            lock.lock(); defer { lock.unlock() }
            for r in real where !roots.contains(r) { roots.append(r) }
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return roots }
    }

    /// Folders of installed packages and toolchains: go-to-definition may land there, read-only.
    static func isDependency(_ path: String) -> Bool {
        let roots = dependencyRoots.all
        if !roots.isEmpty {
            let real = resolved(path)
            if roots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) { return true }
        }
        let parts = path.split(separator: "/")
        if parts.contains("node_modules") || parts.contains("site-packages") || parts.contains(".rustup") { return true }
        for (a, b) in zip(parts, parts.dropFirst()) {
            if a == "pkg" && b == "mod" { return true }
            if a == ".cargo" && (b == "registry" || b == "git") { return true }
        }
        return false
    }

    /// realpath; for a path that doesn't exist (yet), its nearest existing folder's realpath + the rest.
    static func resolved(_ path: String) -> String {
        if let p = realpath(path, nil) { defer { free(p) }; return String(cString: p) }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        return (resolved(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// Absolute, no `..` / NUL, and — after resolving symlinks (`resolve`, realpath) — inside one of the (resolved)
    /// `roots` or a dependency folder: a symlink in the project pointing at ~/.ssh is refused.
    static func allowed(_ path: String, roots: [String], resolve: (String) -> String = resolved) -> Bool {
        guard TsMap.allowed(path, roots: roots + [path]) else { return false }  // the shape checks only
        let real = resolve(path)
        guard TsMap.allowed(real, roots: [real]) else { return false }
        return isDependency(real) || TsMap.allowed(real, roots: roots.map(resolve))
    }

    // MARK: Positions

    /// An LSP position (0-based, UTF-16) → Monaco's 1-based line and column.
    private static func position(_ any: Any?) -> (Int, Int)? {
        guard let p = any as? [String: Any], let l = int(p["line"]), let c = int(p["character"]),
              l < maxPosition, c < maxPosition else { return nil }
        return (l + 1, c + 1)
    }

    private static func int(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber, !LspMessage.isBool(n), let i = n as? Int, i >= 0 else { return nil }
        return i
    }

    static func range(_ any: Any?) -> (Int, Int, Int, Int)? {
        guard let r = any as? [String: Any], let (l, c) = position(r["start"]), let (el, ec) = position(r["end"]),
              (el, ec) >= (l, c) else { return nil }
        return (l, c, el, ec)
    }

    static func lspPosition(line: Int, column: Int) -> [String: Any] { ["line": max(line - 1, 0), "character": max(column - 1, 0)] }

    static func lspRange(_ e: EditorEdit) -> [String: Any] {
        ["start": lspPosition(line: e.line, column: e.column), "end": lspPosition(line: e.endLine, column: e.endColumn)]
    }

    // MARK: Results

    /// `Location | Location[] | LocationLink[]` → locations; bad, refused and duplicate entries go.
    static func locations(_ result: Any?, roots: [String]) -> [EditorLocation] {
        let list: [Any] = result as? [Any] ?? (result.map { [$0] } ?? [])
        var out: [EditorLocation] = []
        for item in list.prefix(maxItems) {
            guard let loc = item as? [String: Any] else { continue }
            let link = loc["targetUri"] != nil
            guard let file = path(link ? loc["targetUri"] : loc["uri"]), allowed(file, roots: roots),
                  let (l, c, el, ec) = range(link ? (loc["targetSelectionRange"] ?? loc["targetRange"]) : loc["range"]) else { continue }
            let e = EditorLocation(path: file, line: l, column: c, endLine: el, endColumn: ec)
            if !out.contains(e) { out.append(e) }
        }
        return out
    }

    private static func capped(_ s: String) -> String { s.count > maxText ? String(s.prefix(maxText)) + "…" : s }

    private static func fenced(_ code: String, language: String) -> String {
        let lang = language.count <= 32 && language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) ? language : ""
        return "```" + lang + "\n" + capped(code).replacingOccurrences(of: "```", with: "`\u{200B}``") + "\n```"
    }

    /// `MarkupContent | MarkedString | MarkedString[]` → markdown (plain text as a code block, so nothing renders).
    static func markdown(_ any: Any?) -> String? {
        let parts: [String]
        if let s = any as? String {
            parts = [capped(s)]
        } else if let m = any as? [String: Any], let value = m["value"] as? String {
            if let kind = m["kind"] as? String {
                parts = [kind == "markdown" ? capped(value) : fenced(value, language: "")]
            } else {
                parts = [fenced(value, language: m["language"] as? String ?? "")]
            }
        } else if let list = any as? [Any] {
            parts = list.prefix(20).compactMap { markdown($0) }
        } else {
            return nil
        }
        let md = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
        return md.isEmpty ? nil : md
    }

    static func hover(_ result: Any?) -> String? { markdown((result as? [String: Any])?["contents"]) }

    /// A completion's `textEdit` range (or an InsertReplaceEdit's insert / replace ranges), when Monaco can use it:
    /// one line, containing the asked position (`line`, `column`, 1-based); otherwise nil (the word range is used).
    static func completionRange(_ edit: Any?, line: Int, column: Int) -> EditorCompletion.Range? {
        guard let e = edit as? [String: Any] else { return nil }
        func usable(_ any: Any?) -> (Int, Int)? {
            guard let (l, c, el, ec) = range(any), l == line, el == line, c <= column, column <= ec else { return nil }
            return (c, ec)
        }
        if let r = usable(e["range"]) { return EditorCompletion.Range(start: r.0, end: r.1, replaceEnd: r.1) }
        guard let i = usable(e["insert"]), let r = usable(e["replace"]), r.0 == i.0, r.1 >= i.1 else { return nil }
        return EditorCompletion.Range(start: i.0, end: i.1, replaceEnd: r.1)
    }

    /// `CompletionItem[] | CompletionList` → entries, and the raw items by label (for `completionItem/resolve`).
    /// `line`, `column`: where completion was asked (for the items' own ranges).
    static func completions(_ result: Any?, line: Int = 0, column: Int = 0) -> ([EditorCompletion], [String: [String: Any]]) {
        let items = ((result as? [String: Any])?["items"] ?? result) as? [Any] ?? []
        var out: [EditorCompletion] = [], raw: [String: [String: Any]] = [:]
        for item in items.prefix(TsMap.maxCompletions) {
            guard let i = item as? [String: Any], let label = i["label"] as? String, !label.isEmpty, label.utf8.count <= 512,
                  raw[label] == nil else { continue }
            let snippet = (i["insertTextFormat"] as? Int) == 2
            let text = ((i["textEdit"] as? [String: Any])?["newText"] as? String) ?? (i["insertText"] as? String) ?? label
            let insert = text.count <= maxText ? (snippet ? Self.snippet(text) : text) : label
            let detail = (i["detail"] as? String).map { String($0.prefix(256)) }
            var item = EditorCompletion(label: label, detail: detail, insertText: insert, kind: kindName(i["kind"]),
                                        sortText: (i["sortText"] as? String).map { String($0.prefix(64)) }, snippet: snippet && insert != label)
            if insert == text { item.range = completionRange(i["textEdit"], line: line, column: column) }
            out.append(item)
            raw[label] = i
        }
        return (out, raw)
    }

    /// A server's snippet with its tab stops (`$1`, `${2:x}`, `${3|a,b|}`) only: every other `$` is escaped, so a
    /// variable (`$CLIPBOARD`, `${TM_FILENAME}`) can't put the clipboard or anything else into the buffer.
    static func snippet(_ s: String) -> String {
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out += String([c, chars[i + 1]]); i += 2; continue
            }
            if c == "$" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let after = i + 2 < chars.count ? chars[i + 2] : " "
                if !(next.isASCII && next.isNumber) && !(next == "{" && after.isASCII && after.isNumber) { out += "\\$"; i += 1; continue }
            }
            out.append(c); i += 1
        }
        return out
    }

    /// A completion item's docs: its detail as code, then the documentation.
    static func details(_ item: Any?, language: String) -> String? {
        guard let i = item as? [String: Any] else { return nil }
        let detail = (i["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [detail.isEmpty ? nil : fenced(detail, language: language), markdown(i["documentation"])].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// LSP `CompletionItemKind` → the tsserver kind names the page's icons know.
    static func kindName(_ any: Any?) -> String? {
        switch any as? Int {
        case 2: "method"
        case 3: "function"
        case 4: "constructor"
        case 5, 10: "property"
        case 6: "var"
        case 7, 22: "class"
        case 8: "interface"
        case 9: "module"
        case 13: "enum"
        case 14: "keyword"
        case 17: "script"
        case 19: "directory"
        case 20: "enum member"
        case 21: "const"
        case 25: "type parameter"
        default: nil
        }
    }

    /// `textDocument/publishDiagnostics` params → the file and its markers.
    static func diagnostics(_ params: Any?) -> (String, [EditorDiagnostic])? {
        guard let p = params as? [String: Any], let file = path(p["uri"]), let list = p["diagnostics"] as? [Any] else { return nil }
        let out: [EditorDiagnostic] = list.prefix(maxItems).compactMap { item in
            guard let d = item as? [String: Any], let (l, c, el, ec) = range(d["range"]), let message = d["message"] as? String else { return nil }
            let severity: EditorDiagnostic.Severity = switch d["severity"] as? Int {
            case 2: .warning
            case 3: .info
            case 4: .hint
            default: .error
            }
            let source = (d["source"] as? String).map { String($0.prefix(64)) } ?? ""
            let code = (d["code"] as? String).map { String($0.prefix(64)) } ?? (d["code"] as? Int).map(String.init) ?? ""
            let tag = [source, code].filter { !$0.isEmpty }.joined(separator: " ")
            return EditorDiagnostic(line: l, column: c, endLine: el, endColumn: ec, severity: severity,
                                    message: capped(message) + (tag.isEmpty ? "" : " (\(tag))"))
        }
        return (file, out)
    }

    /// `TextEdit[]` → edits (formatting).
    static func edits(_ result: Any?) -> [EditorEdit] {
        guard let list = result as? [Any] else { return [] }
        return list.prefix(maxItems * 10).compactMap { item in
            guard let e = item as? [String: Any], let (l, c, el, ec) = range(e["range"]), let text = e["newText"] as? String,
                  text.count <= maxText else { return nil }
            return EditorEdit(line: l, column: c, endLine: el, endColumn: ec, text: text)
        }
    }

    /// `WorkspaceEdit` → spans of `file` (the page writes `prefix + newName + suffix`). shortcut: as for tsserver (#82),
    /// a rename that reaches other files is refused; lift when the editor can apply edits to unopened files.
    @MainActor static func rename(_ result: Any?, file: String, newName: String) -> ProviderResult? {
        guard let w = result as? [String: Any] else { return nil }
        var groups: [(String, Any?)] = []
        if let changes = w["documentChanges"] as? [Any] {
            for c in changes.prefix(maxItems) {
                guard let d = c as? [String: Any], let doc = d["textDocument"] as? [String: Any] else {
                    return .rejected(L10n.editorRenameOtherFiles)  // create / rename / delete a file
                }
                groups.append((path(doc["uri"]) ?? "", d["edits"]))
            }
        } else if let changes = w["changes"] as? [String: Any] {
            for (uri, edits) in changes.prefix(maxItems) { groups.append((path(uri) ?? "", edits)) }
        }
        let same = { (p: String) in p == file || realPath(p) == realPath(file) }
        var out: [EditorRename] = []
        for (p, list) in groups {
            guard same(p) else { return .rejected(L10n.editorRenameOtherFiles) }
            for e in edits(list) {
                guard let r = e.text.range(of: newName) else { return .rejected(L10n.editorRenameRefused) }
                out.append(EditorRename(line: e.line, column: e.column, endLine: e.endLine, endColumn: e.endColumn,
                                        prefix: String(e.text[..<r.lowerBound].prefix(256)), suffix: String(e.text[r.upperBound...].prefix(256))))
            }
        }
        return out.isEmpty ? nil : .renames(out)
    }

    // MARK: Session

    /// What the server can do (from `initialize`); a capability is on when it is `true` or an options object.
    struct Capabilities: Equatable {
        /// 0 none, 1 full text, 2 incremental.
        var sync = 0
        var definition = false, references = false, hover = false, completion = false, resolve = false
        var rename = false, prepareRename = false, formatting = false

        init() {}

        init(_ result: Any?) {
            guard let c = (result as? [String: Any])?["capabilities"] as? [String: Any] else { return }
            func on(_ key: String) -> Bool { (c[key] as? NSNumber).map { LspMessage.isBool($0) && $0.boolValue } ?? (c[key] is [String: Any]) }
            let s = c["textDocumentSync"]
            let kind = (s as? [String: Any])?["change"] ?? s
            sync = (kind as? Int).flatMap { (0...2).contains($0) ? $0 : nil } ?? 0
            definition = on("definitionProvider")
            references = on("referencesProvider")
            hover = on("hoverProvider")
            completion = on("completionProvider")
            resolve = (c["completionProvider"] as? [String: Any])?["resolveProvider"] as? Bool == true
            rename = on("renameProvider")
            prepareRename = (c["renameProvider"] as? [String: Any])?["prepareProvider"] as? Bool == true
            formatting = on("documentFormattingProvider")
        }
    }

    static func initialize(root: String, processId: Int32, locale: String) -> [String: Any] {
        let uri = uri(root)
        return [
            "processId": Int(processId), "rootUri": uri, "rootPath": root, "locale": locale,
            "clientInfo": ["name": "Hangar"],
            "workspaceFolders": [["uri": uri, "name": (root as NSString).lastPathComponent]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["configuration": true, "workspaceFolders": true],
                "window": ["workDoneProgress": false],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false, "didSave": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "completion": ["completionItem": ["snippetSupport": true, "insertReplaceSupport": true, "documentationFormat": ["markdown", "plaintext"]]],
                    "definition": ["linkSupport": true],
                    "references": [String: Any](),
                    "rename": ["prepareSupport": true],
                    "formatting": [String: Any](),
                    "publishDiagnostics": ["relatedInformation": false],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// The answer to a server → client request; nil = not supported (an error goes back).
    static func reply(_ method: String, _ params: Any?, folders: [[String: Any]]) -> Any? {
        switch method {
        case "workspace/configuration":
            // No settings of ours: the server's defaults (one null per asked section).
            let n = min(((params as? [String: Any])?["items"] as? [Any])?.count ?? 0, 1000)
            return Array(repeating: NSNull(), count: n)
        case "workspace/workspaceFolders": return folders
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
             "window/showMessageRequest": return NSNull()
        case "workspace/applyEdit": return ["applied": false]
        default: return nil
        }
    }
}
