import Foundation

/// tsserver answers → editor results (#82). Everything here reads untrusted JSON: wrong types are skipped, lists and
/// strings are capped, and a path from an answer must be inside the project (or a node_modules) to be shown.
enum TsMap {
    static let maxItems = 1000
    static let maxCompletions = 2000
    static let maxText = 20_000
    private static let maxPath = 4096

    /// tsserver's `scriptKindName`; nil = not a TS/JS file.
    static func scriptKind(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "mts", "cts": "TS"
        case "tsx": "TSX"
        case "js", "mjs", "cjs": "JS"
        case "jsx": "JSX"
        default: nil
        }
    }

    static func isDependency(_ path: String) -> Bool { path.split(separator: "/").contains("node_modules") }

    /// Absolute, no `..` / NUL, and inside one of `roots` or a node_modules folder.
    static func allowed(_ path: String, roots: [String]) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maxPath, !path.contains("\0") else { return false }
        let parts = path.split(separator: "/")
        guard !parts.contains(".."), !parts.contains(".") else { return false }
        if parts.contains("node_modules") { return true }
        return roots.contains { root in
            let r = root.hasSuffix("/") ? String(root.dropLast()) : root
            return !r.isEmpty && (path == r || path.hasPrefix(r + "/"))
        }
    }

    private static func position(_ any: Any?) -> (Int, Int)? {
        guard let p = any as? [String: Any], let l = p["line"] as? Int, let o = p["offset"] as? Int, l >= 1, o >= 1 else { return nil }
        return (l, o)
    }

    /// File spans (`{file, start, end}`) → locations; bad or refused entries and duplicates go.
    static func locations(_ items: Any?, roots: [String]) -> [EditorLocation] {
        guard let list = items as? [Any] else { return [] }
        var out: [EditorLocation] = []
        for item in list.prefix(maxItems) {
            guard let span = item as? [String: Any], let file = span["file"] as? String, allowed(file, roots: roots),
                  let (l, o) = position(span["start"]) else { continue }
            let (el, eo) = position(span["end"]) ?? (l, o)
            let loc = EditorLocation(path: file, line: l, column: o, endLine: el, endColumn: eo)
            if !out.contains(loc) { out.append(loc) }
        }
        return out
    }

    /// `definitionAndBoundSpan` (`{definitions}`) or plain `definition` (an array).
    static func definition(_ body: Any?, roots: [String]) -> [EditorLocation] {
        locations((body as? [String: Any])?["definitions"] ?? body, roots: roots)
    }

    static func references(_ body: Any?, roots: [String]) -> [EditorLocation] {
        locations((body as? [String: Any])?["refs"], roots: roots)
    }

    /// A string or SymbolDisplayPart[] (both occur across TS versions).
    private static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        guard let parts = any as? [Any] else { return "" }
        return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    private static func capped(_ s: String) -> String { s.count > maxText ? String(s.prefix(maxText)) + "…" : s }

    /// Signature in a code block, then the docs and JSDoc tags.
    private static func markdown(signature: String, docs: String, tags: Any?) -> String? {
        let sig = capped(signature.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !sig.isEmpty else { return nil }
        var md = "```typescript\n" + sig.replacingOccurrences(of: "```", with: "`\u{200B}``") + "\n```"
        let d = capped(docs.trimmingCharacters(in: .whitespacesAndNewlines))
        if !d.isEmpty { md += "\n\n" + d }
        for tag in (tags as? [Any] ?? []).prefix(50) {
            guard let t = tag as? [String: Any], let name = t["name"] as? String, !name.isEmpty, name.count < 64 else { continue }
            let value = capped(text(t["text"]).trimmingCharacters(in: .whitespacesAndNewlines))
            md += "\n\n*@\(name)*" + (value.isEmpty ? "" : " " + value)
        }
        return md
    }

    static func hover(_ body: Any?) -> String? {
        guard let b = body as? [String: Any], let sig = b["displayString"] as? String else { return nil }
        return markdown(signature: sig, docs: text(b["documentation"]), tags: b["tags"])
    }

    static func details(_ body: Any?) -> String? {
        guard let first = (body as? [Any])?.first as? [String: Any] else { return nil }
        return markdown(signature: text(first["displayParts"]), docs: text(first["documentation"]), tags: first["tags"])
    }

    static func completions(_ body: Any?) -> [EditorCompletion] {
        let entries = ((body as? [String: Any])?["entries"] ?? body) as? [Any] ?? []
        return entries.prefix(maxCompletions).compactMap { item in
            guard let e = item as? [String: Any], let name = e["name"] as? String, !name.isEmpty, name.count <= 512 else { return nil }
            let insert = (e["insertText"] as? String).flatMap { $0.count <= maxText ? $0 : nil } ?? name
            return EditorCompletion(label: name, detail: nil, insertText: insert, kind: (e["kind"] as? String).map { String($0.prefix(32)) },
                                    sortText: (e["sortText"] as? String).map { String($0.prefix(64)) })
        }
    }

    /// A `syntaxDiag` / `semanticDiag` event body → its file and markers.
    static func diagnostics(_ body: Any?) -> (String, [EditorDiagnostic])? {
        guard let b = body as? [String: Any], let file = b["file"] as? String, let list = b["diagnostics"] as? [Any] else { return nil }
        let out: [EditorDiagnostic] = list.prefix(maxItems).compactMap { item in
            guard let d = item as? [String: Any], let (l, c) = position(d["start"]), var (el, ec) = position(d["end"]),
                  let message = d["text"] as? String else { return nil }
            if (el, ec) < (l, c) { (el, ec) = (l, c) }
            let severity: EditorDiagnostic.Severity = switch d["category"] as? String {
            case "warning": .warning
            case "suggestion": .hint
            case "message": .info
            default: .error
            }
            let code = (d["code"] as? Int).map { " (TS\($0))" } ?? ""
            return EditorDiagnostic(line: l, column: c, endLine: el, endColumn: ec, severity: severity, message: capped(message) + code)
        }
        return (file, out)
    }

    /// `format` (CodeEdit[]) → edits of the formatted file.
    static func format(_ body: Any?) -> [EditorEdit] {
        guard let list = body as? [Any] else { return [] }
        return list.prefix(maxItems * 10).compactMap { item in
            guard let e = item as? [String: Any], let (l, c) = position(e["start"]), let (el, ec) = position(e["end"]),
                  (el, ec) >= (l, c), let text = e["newText"] as? String, text.count <= maxText else { return nil }
            return EditorEdit(line: l, column: c, endLine: el, endColumn: ec, text: text)
        }
    }

    /// `rename` → spans in `file`. shortcut: a rename that reaches other files is refused (they may be unopened or
    /// unsaved, so no partial rename is written); lift when the editor can apply edits to files it has not opened.
    @MainActor static func rename(_ body: Any?, file: String) -> ProviderResult? {
        guard let b = body as? [String: Any], let info = b["info"] as? [String: Any] else { return nil }
        guard info["canRename"] as? Bool == true else {
            let why = (info["localizedErrorMessage"] as? String).map { String($0.prefix(500)) } ?? ""
            return .rejected(why.isEmpty ? L10n.editorRenameRefused : why)
        }
        var out: [EditorRename] = []
        for group in (b["locs"] as? [Any] ?? []).prefix(maxItems) {
            guard let g = group as? [String: Any], let f = g["file"] as? String else { continue }
            guard f == file else { return .rejected(L10n.editorRenameOtherFiles) }
            for item in (g["locs"] as? [Any] ?? []).prefix(maxItems) {
                guard let span = item as? [String: Any], let (l, c) = position(span["start"]), let (el, ec) = position(span["end"]),
                      (el, ec) >= (l, c) else { continue }
                let prefix = (span["prefixText"] as? String).map { String($0.prefix(256)) } ?? ""
                let suffix = (span["suffixText"] as? String).map { String($0.prefix(256)) } ?? ""
                out.append(EditorRename(line: l, column: c, endLine: el, endColumn: ec, prefix: prefix, suffix: suffix))
            }
        }
        return out.isEmpty ? nil : .renames(out)
    }

    /// tsserver's 2020 token types (class … member) and modifiers (declaration … local): the page's legend.
    static let semanticTypes = 12, semanticModifiers = 6

    /// `encodedSemanticClassifications-full` (format 2020) → flat start, length, type, modifiers.
    static func semantic(_ body: Any?) -> [Int] {
        guard let spans = (body as? [String: Any])?["spans"] as? [Any] else { return [] }
        var out: [Int] = []
        var i = 0
        while i + 2 < spans.count, out.count < maxItems * 200 {
            defer { i += 3 }
            guard let start = spans[i] as? Int, let length = spans[i + 1] as? Int, let code = spans[i + 2] as? Int,
                  start >= 0, length > 0 else { continue }
            let type = (code >> 8) - 1, mods = code & 0xff
            guard (0..<semanticTypes).contains(type), mods < 1 << semanticModifiers else { continue }
            out += [start, length, type, mods]
        }
        return out
    }

    static func change(file: String, _ e: EditorEdit) -> [String: Any] {
        ["file": file, "line": e.line, "offset": e.column, "endLine": e.endLine, "endOffset": e.endColumn, "insertString": e.text]
    }

    // MARK: Finding the project's TypeScript

    struct Lookup: Equatable {
        var tsserver: String
        var version: String
        /// Empty: `command -v node` found nothing (with the PATH the script ran under).
        var node: String
    }

    /// `$1` = the file's folder, `$2` = the session root: the nearest `node_modules/typescript` walking up, never above
    /// the root; prints `HANGAR-TS<TAB>tsserver.js<TAB>version<TAB>node`.
    static let lookupScript = #"""
    d=$1; root=$2
    while :; do
      if [ -f "$d/node_modules/typescript/lib/tsserver.js" ]; then
        t="$d/node_modules/typescript"
        v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$t/package.json" 2>/dev/null | head -n 1)
        printf 'HANGAR-TS\t%s\t%s\t%s\n' "$t/lib/tsserver.js" "$v" "$(command -v node 2>/dev/null)"
        exit 0
      fi
      { [ "$d" = "$root" ] || [ "$d" = / ] || [ -z "$d" ]; } && break
      d=$(dirname -- "$d")
    done
    """#

    static func parseLookup(_ out: String) -> Lookup? {
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("HANGAR-TS\t") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[1].hasPrefix("/"), f[1].hasSuffix("/tsserver.js"), f[1].utf8.count <= maxPath,
                  !f[1].split(separator: "/").contains("..") else { return nil }
            let version = f[2].count <= 32 && f[2].allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } ? f[2] : ""
            let node = f[3].hasPrefix("/") && f[3].utf8.count <= maxPath ? f[3] : ""
            return Lookup(tsserver: f[1], version: version, node: node)
        }
        return nil
    }
}
