import Foundation

/// Which line Claude Code shows (`statusline` in config.toml): Hangar's own, or the user's original command (`--then`).
public enum StatuslineMode: String, Sendable, CaseIterable { case hangar, user }

/// A part of Hangar's status line (`statusline_segments`), shown in the config's order (#110).
public enum StatuslineSegment: String, Sendable, CaseIterable {
    case model, context, fiveHour = "5h", week, branch, effort
    public static let defaults: [StatuslineSegment] = [.model, .context, .fiveHour, .week]

    /// Names from config.toml: unknown and repeated ones skipped, the first place wins.
    static func list(_ names: [String]) -> [StatuslineSegment] {
        var out: [StatuslineSegment] = []
        for case let s? in names.map(StatuslineSegment.init(rawValue:)) where !out.contains(s) { out.append(s) }
        return out
    }
}

/// `segment` taken out of `chips` and put before the chip at `index` of the original row (`chips.count` = last);
/// an index past the end changes nothing.
public func statuslineMove(_ chips: [StatuslineSegment], _ segment: StatuslineSegment, to index: Int) -> [StatuslineSegment] {
    guard let from = chips.firstIndex(of: segment), index >= 0, index <= chips.count else { return chips }
    var out = chips
    out.remove(at: from)
    out.insert(segment, at: index > from ? index - 1 : index)
    return out
}

/// The status line fields Hangar shows, from Claude Code's stdin JSON; anything absent or malformed is nil.
public struct StatuslineInput: Equatable, Sendable {
    public var model: String?
    public var contextPercent: Double?
    public var contextSize: Double?
    public var fiveHour: (used: Double?, resetsAt: Double?)
    public var week: (used: Double?, resetsAt: Double?)
    public var effort: String?
    public var fast = false
    public var branch: String?

    public init() { fiveHour = (nil, nil); week = (nil, nil) }

    public init(json: Data) {
        self.init()
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        func number(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        let m = root["model"] as? [String: Any]
        model = shortModelName(display: m?["display_name"] as? String, id: m?["id"] as? String)
        let ctx = root["context_window"] as? [String: Any]
        contextPercent = number(ctx?["used_percentage"])
        contextSize = number(ctx?["context_window_size"])
        let limits = root["rate_limits"] as? [String: Any]
        func window(_ name: String) -> (Double?, Double?) {
            let w = limits?[name] as? [String: Any]
            return (number(w?["used_percentage"]), number(w?["resets_at"]))
        }
        fiveHour = window("five_hour")
        week = window("seven_day")
        effort = ((root["effort"] as? [String: Any])?["level"] as? String).map { clean($0, max: 12) }.flatMap { $0.isEmpty ? nil : $0 }
        fast = root["fast_mode"] as? Bool == true
        let wt = (root["worktree"] as? [String: Any])?["branch"] as? String
        let gw = (root["workspace"] as? [String: Any])?["git_worktree"] as? String
        branch = (wt ?? gw).map { clean($0, max: 32) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.model == b.model && a.contextPercent == b.contextPercent && a.contextSize == b.contextSize
            && a.fiveHour.used == b.fiveHour.used && a.fiveHour.resetsAt == b.fiveHour.resetsAt
            && a.week.used == b.week.used && a.week.resetsAt == b.week.resetsAt
            && a.effort == b.effort && a.fast == b.fast && a.branch == b.branch
    }

    /// The sample of Settings' preview: every default segment present, the 5-hour window near its limit.
    public static func sample(now: Date) -> StatuslineInput {
        var s = StatuslineInput()
        s.model = "Opus 5.5"
        s.contextPercent = 38
        s.contextSize = 200_000
        s.fiveHour = (84, now.timeIntervalSince1970 + 107 * 60)
        s.week = (31, now.timeIntervalSince1970 + 3 * 86_400)
        s.effort = "medium"
        s.branch = "feat/login"
        return s
    }
}

/// Control characters (ESC, newlines) out, at most `max` characters (then «…»): the payload cannot style or break the line.
private func clean(_ s: String, max: Int) -> String {
    let t = String(s.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
        .map(Character.init)).trimmingCharacters(in: .whitespaces)
    return t.count > max ? String(t.prefix(max - 1)) + "…" : t
}

/// «Opus 5.5»: `display_name` without «Claude » and a «(…)» suffix; one without a version takes it from the id
/// (`claude-opus-5-5[1m]` → «Opus 5.5»).
func shortModelName(display: String?, id: String?) -> String? {
    var d = clean(display ?? "", max: 64)
    if d.lowercased().hasPrefix("claude ") { d = String(d.dropFirst(7)) }
    if let paren = d.firstIndex(of: "("), paren > d.startIndex { d = d[..<paren].trimmingCharacters(in: .whitespaces) }
    if !d.contains(where: \.isNumber), let id {
        let parts = (id.lowercased().split(separator: "[").first ?? "").split(separator: "-").map(String.init)
        if let f = parts.firstIndex(where: { $0 != "claude" && $0.allSatisfy(\.isLetter) }) {
            let version = parts[(f + 1)...].prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.prefix(2)
            let family = parts[f].prefix(1).uppercased() + parts[f].dropFirst()
            if !version.isEmpty, d.isEmpty || d.lowercased() == parts[f] { d = family + " " + version.joined(separator: ".") }
        }
    }
    d = clean(d, max: 24)
    return d.isEmpty ? nil : d
}

/// «47m», «1h47m», «2d3h» (English in every language, #110); under a minute counts as one.
public func compactDuration(_ seconds: Double) -> String {
    let minutes = max(1, Int((seconds / 60).rounded(.up)))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 24 * 60 { return "\(minutes / 60)h" + (minutes % 60 > 0 ? "\(minutes % 60)m" : "") }
    let hours = minutes / 60
    return "\(hours / 24)d" + (hours % 24 > 0 ? "\(hours % 24)h" : "")
}

/// ANSI SGR the renderer uses: the terminal's own palette, so the line follows its theme.
enum SGR {
    static let reset = "\u{1B}[0m", dim = "\u{1B}[2m", yellow = "\u{1B}[33m", red = "\u{1B}[31m"
}

/// Same thresholds as Hangar's limits: yellow from 80 %, red from 95 %.
private func levelColor(_ percent: Double) -> String? {
    percent >= 95 ? SGR.red : percent >= 80 ? SGR.yellow : nil
}

private func styled(_ text: String, _ sgr: String?) -> String {
    guard let sgr else { return text }
    return sgr + text + SGR.reset
}

/// `━━━─────`: filled cells in the level colour (default foreground below 80 %), the rest dim.
private func bar(_ percent: Double, cells: Int = 8) -> String {
    let p = min(max(percent, 0), 100)
    let filled = p > 0 ? max(1, Int((p / 100 * Double(cells)).rounded())) : 0
    let color = levelColor(percent)
    return (filled > 0 ? styled(String(repeating: "━", count: filled), color) : "")
        + (filled < cells ? styled(String(repeating: "─", count: cells - filled), SGR.dim) : "")
}

private func percentText(_ percent: Double) -> String {
    styled("\(Int(percent.rounded()))%", levelColor(percent))
}

/// Hangar's status line: one line, segments in the given order, a segment without its data left out (nothing at all
/// → ""). Always English, whatever Hangar's language (#110): it lives in Claude's terminal, often on a server.
/// Labels and separators dim, values neutral, yellow ≥ 80 %, red ≥ 95 %.
public func renderStatusline(_ input: StatuslineInput, segments: [StatuslineSegment], now: Date) -> String {
    func label(_ s: String) -> String { styled(s, SGR.dim) }
    func until(_ resetsAt: Double?) -> String? {
        guard let r = resetsAt, r > now.timeIntervalSince1970 else { return nil }
        return compactDuration(r - now.timeIntervalSince1970)
    }
    func part(_ segment: StatuslineSegment) -> String? {
        switch segment {
        case .model:
            guard let model = input.model else { return nil }
            var markers: [String] = []
            if let size = input.contextSize, size >= 1_000_000 { markers.append("1M") }
            if input.fast { markers.append("fast") }
            // A high level shows even without the effort part; with it, the part says it in its own place.
            if let e = input.effort, !segments.contains(.effort), ["high", "xhigh", "max"].contains(e.lowercased()) { markers.append(e) }
            return ([model] + markers.map(label)).joined(separator: " ")
        case .context:
            return input.contextPercent.map { "\(label("ctx")) \(bar($0)) \(percentText($0))" }
        case .fiveHour:
            guard let p = input.fiveHour.used else { return nil }
            let reset = until(input.fiveHour.resetsAt).map { " " + label($0) } ?? ""
            return "\(label("5h")) \(bar(p)) \(percentText(p))\(reset)"
        case .week:
            guard let p = input.week.used else { return nil }
            let reset = p >= 80 ? until(input.week.resetsAt).map { " " + label($0) } ?? "" : ""
            return "\(label("wk")) \(percentText(p))\(reset)"
        case .branch:
            return input.branch.map { "\(label("⎇")) \($0)" }
        case .effort:
            return input.effort.map { "\(label("effort")) \($0)" }
        }
    }
    return segments.compactMap(part).joined(separator: label(" │ "))
}

/// A run of the rendered line with its style, for Settings' preview (the same SGR codes the renderer writes).
public struct AnsiSpan: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case normal, dim, yellow, red }
    public var text: String
    public var tone: Tone
    public init(_ text: String, _ tone: Tone) { self.text = text; self.tone = tone }
}

/// Splits ANSI text into styled runs; unknown or malformed sequences are dropped, never shown.
public func ansiSpans(_ line: String) -> [AnsiSpan] {
    var spans: [AnsiSpan] = []
    var tone = AnsiSpan.Tone.normal
    var text = ""
    var rest = Substring(line)
    func flush() {
        if !text.isEmpty { spans.append(AnsiSpan(text, tone)) }
        text = ""
    }
    while let c = rest.first {
        rest = rest.dropFirst()
        guard c == "\u{1B}" else { text.append(c); continue }
        guard rest.first == "[" else { continue }
        rest = rest.dropFirst()
        let params = rest.prefix { $0.isNumber || $0 == ";" }
        rest = rest.dropFirst(params.count)
        guard let final = rest.first else { break }
        rest = rest.dropFirst()
        guard final == "m" else { continue }
        flush()
        for p in params.split(separator: ";", omittingEmptySubsequences: false) {
            switch p {
            case "", "0": tone = .normal
            case "2": tone = .dim
            case "33": tone = .yellow
            case "31": tone = .red
            default: break
            }
        }
    }
    flush()
    return spans
}

public extension Language {
    /// `system` → ru when the first preferred language is Russian, else en.
    func resolved(preferred: [String] = Locale.preferredLanguages) -> Language {
        guard self == .system else { return self }
        return preferred.first.map { Locale(identifier: $0).language.languageCode?.identifier == "ru" } == true ? .ru : .en
    }
}
