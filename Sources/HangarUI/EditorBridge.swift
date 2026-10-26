import AppKit
import Workspace

/// Size rules of the editor (#80): up to `editable` bytes a file is edited, up to `refuse` read-only, above — refused.
struct EditorLimits: Equatable, Sendable {
    static let editableBytes = 2 << 20
    static let refuseBytes = 5 << 20
    var editable = editableBytes
    var refuse = refuseBytes
}

// MARK: JS → Swift

/// A language-feature request from Monaco (answered by tsserver, #82). `details`: a completion entry's docs by `name`;
/// `format`: the position is the document's end (the whole file is formatted).
struct ProviderRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case definition, references, hover, completion, details, rename, format, semantic }
    var id: Int
    var kind: Kind
    var file: String
    var line: Int
    var column: Int
    var name: String? = nil
    /// `format`: the editor's indentation.
    var tabSize: Int? = nil
    var insertSpaces: Bool? = nil
    /// `semantic`: the buffer's length (UTF-16 units), the whole file is classified.
    var length: Int? = nil
}

/// One Monaco content change (1-based, end exclusive), in the order Monaco gives them (safe to apply in sequence).
struct EditorEdit: Equatable, Sendable {
    var line: Int, column: Int, endLine: Int, endColumn: Int
    var text: String
}

/// One message of `window.webkit.messageHandlers.hangar.postMessage(JSON.stringify(m))`. The page is untrusted input:
/// a message decodes only as a JSON string within the size limit, with every field of the right type and range.
enum BridgeMessage: Equatable {
    case ready
    /// The editor got keyboard focus (remote files are re-checked).
    case focus
    case changed(file: String, dirty: Bool)
    case save(file: String, text: String)
    case cursor(file: String, line: Int, column: Int)
    /// The diff: open the working file in the editor here.
    case openAt(line: Int, column: Int)
    /// Go to definition landed in another file.
    case openFile(file: String, line: Int, column: Int)
    /// The conflict bar's choice.
    case conflict(file: String, keepMine: Bool)
    case inline(Bool)
    case request(ProviderRequest)
    /// The context menu's Cut / Copy / Paste.
    case clipboard(ClipboardAction)
    /// A TS/JS buffer changed (forwarded to tsserver).
    case edit(file: String, [EditorEdit])
    /// The status item's click: restart the file's language server.
    case restartLanguage(file: String)
    /// A script error in the page (to the app log; capped).
    case log(String)

    static let maxBytes = 2 * EditorLimits.refuseBytes + 65_536
    private static let maxPath = 4096
    private static let maxPosition = 10_000_000
    private static let maxEdits = 10_000

    static func decode(_ body: Any) -> BridgeMessage? { envelope(body)?.message }

    /// The message and the file tab it is about (`doc`: the editor leaf's id; nil for the page itself or the diff).
    static func envelope(_ body: Any) -> (doc: UUID?, message: BridgeMessage)? {
        guard let string = body as? String, string.utf8.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              let m = object as? [String: Any], m["type"] is String else { return nil }
        var doc: UUID?
        if let raw = m["doc"] {
            guard let s = raw as? String, let id = UUID(uuidString: s) else { return nil }
            doc = id
        }
        return message(m).map { (doc, $0) }
    }

    private static func message(_ m: [String: Any]) -> BridgeMessage? {
        guard let type = m["type"] as? String else { return nil }
        func str(_ key: String) -> String? { m[key] as? String }
        func file() -> String? {
            guard let f = str("file"), f.hasPrefix("/"), f.utf8.count <= maxPath, !f.contains("\0") else { return nil }
            return f
        }
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            guard let n = m[key] as? NSNumber, !isBool(n), let v = n as? Int, range.contains(v) else { return nil }
            return v
        }
        func bool(_ key: String) -> Bool? {
            guard let n = m[key] as? NSNumber, isBool(n) else { return nil }
            return n.boolValue
        }
        func position() -> (Int, Int)? {
            guard let l = int("line", 1...maxPosition), let c = int("column", 1...maxPosition) else { return nil }
            return (l, c)
        }
        switch type {
        case "ready": return .ready
        case "log": return str("text").map { .log(String($0.prefix(2000))) }
        case "focus": return .focus
        case "changed":
            guard let f = file(), let d = bool("dirty") else { return nil }
            return .changed(file: f, dirty: d)
        case "save":
            guard let f = file(), let t = str("text"), t.utf8.count <= EditorLimits.refuseBytes else { return nil }
            return .save(file: f, text: t)
        case "cursor":
            guard let f = file(), let (l, c) = position() else { return nil }
            return .cursor(file: f, line: l, column: c)
        case "openFile":
            guard let f = file(), let (l, c) = position() else { return nil }
            return .openFile(file: f, line: l, column: c)
        case "openAt":
            guard let (l, c) = position() else { return nil }
            return .openAt(line: l, column: c)
        case "conflict":
            guard let f = file(), let k = bool("keepMine") else { return nil }
            return .conflict(file: f, keepMine: k)
        case "clipboard": return str("action").flatMap(ClipboardAction.init(rawValue:)).map { .clipboard($0) }
        case "inline": return bool("on").map { .inline($0) }
        case "request":
            guard let id = int("id", 0...Int(Int32.max)), let kind = str("kind").flatMap(ProviderRequest.Kind.init(rawValue:)),
                  let f = file(), let (l, c) = position() else { return nil }
            let name = str("name")
            if kind == .details { guard let name, !name.isEmpty, name.utf8.count <= 512 else { return nil } }
            var r = ProviderRequest(id: id, kind: kind, file: f, line: l, column: c, name: kind == .details ? name : nil)
            if kind == .format {
                guard let tab = int("tabSize", 1...16), let spaces = bool("insertSpaces") else { return nil }
                (r.tabSize, r.insertSpaces) = (tab, spaces)
            }
            if kind == .semantic {
                guard let length = int("length", 0...maxBytes) else { return nil }
                r.length = length
            }
            return .request(r)
        case "edit":
            guard let f = file(), let list = m["changes"] as? [[String: Any]], list.count <= maxEdits else { return nil }
            var edits: [EditorEdit] = []
            for e in list {
                func n(_ key: String) -> Int? {
                    guard let v = e[key] as? NSNumber, !isBool(v), let i = v as? Int, (1...maxPosition).contains(i) else { return nil }
                    return i
                }
                guard let l = n("line"), let c = n("column"), let el = n("endLine"), let ec = n("endColumn"),
                      let t = e["text"] as? String else { return nil }
                edits.append(EditorEdit(line: l, column: c, endLine: el, endColumn: ec, text: t))
            }
            return .edit(file: f, edits)
        case "restartLanguage": return file().map { .restartLanguage(file: $0) }
        default: return nil
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

enum ClipboardAction: String, Sendable {
    case cut, copy, paste

    var selector: Selector {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        }
    }
}

// MARK: Swift → JS

struct EditorLocation: Equatable, Sendable {
    var path: String
    var line: Int
    var column: Int
    var endLine: Int? = nil
    var endColumn: Int? = nil
}

struct EditorCompletion: Equatable, Sendable {
    var label: String
    var detail: String?
    var insertText: String
    /// tsserver's `ScriptElementKind` (`method`, `property` …): the icon in the list.
    var kind: String? = nil
    var sortText: String? = nil
}

/// The status item of the editor's tab bar for a TS/JS file (#82).
struct LanguageStatus: Equatable, Sendable {
    enum Level: String, Sendable { case ready, busy, off }
    var text: String
    var tooltip: String
    var level: Level
}

/// A marker of the language server (M2); 1-based, end exclusive.
struct EditorDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable { case error, warning, info, hint }
    var line: Int, column: Int, endLine: Int, endColumn: Int
    var severity: Severity
    var message: String
}

/// A language request's answer; nil = nothing found.
enum ProviderResult: Equatable, Sendable {
    /// `previews`: texts of files the page has no model for (the references peek shows their lines).
    case locations([EditorLocation], previews: [String: String])
    case hover(markdown: String)
    case completions([EditorCompletion])
    /// `format`: edits of the asked file (Monaco applies them; the page mirrors them to tsserver as usual).
    case edits([EditorEdit])
    /// `rename`: spans of the asked file; the page writes `prefix + newName + suffix` into each.
    case renames([EditorRename])
    /// `rename` refused, with the reason shown in the editor.
    case rejected(String)
    /// `semantic`: start, length, type, modifiers per span (TS 2020 legend, #84).
    case semantic([Int])
}

/// One span of a rename (1-based, end exclusive).
struct EditorRename: Equatable, Sendable {
    var line: Int, column: Int, endLine: Int, endColumn: Int
    var prefix: String, suffix: String
}

/// Settings → Editor (#84): the syntax palette, rainbow indents, TODO pills; and the app theme's editor chrome
/// (Monaco themes + the page's CSS variables) — every editor and diff page, at load and live.
struct EditorAppearance: Equatable {
    var palette: HangarConfig.EditorPalette
    var rainbow: Bool
    var todo: Bool
    var theme: AppTheme

    init(_ config: HangarConfig) {
        palette = config.editorPalette
        rainbow = config.editorRainbowIndent
        todo = config.editorTodoHighlight
        theme = config.theme
    }

    var json: [String: Any] {
        let p = ThemePalette.of(theme)
        return ["palette": palette.rawValue, "rainbow": rainbow, "todo": todo, "themes": MonacoTheme.all(p), "css": MonacoTheme.css(p)]
    }
}

struct EditorOpen: Equatable {
    var path: String
    /// nil: refused (`notice` says why).
    var text: String?
    var readOnly: Bool
    var notice: String?
    var line: Int
    var column: Int
}

/// The diff tab's two sides (`modified` editable when `path` is set: a working-tree file that saves there).
struct EditorDiff: Equatable {
    var name: String
    var original: String
    var modified: String
    var path: String?
    var line: Int?
}

/// One call of `hangar.receive(cmd)` in the page.
enum EditorCommand: Equatable {
    case open(EditorOpen)
    case activate(path: String, line: Int?, column: Int?)
    case close(path: String)
    case reload(path: String, text: String)
    case saved(path: String)
    case conflict(path: String, shown: Bool)
    /// A calm line over the file (save failed); nil text hides it.
    case notice(path: String, text: String?)
    case resolve(id: Int, result: ProviderResult?)
    case markers(path: String, [EditorDiagnostic])
    /// nil hides the status item for that file.
    case language(path: String, LanguageStatus?)
    case diff(EditorDiff)
    case options(inline: Bool, minimap: Bool)
    case focus
    case appearance(EditorAppearance)

    /// With the file tab it is for (the shared editor page, #83).
    func json(doc: UUID?) -> Any {
        guard var object = json as? [String: Any] else { return json }
        if let doc { object["doc"] = doc.uuidString }
        return object
    }

    var json: Any {
        switch self {
        case .open(let o):
            return ["type": "open", "path": o.path, "text": n(o.text), "readOnly": o.readOnly, "notice": n(o.notice),
                    "line": o.line, "column": o.column]
        case .activate(let p, let l, let c): return ["type": "activate", "path": p, "line": n(l), "column": n(c)]
        case .close(let p): return ["type": "close", "path": p]
        case .reload(let p, let t): return ["type": "reload", "path": p, "text": t]
        case .saved(let p): return ["type": "saved", "path": p]
        case .conflict(let p, let shown): return ["type": "conflict", "path": p, "shown": shown]
        case .notice(let p, let t): return ["type": "notice", "path": p, "text": n(t)]
        case .resolve(let id, let result): return ["type": "resolve", "id": id, "result": n(result.map(Self.json))]
        case .markers(let p, let list):
            return ["type": "markers", "path": p, "markers": list.map {
                ["line": $0.line, "column": $0.column, "endLine": $0.endLine, "endColumn": $0.endColumn,
                 "severity": $0.severity.rawValue, "message": $0.message] as [String: Any]
            }]
        case .language(let p, let s):
            return ["type": "language", "path": p,
                    "status": n(s.map { ["text": $0.text, "tooltip": $0.tooltip, "level": $0.level.rawValue] })]
        case .diff(let d):
            return ["type": "diff", "name": d.name, "original": d.original, "modified": d.modified, "path": n(d.path),
                    "line": n(d.line)]
        case .options(let inline, let minimap): return ["type": "options", "inline": inline, "minimap": minimap]
        case .focus: return ["type": "focus"]
        case .appearance(let a): return a.json.merging(["type": "appearance"]) { $1 }
        }
    }

    /// JS gets `null` for nil (WebKit can't pass an Optional).
    private func n(_ value: Any?) -> Any { value ?? NSNull() }

    private static func json(_ r: ProviderResult) -> [String: Any] {
        switch r {
        case .locations(let list, let previews):
            return ["kind": "locations", "previews": previews, "items": list.map {
                ["path": $0.path, "line": $0.line, "column": $0.column, "endLine": $0.endLine ?? $0.line,
                 "endColumn": $0.endColumn ?? $0.column] as [String: Any]
            }]
        case .hover(let markdown): return ["kind": "hover", "markdown": markdown]
        case .completions(let list):
            return ["kind": "completions", "items": list.map {
                ["label": $0.label, "detail": $0.detail ?? NSNull(), "insertText": $0.insertText, "kind": $0.kind ?? NSNull(),
                 "sortText": $0.sortText ?? NSNull()] as [String: Any]
            }]
        case .edits(let list):
            return ["kind": "edits", "items": list.map {
                ["line": $0.line, "column": $0.column, "endLine": $0.endLine, "endColumn": $0.endColumn, "text": $0.text] as [String: Any]
            }]
        case .renames(let list):
            return ["kind": "renames", "items": list.map {
                ["line": $0.line, "column": $0.column, "endLine": $0.endLine, "endColumn": $0.endColumn,
                 "prefix": $0.prefix, "suffix": $0.suffix] as [String: Any]
            }]
        case .rejected(let reason): return ["kind": "rejected", "reason": reason]
        case .semantic(let data): return ["kind": "semantic", "data": data]
        }
    }
}
