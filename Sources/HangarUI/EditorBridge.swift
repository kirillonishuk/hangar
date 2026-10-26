import AppKit

/// Size rules of the editor (#80): up to `editable` bytes a file is edited, up to `refuse` read-only, above — refused.
struct EditorLimits: Equatable, Sendable {
    static let editableBytes = 2 << 20
    static let refuseBytes = 5 << 20
    var editable = editableBytes
    var refuse = refuseBytes
}

// MARK: JS → Swift

/// A language-feature request from Monaco (M2 answers them from the language server).
struct ProviderRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case definition, references, hover, completion }
    var id: Int
    var kind: Kind
    var file: String
    var line: Int
    var column: Int
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
    case activate(file: String)
    case close(file: String)
    /// The diff: open the working file in the editor here.
    case openAt(line: Int, column: Int)
    /// Go to definition landed in another file.
    case openFile(file: String, line: Int, column: Int)
    /// The conflict bar's choice.
    case conflict(file: String, keepMine: Bool)
    case inline(Bool)
    case minimap(Bool)
    case request(ProviderRequest)
    /// The context menu's Cut / Copy / Paste.
    case clipboard(ClipboardAction)
    /// A script error in the page (to the app log; capped).
    case log(String)

    static let maxBytes = 2 * EditorLimits.refuseBytes + 65_536
    private static let maxPath = 4096
    private static let maxPosition = 10_000_000

    static func decode(_ body: Any) -> BridgeMessage? {
        guard let string = body as? String, string.utf8.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              let m = object as? [String: Any], let type = m["type"] as? String else { return nil }
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
        case "activate": return file().map { .activate(file: $0) }
        case "close": return file().map { .close(file: $0) }
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
        case "minimap": return bool("on").map { .minimap($0) }
        case "request":
            guard let id = int("id", 0...Int(Int32.max)), let kind = str("kind").flatMap(ProviderRequest.Kind.init(rawValue:)),
                  let f = file(), let (l, c) = position() else { return nil }
            return .request(ProviderRequest(id: id, kind: kind, file: f, line: l, column: c))
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
}

struct EditorCompletion: Equatable, Sendable {
    var label: String
    var detail: String?
    var insertText: String
}

/// A marker of the language server (M2); 1-based, end exclusive.
struct EditorDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable { case error, warning, info, hint }
    var line: Int, column: Int, endLine: Int, endColumn: Int
    var severity: Severity
    var message: String
}

/// The M2 hook's answer; nil from the provider = nothing found.
enum ProviderResult: Equatable, Sendable {
    case locations([EditorLocation])
    case hover(markdown: String)
    case completions([EditorCompletion])
}

/// Answers `ProviderRequest`s (set by the language-server track, M2); nil = no provider, Monaco shows nothing.
typealias EditorProvider = @MainActor (ProviderRequest) async -> ProviderResult?

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
    case diff(EditorDiff)
    case options(inline: Bool, minimap: Bool)
    case focus

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
        case .diff(let d):
            return ["type": "diff", "name": d.name, "original": d.original, "modified": d.modified, "path": n(d.path),
                    "line": n(d.line)]
        case .options(let inline, let minimap): return ["type": "options", "inline": inline, "minimap": minimap]
        case .focus: return ["type": "focus"]
        }
    }

    /// JS gets `null` for nil (WebKit can't pass an Optional).
    private func n(_ value: Any?) -> Any { value ?? NSNull() }

    private static func json(_ r: ProviderResult) -> [String: Any] {
        switch r {
        case .locations(let list):
            return ["kind": "locations", "items": list.map { ["path": $0.path, "line": $0.line, "column": $0.column] as [String: Any] }]
        case .hover(let markdown): return ["kind": "hover", "markdown": markdown]
        case .completions(let list):
            return ["kind": "completions", "items": list.map {
                ["label": $0.label, "detail": $0.detail ?? NSNull(), "insertText": $0.insertText] as [String: Any]
            }]
        }
    }
}
