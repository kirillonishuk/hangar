import Foundation
import Exec

// MARK: Models

/// `branch` nil = detached; `hash` nil = no commits yet (unborn branch).
public struct GitHead: Equatable, Sendable {
    public var branch: String?
    public var hash: String?

    public init(branch: String?, hash: String?) { self.branch = branch; self.hash = hash }
}

public struct BranchInfo: Equatable, Sendable {
    /// "main" for local branches, "origin/main" for remote ones.
    public var name: String
    public var isRemote: Bool
    public var hash: String
    /// Checked out here.
    public var isHead: Bool
    /// Short name ("origin/main"); local branches only.
    public var upstream: String?
    /// The upstream no longer exists (deleted on the remote and pruned).
    public var upstreamGone: Bool
    public var ahead: Int
    public var behind: Int
    public var lastCommit: Date
}

public struct BranchList: Equatable, Sendable {
    public var head: GitHead
    /// Each sorted by ref name; symbolic refs (origin/HEAD) are skipped.
    public var local: [BranchInfo]
    public var remote: [BranchInfo]
}

public struct CommitRef: Equatable, Sendable {
    public enum Kind: Sendable { case head, branch, remote, tag }
    public var kind: Kind
    public var name: String
    /// `HEAD -> main` on the branch, or the bare `HEAD` of a detached head.
    public var isHead: Bool

    public init(kind: Kind, name: String, isHead: Bool = false) { self.kind = kind; self.name = name; self.isHead = isHead }
}

public struct Commit: Equatable, Sendable, Identifiable {
    public var hash: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var subject: String
    public var refs: [CommitRef]
    public var id: String { hash }

    public init(hash: String, parents: [String] = [], authorName: String = "", authorEmail: String = "",
                date: Date = Date(timeIntervalSince1970: 0), subject: String = "", refs: [CommitRef] = []) {
        self.hash = hash; self.parents = parents; self.authorName = authorName; self.authorEmail = authorEmail
        self.date = date; self.subject = subject; self.refs = refs
    }
}

public struct LogPage: Equatable, Sendable {
    public var commits: [Commit]
    /// More commits after this page (ask for `skip: skip + limit`).
    public var hasMore: Bool
}

/// User input: every string is cleaned (control characters stripped, trimmed); blank = no filter.
public struct LogFilters: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        /// Branches, remote branches, tags and HEAD.
        case all
        case head
        /// A branch, tag or revision; never starting with `-`.
        case ref(String)
    }
    public var ref: Scope
    /// Case-insensitive fixed string in "Name <email>".
    public var author: String?
    public var since: Date?
    public var until: Date?
    /// Literal pathspec relative to the repo folder (a file or a directory).
    public var path: String?
    /// Case-insensitive fixed string in the message, or a hash prefix (4+ hex digits).
    public var text: String?

    public init(ref: Scope = .all, author: String? = nil, since: Date? = nil, until: Date? = nil,
                path: String? = nil, text: String? = nil) {
        self.ref = ref; self.author = author; self.since = since; self.until = until; self.path = path; self.text = text
    }
}

public struct CommitDetails: Equatable, Sendable {
    public var commit: Commit
    /// Full message (subject + body), trailing whitespace trimmed.
    public var message: String
    /// Against the first parent (the empty tree for a root commit). `added`/`deleted` nil = binary.
    public var files: [ChangedFile]
    public var truncated: Bool
}

public struct DiffStat: Equatable, Sendable {
    public var files: Int
    public var added: Int
    public var deleted: Int

    public init(files: Int, added: Int, deleted: Int) { self.files = files; self.added = added; self.deleted = deleted }
}

// MARK: Commands

/// Read-only history for the Git panel. Runs on ssh hosts too: user strings are validated here, and the ssh runner's
/// `maxOutput` caps what a server can send (a cut stream kills git, which surfaces as a GitError).
extension Git {
    public static let defaultLogLimit = 200
    static let maxFilterLength = 256

    public func branches() async throws -> BranchList {
        let branch = try await historyProbe(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let hash = try await headHash()
        let out = try await history([
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(symref)%00%(HEAD)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)",
            "refs/heads", "refs/remotes",
        ])
        var local: [BranchInfo] = [], remote: [BranchInfo] = []
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 7, p[2].isEmpty else { continue }
            var info = BranchInfo(name: "", isRemote: false, hash: p[1], isHead: p[3] == "*",
                                  upstream: p[4].isEmpty ? nil : p[4], upstreamGone: p[5] == "gone", ahead: 0, behind: 0,
                                  lastCommit: Date(timeIntervalSince1970: TimeInterval(p[6]) ?? 0))
            for part in p[5].split(separator: ",") {
                let w = part.split(separator: " ")
                guard w.count == 2, let n = Int(w[1]) else { continue }
                if w[0] == "ahead" { info.ahead = n } else if w[0] == "behind" { info.behind = n }
            }
            if p[0].hasPrefix("refs/heads/") {
                info.name = String(p[0].dropFirst("refs/heads/".count))
                local.append(info)
            } else if p[0].hasPrefix("refs/remotes/") {
                info.name = String(p[0].dropFirst("refs/remotes/".count))
                info.isRemote = true; info.isHead = false; info.upstream = nil
                remote.append(info)
            }
        }
        return BranchList(head: GitHead(branch: branch, hash: hash), local: local, remote: remote)
    }

    /// One page of history, newest first in topological order (children before parents: ready for `layoutGraph`).
    /// A hash-prefix `text` also finds that commit (first on the first page) whatever its message.
    public func log(limit: Int = Git.defaultLogLimit, skip: Int = 0, filters: LogFilters = LogFilters()) async throws -> LogPage {
        guard (1...10_000).contains(limit), skip >= 0 else { throw invalid("limit/skip") }
        var revs: [String]
        let hasHead = try await headHash() != nil
        switch filters.ref {
        case .all:
            // No refs at all: `log` would fall back to the unborn HEAD and fail.
            if !hasHead, try await history(["for-each-ref", "--count=1", "refs/heads", "refs/remotes", "refs/tags"]).isEmpty {
                return LogPage(commits: [], hasMore: false)
            }
            revs = ["--branches", "--remotes", "--tags"] + (hasHead ? ["HEAD"] : [])
        case .head:
            guard hasHead else { return LogPage(commits: [], hasMore: false) }
            revs = ["HEAD"]
        case .ref(let r):
            guard let r = try clean(r) else { throw invalid("ref") }
            guard !r.hasPrefix("-") else { throw invalid("ref") }
            revs = [r]
        }
        var opts = ["-i", "-F"]
        if let a = try clean(filters.author) { opts.append("--author=" + a) }
        let text = try clean(filters.text)
        if let text { opts.append("--grep=" + text) }
        if let s = filters.since { opts.append("--since=" + gitDate(s)) }
        if let u = filters.until { opts.append("--until=" + gitDate(u)) }
        let paths = try clean(filters.path).map { [":(literal)" + $0] } ?? []

        let args = ["log", "--no-color", "--decorate=full", "--topo-order", "-z", "--format=" + Self.commitFormat,
                    "--skip=\(skip)", "-n", "\(limit + 1)"] + opts + revs + ["--"] + paths
        var commits = try parseCommits(try await history(args))
        let hasMore = commits.count > limit
        if hasMore { commits.removeLast(commits.count - limit) }
        if let text, let hit = try await commitByHash(text) {
            commits.removeAll { $0.hash == hit.hash }
            if skip == 0 { commits.insert(hit, at: 0) }
        }
        return LogPage(commits: commits, hasMore: hasMore)
    }

    /// Full message and changed files of a commit given by (abbreviated) hash.
    public func commit(hash: String, fileLimit: Int = 5_000) async throws -> CommitDetails {
        guard let h = try clean(hash), isHexPrefix(h) else { throw invalid("hash") }
        let rev = h.lowercased() + "^{commit}"
        let meta = try await history(["show", "-s", "--no-color", "--decorate=full", "-z", "--format=" + Self.commitFormat + "%x00%B%x00%x1e", rev, "--"])
        let f = meta.split(separator: "\0", omittingEmptySubsequences: false)
        guard f.count >= 10, f[9] == "\u{1e}", let commit = parseCommit(f[0..<8]) else { throw invalid("output") }
        let message = String(f[8]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        // First-parent diff: what a merge brought in; `-m` makes older git diff merges at all.
        let diff = ["show", "--no-color", "--no-ext-diff", "--no-textconv", "--format=", "-z", "-m", "--first-parent", "--find-renames"]
        let names = parseNameStatus(try await history(diff + ["--name-status", rev, "--"]))
        let stats = parseNumstat(try await history(diff + ["--numstat", rev, "--"]))
        var byPath: [String: NumstatEntry] = [:]
        for s in stats { byPath[s.path] = s }
        var files = names.map { f -> ChangedFile in
            var f = f
            if let s = byPath[f.path] { f.added = s.added; f.deleted = s.deleted }
            return f
        }
        let truncated = files.count > fileLimit
        if truncated { files.removeLast(files.count - fileLimit) }
        return CommitDetails(commit: commit, message: message, files: files, truncated: truncated)
    }

    /// Total +N −M of the folder against `base` as the inspector's Changes count it: merge-base of HEAD and `base`
    /// against the working tree (uncommitted included, untracked not counted). A missing base falls back to HEAD.
    public func diffStat(base: String) async throws -> DiffStat {
        let common = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "--find-renames", "--relative"]
        var out: String?
        if let b = try? clean(base), !b.hasPrefix("-") {
            out = try? await history(common + ["--merge-base", b, "--", "."])
        }
        if out == nil {
            let from = await hasCommits()
                ? "HEAD"
                : try await history(["hash-object", "-t", "tree", "/dev/null"]).trimmingCharacters(in: .whitespacesAndNewlines)
            out = try await history(common + [from, "--", "."])
        }
        let entries = parseNumstat(out ?? "")
        return DiffStat(files: entries.count, added: entries.reduce(0) { $0 + ($1.added ?? 0) },
                        deleted: entries.reduce(0) { $0 + ($1.deleted ?? 0) })
    }

    // MARK: Helpers

    /// hash, parents, author name, email, unix date, decorations, subject, then a 0x1e end mark: a cut stream shows.
    static let commitFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s%x00%x1e"

    private func commitByHash(_ text: String) async throws -> Commit? {
        guard isHexPrefix(text) else { return nil }
        let r = try await runner.run(["git", "--no-optional-locks", "log", "--no-color", "--decorate=full", "--no-walk", "-z",
                                      "--format=" + Self.commitFormat, text.lowercased() + "^{commit}", "--"], repo)
        guard r.status == 0 else { return nil }   // not an object or ambiguous: just no hash match
        return (try? parseCommits(r.stdout))?.first
    }

    /// Control characters stripped, trimmed; nil when blank; too long throws.
    private func clean(_ s: String?) throws -> String? {
        guard let s else { return nil }
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard kept.count <= Self.maxFilterLength else { throw invalid("filter too long") }
        return kept.isEmpty ? nil : kept
    }

    private func isHexPrefix(_ s: String) -> Bool {
        (4...64).contains(s.count) && s.allSatisfy(\.isHexDigit)
    }

    /// `@<unix> +0000`: git's own raw date form, no locale or approxidate guessing.
    private func gitDate(_ d: Date) -> String { "@\(Int(d.timeIntervalSince1970)) +0000" }

    private func invalid(_ what: String) -> GitError { GitError(args: [], status: 128, stderr: "invalid \(what)") }

    private func history(_ args: [String]) async throws -> String {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, repo)
        guard r.status == 0 else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }

    /// Exit 1 is the answer "no"; anything else (ssh's 255, a cut stream) is a failure, not an empty repository.
    private func historyProbe(_ args: [String]) async throws -> String? {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, repo)
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0 || r.status == 1 else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    /// nil = no commits yet.
    private func headHash() async throws -> String? {
        try await historyProbe(["rev-parse", "--verify", "--quiet", "HEAD"])
    }
}

// MARK: Parsing

/// `log -z --format=commitFormat`: NUL between fields and after each commit, 8 fields per commit. Throws when the
/// stream was cut (`maxOutput`; git may still exit 0): a short page must not pass for the end of history.
func parseCommits(_ out: String) throws -> [Commit] {
    if out.isEmpty { return [] }
    guard out.hasSuffix("\u{1e}\0") else { throw GitError(args: ["log"], status: 0, stderr: "unexpected or cut git output") }
    let f = out.dropLast().split(separator: "\0", omittingEmptySubsequences: false)
    var res: [Commit] = []
    var i = 0
    while i < f.count {
        guard i + 8 <= f.count, f[i + 7] == "\u{1e}", let c = parseCommit(f[i..<(i + 8)]) else {
            throw GitError(args: ["log"], status: 0, stderr: "unexpected or cut git output")
        }
        res.append(c)
        i += 8
    }
    return res
}

func parseCommit(_ p: ArraySlice<Substring>) -> Commit? {
    let p = Array(p)
    let hash = String(p[0])
    guard hash.count >= 40, hash.allSatisfy(\.isHexDigit) else { return nil }
    return Commit(hash: hash, parents: p[1].split(separator: " ").map(String.init), authorName: String(p[2]),
                  authorEmail: String(p[3]), date: Date(timeIntervalSince1970: TimeInterval(p[4]) ?? 0),
                  subject: String(p[6]), refs: parseDecorations(p[5]))
}

/// `%D` with `--decorate=full`: `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
/// Ref names can't contain ", ". Remote symbolic heads (origin/HEAD) are dropped.
func parseDecorations<S: StringProtocol>(_ s: S) -> [CommitRef] {
    var refs: [CommitRef] = []
    for raw in s.components(separatedBy: ", ") where !raw.isEmpty {
        var name = raw
        var isHead = false
        if name.hasPrefix("HEAD -> ") { isHead = true; name = String(name.dropFirst("HEAD -> ".count)) }
        if name.hasPrefix("tag: ") { name = String(name.dropFirst("tag: ".count)) }
        if name == "HEAD" {
            refs.append(CommitRef(kind: .head, name: "HEAD", isHead: true))
        } else if name.hasPrefix("refs/heads/") {
            refs.append(CommitRef(kind: .branch, name: String(name.dropFirst("refs/heads/".count)), isHead: isHead))
        } else if name.hasPrefix("refs/remotes/") {
            let short = String(name.dropFirst("refs/remotes/".count))
            if !short.hasSuffix("/HEAD") { refs.append(CommitRef(kind: .remote, name: short)) }
        } else if name.hasPrefix("refs/tags/") {
            refs.append(CommitRef(kind: .tag, name: String(name.dropFirst("refs/tags/".count))))
        }
    }
    return refs
}
