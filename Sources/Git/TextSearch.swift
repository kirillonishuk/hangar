import Foundation

/// Find in files (decision #91): the query and toggles of the inspector's Search tab.
public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var caseSensitive = false
    public var regex = false
    public var wholeWord = false
    /// Globs as typed (gitignore style: no `/` = any depth); empty = every file.
    public var include: [String] = []
    public var exclude: [String] = []

    public init(text: String, caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false,
                include: [String] = [], exclude: [String] = []) {
        self.text = text; self.caseSensitive = caseSensitive; self.regex = regex; self.wholeWord = wholeWord
        self.include = include; self.exclude = exclude
    }
}

public enum SearchEngine: Equatable, Sendable { case ripgrep, gitGrep }

/// Caps: memory and the list stay bounded whatever the repository holds.
public enum SearchLimits {
    /// Lines shown in all; past it the search stops («more results not shown»).
    public static let total = 2000
    /// Lines shown per file.
    public static let perFile = 200
    /// Characters of a line kept (the rest is cut with «…»), and how many stay before the first match.
    public static let preview = 240
    public static let lead = 40
    /// Highlighted matches per line.
    public static let rangesPerLine = 50
    /// An output line longer than this (bytes) is skipped unread: buffering stays bounded on minified files.
    public static let maxLineBytes = 1 << 20
    /// rg cuts lines wider than this to a preview (`--max-columns`).
    public static let maxColumns = 2000
    /// UTF-16 units of a git grep line searched again for highlighting (ICU on a bounded prefix).
    public static let highlightPrefix = 4096
}

/// A comma-separated glob field (`*.swift, src/**`) as globs; commas inside `{…}` stay.
public func searchGlobs(_ field: String) -> [String] {
    var out: [String] = [], cur = "", depth = 0
    for ch in field {
        switch ch {
        case "{": depth += 1; cur.append(ch)
        case "}": depth = max(0, depth - 1); cur.append(ch)
        case "," where depth == 0: out.append(cur); cur = ""
        default: cur.append(ch)
        }
    }
    out.append(cur)
    return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// `rg` argv (after the executable): JSON events, gitignore respected (also outside a repository, as git grep
/// `--no-index --exclude-standard` does), dotfiles searched (not `.git`), very long lines cut to a preview. The query is
/// the value of `-e` and globs are `--glob=…`, so nothing the user types can become an option.
public func ripgrepArgs(_ q: SearchQuery, perFile: Int = SearchLimits.perFile) -> [String] {
    var a = ["--json", "--no-config", "--hidden", "--no-require-git", "--max-columns", String(SearchLimits.maxColumns),
             "--max-columns-preview", q.caseSensitive ? "--case-sensitive" : "--ignore-case"]
    if !q.regex { a.append("--fixed-strings") }
    if q.wholeWord { a.append("--word-regexp") }
    // One line past the cap marks the file as truncated.
    a += ["--max-count", String(perFile + 1), "--glob=!.git"]
    a += q.include.map { "--glob=" + $0 } + q.exclude.map { "--glob=!" + $0 }
    return a + ["-e", q.text, "--", "."]
}

/// `git grep` argv (with `git`): tracked and untracked-not-ignored files of a repository, or a plain folder
/// (`noIndex`, its `.gitignore` respected). `-z` output, so paths with `:` parse. Older git has no `--column` (`column: false`).
public func gitGrepArgs(_ q: SearchQuery, noIndex: Bool, column: Bool = true) -> [String] {
    // The user's config must not change the output: quoted paths, paths from the top level, colours.
    var a = ["git", "-c", "core.quotePath=false", "-c", "grep.fullName=false", "grep", "--no-color", "-n", "-z", "-I"]
    if column { a.append("--column") }
    a += noIndex ? ["--no-index", "--exclude-standard"] : ["--untracked"]
    if !q.caseSensitive { a.append("-i") }
    a.append(q.regex ? "-E" : "-F")
    if q.wholeWord { a.append("-w") }
    a += ["-e", q.text, "--"]
    return a + q.include.flatMap { gitPathspecs($0, exclude: false) } + q.exclude.flatMap { gitPathspecs($0, exclude: true) }
}

/// A glob as rg reads it (no `/` = at any depth, leading `/` = from the root, a directory = everything in it) as
/// git pathspecs: the glob itself and its contents.
func gitPathspecs(_ glob: String, exclude: Bool) -> [String] {
    var p = Substring(glob)
    if p.hasPrefix("./") { p = p.dropFirst(2) }
    let anchored = p.hasPrefix("/")
    if anchored { p = p.dropFirst() }
    while p.hasSuffix("/") { p = p.dropLast() }
    guard !p.isEmpty else { return [] }
    let base = anchored || p.contains("/") ? String(p) : "**/" + p
    let magic = exclude ? ":(exclude,glob)" : ":(glob)"
    return [magic + base, magic + base + "/**"]
}

/// One line with matches. Columns and ranges are UTF-16 (Monaco's columns), not bytes.
public struct SearchHit: Equatable, Sendable {
    /// 1-based.
    public var line: Int
    /// 1-based column of the first match in the whole line.
    public var column: Int
    /// The line around the first match, at most `SearchLimits.preview` long, «…» where cut; leading indent dropped.
    public var preview: String
    /// Matches inside `preview`.
    public var ranges: [Range<Int>]

    public init(line: Int, column: Int, preview: String, ranges: [Range<Int>]) {
        self.line = line; self.column = column; self.preview = preview; self.ranges = ranges
    }
}

public struct SearchFile: Equatable, Sendable, Identifiable {
    /// Relative to the search root.
    public var path: String
    public var hits: [SearchHit]
    /// More lines matched than `SearchLimits.perFile`.
    public var truncated = false
    public var id: String { path }

    public init(path: String, hits: [SearchHit], truncated: Bool = false) {
        self.path = path; self.hits = hits; self.truncated = truncated
    }
}

public struct SearchResults: Equatable, Sendable {
    public var files: [SearchFile] = []
    /// Lines shown.
    public var lines = 0
    /// Matches in the lines shown.
    public var matches = 0
    /// The total cap was hit: the search stopped, more results are not shown.
    public var truncated = false

    public init() {}
}

/// Streaming parser of `rg --json` or `git grep -z` output: chunks may split lines anywhere. Not thread-safe; one reader.
public struct SearchParser {
    public let engine: SearchEngine
    public private(set) var results = SearchResults()
    private let query: SearchQuery
    private let gitColumn: Bool
    private let total: Int, perFile: Int
    private var buffer: [UInt8] = []
    /// Inside an over-long line: bytes are dropped up to its newline.
    private var skipping = false
    private var index: [String: Int] = [:]
    /// git grep reports one column; the line's matches are found here again (same toggles).
    private lazy var matcher: NSRegularExpression? = searchRegex(query)

    public init(engine: SearchEngine, query: SearchQuery, gitColumn: Bool = true,
                total: Int = SearchLimits.total, perFile: Int = SearchLimits.perFile) {
        self.engine = engine; self.query = query; self.gitColumn = gitColumn; self.total = total; self.perFile = perFile
    }

    /// Feeds output; false once the total cap is hit (stop the process).
    public mutating func feed(_ data: Data) -> Bool {
        guard !results.truncated else { return false }
        var chunk = data[...]
        if skipping {
            guard let nl = chunk.firstIndex(of: 0x0A) else { return true }
            skipping = false
            chunk = chunk[(nl + 1)...]
        }
        // Only the new bytes are scanned for newlines: the kept tail has none.
        var scan = buffer.count
        buffer.append(contentsOf: chunk)
        var start = 0
        while !results.truncated, let nl = buffer[scan...].firstIndex(of: 0x0A) {
            parse(buffer[start..<nl])
            start = nl + 1
            scan = start
        }
        if results.truncated { buffer = []; return false }
        buffer.removeFirst(start)
        if buffer.count > SearchLimits.maxLineBytes { buffer = []; skipping = true }
        return true
    }

    /// End of output: a last line without a newline.
    public mutating func finish() {
        if !buffer.isEmpty, !results.truncated, !skipping { parse(buffer[...]) }
        buffer = []
        skipping = false
    }

    private mutating func parse(_ line: ArraySlice<UInt8>) {
        switch engine {
        case .ripgrep: parseRipgrep(line)
        case .gitGrep: parseGitGrep(line)
        }
    }

    private struct RgEvent: Decodable {
        struct Text: Decodable { var text: String?; var bytes: String? }
        struct Sub: Decodable { var start: Int; var end: Int }
        struct Payload: Decodable {
            var path: Text?
            var lines: Text?
            var line_number: Int?
            var submatches: [Sub]?
        }
        var type: String
        var data: Payload?
    }

    private mutating func parseRipgrep(_ line: ArraySlice<UInt8>) {
        // begin / end / context / summary carry nothing to show.
        guard line.starts(with: Array(#"{"type":"match""#.utf8)),
              let event = try? JSONDecoder().decode(RgEvent.self, from: Data(line)), let d = event.data,
              var path = d.path?.text, let number = d.line_number, let lines = d.lines else { return }
        // Text that isn't UTF-8 comes base64 in `bytes` (offsets are into those bytes); a non-UTF-8 path can't be opened.
        let bytes: [UInt8]
        if let text = lines.text { bytes = Array(text.utf8) } else if let b = lines.bytes.flatMap({ Data(base64Encoded: $0) }) { bytes = Array(b) } else { return }
        if path.hasPrefix("./") { path.removeFirst(2) }
        let subs = (d.submatches ?? []).prefix(SearchLimits.rangesPerLine).filter { $0.start >= 0 && $0.end >= $0.start }
        let offsets = utf16Offsets(of: subs.flatMap { [$0.start, $0.end] }, in: bytes)
        let ranges = stride(from: 0, to: offsets.count, by: 2).map { offsets[$0]..<offsets[$0 + 1] }.filter { !$0.isEmpty }
        add(path: path, line: number, text: decodeLine(bytes), ranges: ranges, column: nil)
    }

    private mutating func parseGitGrep(_ line: ArraySlice<UInt8>) {
        // path NUL line NUL [column NUL] text
        var fields: [ArraySlice<UInt8>] = []
        var rest = line
        for _ in 0..<(gitColumn ? 3 : 2) {
            guard let z = rest.firstIndex(of: 0) else { return }
            fields.append(rest[..<z])
            rest = rest[(z + 1)...]
        }
        guard let path = String(bytes: fields[0], encoding: .utf8), !path.isEmpty,
              let number = Int(String(decoding: fields[1], as: UTF8.self)) else { return }
        let bytes = Array(rest)
        var column: Int?
        if gitColumn, let c = Int(String(decoding: fields[2], as: UTF8.self)), c >= 1 {
            column = (utf16Offsets(of: [c - 1], in: bytes).first ?? 0) + 1
        }
        let text = decodeLine(bytes)
        let ranges = matcher.map { searchRanges(in: text, $0, limit: SearchLimits.highlightPrefix) } ?? []
        add(path: path, line: number, text: text, ranges: ranges, column: column)
    }

    private mutating func add(path: String, line: Int, text: String, ranges: [Range<Int>], column: Int?) {
        guard !results.truncated else { return }
        if let known = index[path], results.files[known].hits.count >= perFile { results.files[known].truncated = true; return }
        // The total cap first: no empty group for a file whose first line is past it.
        guard results.lines < total else { results.truncated = true; return }
        let i: Int
        if let known = index[path] {
            i = known
        } else {
            i = results.files.count
            index[path] = i
            results.files.append(SearchFile(path: path, hits: []))
        }
        let (preview, shown) = searchPreview(text, ranges)
        let col = ranges.first.map { $0.lowerBound + 1 } ?? column ?? 1
        results.files[i].hits.append(SearchHit(line: line, column: col, preview: preview, ranges: shown))
        results.lines += 1
        results.matches += max(1, ranges.count)
    }
}

/// The line without its newline (`\n`, `\r\n`); invalid UTF-8 becomes U+FFFD, as the editor shows it.
private func decodeLine(_ bytes: [UInt8]) -> String {
    var end = bytes.count
    if end > 0, bytes[end - 1] == 0x0A { end -= 1 }
    if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
    return String(decoding: bytes[..<end], as: UTF8.self)
}

/// UTF-16 offsets of byte offsets into UTF-8 `bytes`, in one pass (offsets in any order; past the end = the end).
func utf16Offsets(of byteOffsets: [Int], in bytes: [UInt8]) -> [Int] {
    guard !byteOffsets.isEmpty else { return [] }
    let order = byteOffsets.indices.sorted { byteOffsets[$0] < byteOffsets[$1] }
    var out = [Int](repeating: 0, count: byteOffsets.count)
    var units = 0, b = 0
    for i in order {
        let target = min(max(byteOffsets[i], 0), bytes.count)
        while b < target {
            let byte = bytes[b]
            // Continuation bytes add nothing; a 4-byte sequence is a surrogate pair; an invalid byte is one U+FFFD.
            if byte & 0xC0 != 0x80 { units += (0xF0...0xF4).contains(byte) ? 2 : 1 }
            b += 1
        }
        out[i] = units
    }
    return out
}

/// The regex the query means (git grep's toggles), for highlighting; nil if ICU can't read it (no highlight then).
func searchRegex(_ q: SearchQuery) -> NSRegularExpression? {
    var pattern = q.regex ? q.text : NSRegularExpression.escapedPattern(for: q.text)
    if q.wholeWord { pattern = #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"# }
    return try? NSRegularExpression(pattern: pattern, options: q.caseSensitive ? [] : [.caseInsensitive])
}

/// UTF-16 ranges of the non-empty matches in the first `limit` units of `text`, at most `SearchLimits.rangesPerLine`.
func searchRanges(in text: String, _ regex: NSRegularExpression, limit: Int = .max) -> [Range<Int>] {
    var out: [Range<Int>] = []
    let ns = text as NSString
    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: min(ns.length, limit))) { m, _, stop in
        guard let r = m?.range, r.length > 0 else { return }
        out.append(r.location..<(r.location + r.length))
        if out.count >= SearchLimits.rangesPerLine { stop.pointee = true }
    }
    return out
}

/// The shown part of a line: indent dropped, cut to keep the first match in view; ranges moved along (UTF-16).
func searchPreview(_ text: String, _ ranges: [Range<Int>], max: Int = SearchLimits.preview,
                   lead: Int = SearchLimits.lead) -> (String, [Range<Int>]) {
    let u = Array(text.utf16)
    let first = ranges.first?.lowerBound ?? u.count
    var start = 0
    while start < first, start < u.count, u[start] == 0x20 || u[start] == 0x09 { start += 1 }
    let cutHead = first - start > lead
    if cutHead { start = first - lead }
    // Never split a surrogate pair.
    if start > 0, start < u.count, UTF16.isTrailSurrogate(u[start]) { start += 1 }
    var end = min(u.count, start + max)
    if end < u.count, end > start, UTF16.isTrailSurrogate(u[end]) { end -= 1 }
    let head = cutHead ? "…" : "", tail = end < u.count ? "…" : ""
    let shift = head.utf16.count - start
    let shown = ranges.compactMap { r -> Range<Int>? in
        let lo = Swift.max(r.lowerBound, start), hi = Swift.min(r.upperBound, end)
        return lo < hi ? (lo + shift)..<(hi + shift) : nil
    }
    return (head + String(decoding: u[start..<end], as: UTF16.self) + tail, shown)
}
