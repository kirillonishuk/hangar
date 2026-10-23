import SwiftUI

// shortcut: a built-in per-line lexer (keywords, strings, comments, numbers, capitalized types) instead of tree-sitter
// grammars (#44); no nesting, interpolation, regex literals or heredocs — change when the user asks for precise highlighting.

enum SyntaxKind: Sendable, Equatable { case keyword, string, comment, number, type }

/// A colored run of a line, in UTF-8 offsets (plain text has none).
struct SyntaxSpan: Sendable, Equatable {
    var kind: SyntaxKind
    var range: Range<Int>
}

/// What a line leaves open for the next one.
enum SyntaxState: Sendable, Equatable {
    case normal
    case comment(close: [UInt8])
    case string(close: [UInt8], escapes: Bool)
    /// Markup: inside `<tag …` (attributes on the next lines).
    case tag
    /// Markdown: inside a fenced code block.
    case fence
}

struct SyntaxLanguage: Sendable {
    enum Mode: Sendable { case code, keyValue, css, markup, markdown }
    var mode = Mode.code
    var keywords: Set<String> = []
    var caseInsensitive = false
    /// Capitalized identifiers are types.
    var types = true
    var lineComments: [[UInt8]] = []
    var blockComment: (open: [UInt8], close: [UInt8])?
    /// Strings that may span lines, longest first.
    var multiline: [(delim: [UInt8], escapes: Bool)] = []
    var quotes: [UInt8] = [q2]
    /// Quotes without backslash escapes (shell `'…'`, SQL).
    var rawQuotes: [UInt8] = []
    /// `'x'` / `'\n'` is a char literal, any other `'` is plain (Rust lifetimes).
    var charQuote = false
    /// `@` starts a word (`@interface`, `@media`).
    var atWords = false
}

private let q2 = UInt8(ascii: "\""), q1 = UInt8(ascii: "'"), bt = UInt8(ascii: "`"), bs = UInt8(ascii: "\\")
private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }
private let cBlock = (open: b("/*"), close: b("*/"))
private let slash = [b("//")], hash = [b("#")]

private let swift = SyntaxLanguage(
    keywords: words("let var func if else guard return import struct class enum case switch default for in while repeat break continue protocol extension init deinit self Self super nil true false throws throw rethrows try catch do async await public private fileprivate internal open static final override mutating nonmutating inout where as is typealias associatedtype some any defer lazy weak unowned subscript operator get set willSet didSet convenience required indirect"),
    lineComments: slash, blockComment: cBlock, multiline: [(b("\"\"\""), true)])
private let js = SyntaxLanguage(
    keywords: words("const let var function return if else for while do switch case default break continue new delete typeof instanceof in of class extends super this import export from as async await yield try catch finally throw null undefined true false void interface type enum implements public private protected readonly static abstract declare namespace keyof satisfies"),
    lineComments: slash, blockComment: cBlock, multiline: [([bt], true)], quotes: [q2, q1])
private let python = SyntaxLanguage(
    keywords: words("def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal None True False async await del assert match case self"),
    lineComments: hash, multiline: [(b("\"\"\""), true), (b("'''"), true)], quotes: [q2, q1])
private let go = SyntaxLanguage(
    keywords: words("func package import var const type struct interface map chan go defer return if else for range switch case default break continue fallthrough select goto nil true false"),
    lineComments: slash, blockComment: cBlock, multiline: [([bt], false)], charQuote: true)
private let rust = SyntaxLanguage(
    keywords: words("fn let mut pub use mod struct enum impl trait for in while loop if else match return break continue as const static ref move self Self super crate where type unsafe async await dyn true false extern"),
    lineComments: slash, blockComment: cBlock, charQuote: true)
private let kotlin = SyntaxLanguage(
    keywords: words("class interface object fun val var if else when for while do return break continue package import public private protected internal open override abstract final static void new this super null true false try catch finally throw throws extends implements is in as int long boolean double float char byte short enum data sealed companion lateinit suspend record"),
    lineComments: slash, blockComment: cBlock, multiline: [(b("\"\"\""), true)], charQuote: true)
private let c = SyntaxLanguage(
    keywords: words("int char void short long float double signed unsigned const static extern struct union enum typedef sizeof if else for while do switch case default break continue return goto auto register volatile inline bool true false NULL nullptr class namespace template typename public private protected virtual override new delete this using include define ifdef ifndef endif elif pragma import @interface @implementation @end @property @protocol @selector @class self nil YES NO"),
    lineComments: slash, blockComment: cBlock, charQuote: true, atWords: true)
private let ruby = SyntaxLanguage(
    keywords: words("def end class module if elsif else unless while until for in do return yield begin rescue ensure raise then case when nil true false self and or not require"),
    lineComments: hash, quotes: [q2, q1])
private let shell = SyntaxLanguage(
    keywords: words("if then else elif fi for while until do done case esac in function return local export break continue"),
    types: false, lineComments: hash, rawQuotes: [q1])
private let json = SyntaxLanguage(keywords: words("true false null"), types: false, lineComments: slash, blockComment: cBlock)
private let keyValue = SyntaxLanguage(
    mode: .keyValue, keywords: words("true false null"), types: false, lineComments: hash,
    multiline: [(b("\"\"\""), true), (b("'''"), false)], quotes: [q2], rawQuotes: [q1])
private let css = SyntaxLanguage(mode: .css, types: false, blockComment: cBlock, quotes: [q2, q1], atWords: true)
private let markup = SyntaxLanguage(mode: .markup, types: false, blockComment: (b("<!--"), b("-->")), quotes: [q2, q1])
private let sql = SyntaxLanguage(
    keywords: words("select from where and or not insert into values update set delete create table drop alter index join left right inner outer on as group by order having limit offset null is in like distinct union all primary key foreign references default exists case when then else end begin commit returning with"),
    caseInsensitive: true, types: false, lineComments: [b("--")], blockComment: cBlock, quotes: [], rawQuotes: [q1])
private let markdown = SyntaxLanguage(mode: .markdown, types: false)

private let byExtension: [String: SyntaxLanguage] = {
    var m: [String: SyntaxLanguage] = [:]
    for (lang, exts) in [(swift, "swift"), (js, "js jsx ts tsx mjs cjs mts cts"), (python, "py pyi"), (go, "go"), (rust, "rs"),
                         (kotlin, "kt kts java"), (c, "c h cc cpp cxx hpp hh hxx m mm"), (ruby, "rb rake gemspec"),
                         (shell, "sh bash zsh"), (json, "json jsonc"), (keyValue, "yml yaml toml"), (css, "css scss less"),
                         (markup, "html htm xml svg plist xib storyboard vue"), (sql, "sql"), (markdown, "md markdown")] {
        for e in exts.split(separator: " ") { m[String(e)] = lang }
    }
    return m
}()

/// By file extension; nil — unknown, stays plain.
func syntaxLanguage(forPath path: String) -> SyntaxLanguage? {
    let name = path.split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return byExtension[name[name.index(after: dot)...].lowercased()]
}

/// Longer lines stay plain (minified files): bounded work per rendered row.
let syntaxMaxLineBytes = 2000

/// Colored spans of one line; `state` carries open comments/strings to the next line.
func highlightLine(_ line: String, _ lang: SyntaxLanguage, _ state: inout SyntaxState) -> [SyntaxSpan] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(line.utf8.count)
    bytes.append(contentsOf: line.utf8)
    guard bytes.count <= syntaxMaxLineBytes else { return [] }
    var lexer = Lexer(s: bytes, lang: lang, state: state)
    lexer.run()
    state = lexer.state
    return lexer.spans
}

private struct Lexer {
    let s: [UInt8]
    let lang: SyntaxLanguage
    var state: SyntaxState
    var spans: [SyntaxSpan] = []
    var i = 0

    init(s: [UInt8], lang: SyntaxLanguage, state: SyntaxState) {
        self.s = s; self.lang = lang; self.state = state
    }

    mutating func run() {
        switch lang.mode {
        case .markdown: return markdownLine()
        case .keyValue: keyValueStart()
        default: break
        }
        while i < s.count {
            switch state {
            case .comment(let close):
                let end = find(close, from: i).map { $0 + close.count }
                emit(.comment, i, end ?? s.count)
                if end != nil { state = .normal }
            case .string(let close, let escapes):
                let end = closing(close, from: i, escapes: escapes)
                emit(.string, i, end ?? s.count)
                if end != nil { state = .normal }
            case .tag: tagToken()
            case .normal, .fence: lang.mode == .markup ? markupToken() : codeToken()
            }
        }
    }

    // MARK: code

    mutating func codeToken() {
        let ch = s[i]
        if ch == 32 || ch == 9 { i += 1; return }
        for p in lang.lineComments where has(p, at: i) && (p != [UInt8(ascii: "#")] || i == 0 || isSpace(s[i - 1])) {
            emit(.comment, i, s.count); return
        }
        if let block = lang.blockComment, has(block.open, at: i) {
            state = .comment(close: block.close)
            let from = i
            i += block.open.count
            let end = find(block.close, from: i).map { $0 + block.close.count }
            emit(.comment, from, end ?? s.count)
            if end != nil { state = .normal }
            return
        }
        for m in lang.multiline where has(m.delim, at: i) {
            let from = i
            let end = closing(m.delim, from: i + m.delim.count, escapes: m.escapes)
            emit(.string, from, end ?? s.count)
            if end == nil { state = .string(close: m.delim, escapes: m.escapes) }
            return
        }
        if lang.quotes.contains(ch) || lang.rawQuotes.contains(ch) {
            let end = closing([ch], from: i + 1, escapes: !lang.rawQuotes.contains(ch))
            emit(.string, i, end ?? s.count); return
        }
        if ch == q1, lang.charQuote {
            if let end = charLiteralEnd() { emit(.string, i, end) } else { i += 1 }
            return
        }
        if isDigit(ch), i == 0 || !isWord(s[i - 1]) { return number(from: i) }
        if lang.mode == .css, ch == UInt8(ascii: "#"), i + 1 < s.count, isWord(s[i + 1]) {
            var j = i + 1
            while j < s.count, isWord(s[j]) { j += 1 }
            emit(.number, i, j); return
        }
        if isWordStart(ch) || (lang.atWords && ch == UInt8(ascii: "@") && i + 1 < s.count && isWordStart(s[i + 1])) {
            return word()
        }
        i += 1
    }

    mutating func number(from: Int) {
        var j = from
        while j < s.count, isWord(s[j]) || (s[j] == UInt8(ascii: ".") && j + 1 < s.count && isDigit(s[j + 1])) { j += 1 }
        emit(.number, from, j)
    }

    mutating func word() {
        let from = i
        var j = i + 1
        while j < s.count, isWord(s[j]) || (lang.mode == .css && s[j] == UInt8(ascii: "-")) { j += 1 }
        let w = String(decoding: s[from..<j], as: UTF8.self)
        if lang.mode == .css {
            var k = j
            while k < s.count, isSpace(s[k]) { k += 1 }
            if s[from] == UInt8(ascii: "@") || (k < s.count && s[k] == UInt8(ascii: ":")) { emit(.keyword, from, j) } else { i = j }
        } else if lang.keywords.contains(lang.caseInsensitive ? w.lowercased() : w) {
            emit(.keyword, from, j)
        } else if lang.types, s[from] >= UInt8(ascii: "A"), s[from] <= UInt8(ascii: "Z") {
            emit(.type, from, j)
        } else {
            i = j
        }
    }

    /// `'x'`, `'é'`, `'\n'`, `'\u{1F}'` — else nil.
    func charLiteralEnd() -> Int? {
        var j = i + 1
        guard j < s.count, s[j] != q1 else { return nil }
        if s[j] == bs {
            j += 2
            while j < s.count, j < i + 12 { if s[j] == q1 { return j + 1 }; j += 1 }
            return nil
        }
        j += 1
        while j < s.count, s[j] & 0xC0 == 0x80 { j += 1 }  // the rest of one UTF-8 character
        return j < s.count && s[j] == q1 ? j + 1 : nil
    }

    // MARK: YAML / TOML

    /// A `key:` / `key =` (after `- ` items) or a `[table]` header at the line start.
    mutating func keyValueStart() {
        guard state == .normal else { return }
        while i < s.count, isSpace(s[i]) { i += 1 }
        if i < s.count, s[i] == UInt8(ascii: "[") {
            let end = find([UInt8(ascii: "]")], from: i).map { var e = $0 + 1; while e < s.count, s[e] == UInt8(ascii: "]") { e += 1 }; return e }
            if let end { emit(.type, i, end) }
            return
        }
        while i + 1 < s.count, s[i] == UInt8(ascii: "-"), isSpace(s[i + 1]) {
            i += 2
            while i < s.count, isSpace(s[i]) { i += 1 }
        }
        var k = i
        let stops: Set<UInt8> = [UInt8(ascii: ":"), UInt8(ascii: "="), UInt8(ascii: "#"), q1, q2]
        while k < s.count, !stops.contains(s[k]) { k += 1 }
        guard k < s.count, s[k] != UInt8(ascii: "#"), s[k] != q1, s[k] != q2 else { return }
        if s[k] == UInt8(ascii: ":"), k + 1 < s.count, !isSpace(s[k + 1]) { return }  // `http://…`
        var e = k
        while e > i, isSpace(s[e - 1]) { e -= 1 }
        if e > i { emit(.keyword, i, e) }
    }

    // MARK: HTML / XML

    mutating func markupToken() {
        if let block = lang.blockComment, has(block.open, at: i) {
            let from = i
            i += block.open.count
            let end = find(block.close, from: i).map { $0 + block.close.count }
            emit(.comment, from, end ?? s.count)
            if end == nil { state = .comment(close: block.close) }
            return
        }
        if s[i] == UInt8(ascii: "<") {
            var j = i + 1
            if j < s.count, [UInt8(ascii: "/"), UInt8(ascii: "!"), UInt8(ascii: "?")].contains(s[j]) { j += 1 }
            let nameStart = j
            while j < s.count, isWord(s[j]) || s[j] == UInt8(ascii: "-") || s[j] == UInt8(ascii: ":") || s[j] == UInt8(ascii: ".") { j += 1 }
            if j > nameStart {
                emit(.keyword, i, j)
                state = .tag
                return
            }
        }
        i += 1
    }

    mutating func tagToken() {
        let ch = s[i]
        if isSpace(ch) || ch == UInt8(ascii: "=") { i += 1; return }
        if ch == UInt8(ascii: ">") { state = .normal; emit(.keyword, i, i + 1); return }
        if (ch == UInt8(ascii: "/") || ch == UInt8(ascii: "?")), i + 1 < s.count, s[i + 1] == UInt8(ascii: ">") {
            state = .normal; emit(.keyword, i, i + 2); return
        }
        if lang.quotes.contains(ch) {
            let end = closing([ch], from: i + 1, escapes: false)
            emit(.string, i, end ?? s.count); return
        }
        var j = i
        while j < s.count, !isSpace(s[j]), ![UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/"), q1, q2].contains(s[j]) { j += 1 }
        if j > i { emit(.type, i, j) } else { i += 1 }
    }

    // MARK: Markdown

    mutating func markdownLine() {
        var k = 0
        while k < s.count, isSpace(s[k]) { k += 1 }
        let fence = has(b("```"), at: k) || has(b("~~~"), at: k)
        if state == .fence || fence {
            if !s.isEmpty { emit(.string, 0, s.count) }
            if fence { state = state == .fence ? .normal : .fence }
            return
        }
        if k < 4, k < s.count, s[k] == UInt8(ascii: "#") { return emit(.keyword, 0, s.count) }
        while i < s.count {
            if s[i] == bt, let end = find([bt], from: i + 1) { emit(.string, i, end + 1) } else { i += 1 }
        }
    }

    // MARK: helpers

    /// Adds a span and moves past it; adjacent strings merge (`'it''s'`).
    mutating func emit(_ kind: SyntaxKind, _ from: Int, _ to: Int) {
        if kind == .string, let last = spans.last, last.kind == .string, last.range.upperBound == from {
            spans[spans.count - 1].range = last.range.lowerBound..<to
        } else if to > from {
            spans.append(SyntaxSpan(kind: kind, range: from..<to))
        }
        i = to
    }

    func has(_ p: [UInt8], at j: Int) -> Bool {
        guard !p.isEmpty, j + p.count <= s.count else { return false }
        for k in p.indices where s[j + k] != p[k] { return false }
        return true
    }

    func find(_ p: [UInt8], from: Int) -> Int? {
        var j = from
        while j + p.count <= s.count { if has(p, at: j) { return j }; j += 1 }
        return nil
    }

    /// The end of a string closed by `close` (past it), skipping `\x` when `escapes`.
    func closing(_ close: [UInt8], from: Int, escapes: Bool) -> Int? {
        var j = from
        while j < s.count {
            if escapes, s[j] == bs { j += 2; continue }
            if has(close, at: j) { return j + close.count }
            j += 1
        }
        return nil
    }

    func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 }
    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    func isWordStart(_ c: UInt8) -> Bool { (c | 0x20 >= 97 && c | 0x20 <= 122) || c == 95 || c == 36 || c >= 0x80 }
    func isWord(_ c: UInt8) -> Bool { isWordStart(c) || isDigit(c) }
}

/// Highlights rows of one diff load on demand (only rendered rows), cached until the next load. State runs along each
/// side of a hunk (old: context + deleted, new: context + added) and restarts at every hunk header.
@MainActor final class DiffHighlighter {
    private struct Lexed {
        var spans: [SyntaxSpan]
        var old: SyntaxState
        var new: SyntaxState
    }
    let lang: SyntaxLanguage
    private let rows: [DiffRow]
    private var lexed: [Lexed?]
    private var texts: [Int: AttributedString] = [:]

    init(lang: SyntaxLanguage, rows: [DiffRow]) {
        self.lang = lang
        self.rows = rows
        lexed = Array(repeating: nil, count: rows.count)
    }

    func spans(at index: Int) -> [SyntaxSpan] {
        if let l = lexed[index] { return l.spans }
        // Back to the nearest lexed row or hunk start, then forward.
        var from = index
        while from > 0, lexed[from - 1] == nil, !rows[from].isHunk { from -= 1 }
        var old = SyntaxState.normal, new = SyntaxState.normal
        if from > 0, !rows[from].isHunk, let prev = lexed[from - 1] { (old, new) = (prev.old, prev.new) }
        for k in from...index {
            var spans: [SyntaxSpan] = []
            if case .line(let l) = rows[k] {
                let text = diffDisplayText(l.text)
                switch l.kind {
                case .added: spans = highlightLine(text, lang, &new)
                case .deleted: spans = highlightLine(text, lang, &old)
                case .context:
                    let same = old == new
                    spans = highlightLine(text, lang, &new)
                    if same { old = new } else { _ = highlightLine(text, lang, &old) }
                }
            } else if rows[k].isHunk {
                (old, new) = (.normal, .normal)
            }
            lexed[k] = Lexed(spans: spans, old: old, new: new)
        }
        return lexed[index]?.spans ?? []
    }

    /// The colored display text of line row `index` (plain runs keep the view's color).
    func text(at index: Int, _ display: String) -> AttributedString {
        if let t = texts[index] { return t }
        let bytes = Array(display.utf8)
        var out = AttributedString()
        var at = 0
        for span in spans(at: index) where span.range.upperBound <= bytes.count {
            out += AttributedString(String(decoding: bytes[at..<span.range.lowerBound], as: UTF8.self))
            var run = AttributedString(String(decoding: bytes[span.range], as: UTF8.self))
            run.foregroundColor = Theme.Diff.syntax(span.kind)
            out += run
            at = span.range.upperBound
        }
        out += AttributedString(String(decoding: bytes[at...], as: UTF8.self))
        texts[index] = out
        return out
    }
}

extension DiffRow {
    var isHunk: Bool { if case .hunk = self { true } else { false } }
}
