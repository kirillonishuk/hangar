import Foundation

/// `MAJOR.MINOR.PATCH` of a tag or `CFBundleShortVersionString` (a leading `v` and a `-…`/`+…` suffix are ignored).
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let core = s.prefix { $0 != "-" && $0 != "+" }
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var parts: [Int] = []
        for f in fields {
            guard !f.isEmpty, f.allSatisfy(\.isASCII), let n = Int(f), n >= 0 else { return nil }
            parts.append(n)
        }
        self.parts = parts + Array(repeating: 0, count: 3 - parts.count)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: SemVer, b: SemVer) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// A release newer than ours, as found in the feed (GitHub `releases/latest`).
public struct UpdateOffer: Codable, Equatable, Sendable {
    /// `0.3.0` (the tag without `v`).
    public var version: String
    /// The release body, trimmed for the sheet.
    public var notes: String
    public var dmg: URL
    public var checksum: URL
    public var page: URL?

    public init(version: String, notes: String, dmg: URL, checksum: URL, page: URL? = nil) {
        self.version = version
        self.notes = notes
        self.dmg = dmg
        self.checksum = checksum
        self.page = page
    }
}

/// The feed: `releases/latest` of the GitHub API (only the fields used).
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let body: String?
    let draft: Bool?
    let prerelease: Bool?
    let html_url: URL?
    let assets: [Asset]
}

public enum ReleaseFeed {
    public static let github = URL(string: "https://api.github.com/repos/kirillonishuk/hangar/releases/latest")!
    /// Release notes longer than this are cut (the sheet links the release page).
    static let notesLimit = 4000

    /// Hosts a release may point at: the API feed, the release page and the asset downloads (and their redirects).
    public static let trustedHosts: Set<String> = [
        "api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    /// https on an allow-listed host; everything else is refused at parse time and on redirects.
    public static func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && trustedHosts.contains(url.host?.lowercased() ?? "")
    }

    /// `vX.Y.Z` / `X.Y.Z` only (no suffixes, no padding): the canonical `X.Y.Z`, else nil.
    public static func releaseVersion(_ tag: String) -> String? {
        guard tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return SemVer(tag)?.description
    }

    /// The release of `data` when it is a published, non-pre-release `vX.Y.Z` with `Hangar-X.Y.Z.dmg` and its
    /// `.sha256` on `trusted` URLs; nil otherwise. Throws on JSON that isn't a release.
    public static func parse(_ data: Data, trusted: (URL) -> Bool = isTrusted) throws -> UpdateOffer? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard release.draft != true, release.prerelease != true, let version = releaseVersion(release.tag_name) else { return nil }
        func asset(_ name: String) -> URL? {
            release.assets.first { $0.name == name }?.browser_download_url
        }
        guard let dmg = asset("Hangar-\(version).dmg"), let sum = asset("Hangar-\(version).dmg.sha256"),
              trusted(dmg), trusted(sum) else { return nil }
        let page = release.html_url.flatMap { trusted($0) ? $0 : nil }
        return UpdateOffer(version: version, notes: trimNotes(release.body ?? ""), dmg: dmg, checksum: sum, page: page)
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
    }

    /// The notes as lines for the sheet: headings without `#`, `*`/`-` bullets as `•`, runs of blank lines as one.
    public static func noteLines(_ notes: String) -> [(text: String, heading: Bool)] {
        var out: [(text: String, heading: Bool)] = []
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = out.last, !last.text.isEmpty { out.append(("", false)) }
            } else if let level = headingLevel(Substring(line)) {
                out.append((String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), true))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                out.append(("• " + line.dropFirst(2), false))
            } else {
                out.append((line, false))
            }
        }
        while out.last?.text.isEmpty == true { out.removeLast() }
        return out
    }

    /// Whether `offer` is newer than the running `current` version (an unparsable current never updates).
    public static func isNewer(_ version: String, than current: String) -> Bool {
        guard let new = SemVer(version), let old = SemVer(current) else { return false }
        return new > old
    }

    /// Whitespace-trimmed, CRLF → LF, without the workflow's «Install» section (manual DMG steps), cut at
    /// `notesLimit` on a line break.
    static func trimNotes(_ body: String) -> String {
        var skipping = false, skipLevel = 0
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            if let level = headingLevel(line) {
                // Skipped until a heading of the same or a higher level.
                if skipping, level <= skipLevel { skipping = false }
                if !skipping, line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased() == "install" {
                    skipping = true
                    skipLevel = level
                }
            }
            return !skipping
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > notesLimit else { return text }
        let cut = text.prefix(notesLimit)
        let line = cut.lastIndex(of: "\n").map { cut[..<$0] } ?? cut
        return line.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }
}

/// What the updater remembers between launches (`update.json` in the state dir).
public struct UpdateRecord: Codable, Equatable, Sendable {
    public var lastCheck: Date?
    /// «Пропустить версию»: no pill for it (a manual check still shows it).
    public var skipped: String?
    /// The last offer found, so the pill survives a relaunch between checks.
    public var offer: UpdateOffer?

    public init(lastCheck: Date? = nil, skipped: String? = nil, offer: UpdateOffer? = nil) {
        self.lastCheck = lastCheck
        self.skipped = skipped
        self.offer = offer
    }

    public static let interval: TimeInterval = 24 * 60 * 60

    /// A check is due when none was made or the last is ≥ 24 h old (or in the future: the clock moved back).
    public func checkDue(now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= Self.interval || lastCheck > now
    }

    public static func load(from url: URL) -> UpdateRecord {
        guard let data = try? Data(contentsOf: url) else { return UpdateRecord() }
        return (try? decoder.decode(UpdateRecord.self, from: data)) ?? UpdateRecord()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
