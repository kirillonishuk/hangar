import Foundation
import Exec

/// Read-only commands for the inspector. `--no-optional-locks`: otherwise `status` rewrites .git/index,
/// which fires FSEvents, which triggers `status` again.
extension Git {
    public func toplevel() async throws -> String {
        try await inspect(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func gitDir() async throws -> String {
        try await inspect(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The top level and the folder's place under it: `apps/web/` for a project in a subfolder (#44), "" at the top.
    public func location() async throws -> (top: String, prefix: String) {
        let lines = try await inspect(["rev-parse", "--show-toplevel", "--show-prefix"]).split(separator: "\n", omittingEmptySubsequences: false)
        return (String(lines.first ?? ""), lines.count > 1 ? String(lines[1]) : "")
    }

    /// `prefix` (from `location`): only entries under it, relative to it — porcelain paths are always top-relative.
    public func status(limit: Int = 5_000, prefix: String = "") async throws -> StatusResult {
        let scope = prefix.isEmpty ? [] : ["--", ":(top,literal)" + prefix]
        let out = try await inspect(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames"] + scope)
        var r = parseStatusV2(out, limit: limit)
        guard !prefix.isEmpty else { return r }
        func strip(_ p: String) -> String { p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p }
        r.entries = r.entries.map { StatusEntry(path: strip($0.path), origPath: $0.origPath.map(strip), change: $0.change) }
        return r
    }

    /// Commits of HEAD not in `base` and of `base` not in HEAD (`rev-list --left-right --count`).
    public func aheadBehind(base: String) async throws -> (ahead: Int, behind: Int) {
        guard !base.hasPrefix("-") else { throw GitError(args: [base], status: 128, stderr: "invalid base") }
        let parts = try await inspect(["rev-list", "--left-right", "--count", base + "...HEAD", "--"])
            .split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        guard parts.count == 2 else { throw GitError(args: ["rev-list"], status: 0, stderr: "unexpected output") }
        return (parts[1], parts[0])
    }

    /// The common git-dir: the main repository's for a linked worktree, else the same as `gitDir`.
    public func commonDir() async throws -> String {
        try await inspect(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ignored entries under the folder, relative to the top level; a wholly ignored directory comes as one `dir/` (not descended into).
    public func ignoredPaths() async throws -> [String] {
        let out = try await inspect(["status", "--porcelain=v2", "-z", "--ignored=matching", "--untracked-files=normal", "--", "."])
        return out.split(separator: "\0", omittingEmptySubsequences: true).compactMap { $0.hasPrefix("! ") ? String($0.dropFirst(2)) : nil }
    }

    /// Tracked + untracked, not ignored, under the folder (`ls-files` lists its cwd); paths relative to it.
    public func listFiles(limit: Int = FileListing.limit) async throws -> FileListing {
        // `-s`: "<mode> <sha> <stage>\t<path>" (mode 120000 = symlink); works on every git, unlike `--format`.
        let tracked = try await inspect(["ls-files", "-c", "-s", "-z"])
        let others = try await inspect(["ls-files", "-o", "--exclude-standard", "-z"])
        var seen = Set<Substring>()  // unmerged entries are listed once per stage
        var paths: [String] = []
        var dirLinks = Set<String>()
        var truncated = false
        func add(_ p: Substring, link: Bool) -> Bool {
            guard seen.insert(p).inserted else { return true }
            if paths.count == limit { truncated = true; return false }
            let path = String(p)
            paths.append(path)
            if link, runner.isLocal, isDirectoryLink(repo + "/" + path) { dirLinks.insert(path) }
            return true
        }
        for line in tracked.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            guard add(line[line.index(after: tab)...], link: line.hasPrefix("120000 ")) else { break }
        }
        if !truncated {
            // An untracked symlink looks like a file to git: only the file system tells.
            for p in others.split(separator: "\0", omittingEmptySubsequences: true) where !add(p, link: true) { break }
        }
        return FileListing(paths: paths, truncated: truncated, dirLinks: dirLinks)
    }

    /// shortcut: local lstat/stat only; remote directory symlinks show as files, change when that is wanted (deferred in stage 6).
    private func isDirectoryLink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK, stat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR
    }

    // MARK: Changes

    /// Changes under the folder, paths relative to it. `status`: the caller's own result (the inspector already ran it,
    /// with the folder's prefix), else one is run here for the untracked files.
    public func changedFiles(_ mode: DiffMode, limit: Int = 5_000, status given: StatusResult? = nil) async throws -> ChangeSet {
        var effective = mode
        var baseMissing = false
        var from: String?
        if case .base(let b) = mode {
            if !b.hasPrefix("-"),
               let r = try? await runner.run(["git", "--no-optional-locks", "merge-base", "HEAD", b], repo),
               r.status == 0, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                from = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                effective = .uncommitted
                baseMissing = true
            }
        }
        if from == nil {
            if await hasCommits() {
                from = "HEAD"
            } else {
                from = try await inspect(["hash-object", "-t", "tree", "/dev/null"]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let rev = from!
        // `--`: a file named like the rev (`HEAD`) is otherwise "ambiguous argument". `--relative` + `.`: only the
        // folder, paths relative to it (a no-op at the top level); a rename from outside it shows as added.
        let names = parseNameStatus(try await inspect(["diff", "--name-status", "-z", "--find-renames", "--relative", rev, "--", "."]))
        let stats = parseNumstat(try await inspect(["diff", "--numstat", "-z", "--find-renames", "--relative", rev, "--", "."]))
        var byPath: [String: NumstatEntry] = [:]
        for s in stats { byPath[s.path] = s }
        var files = names.map { f -> ChangedFile in
            var f = f
            if let s = byPath[f.path] { f.added = s.added; f.deleted = s.deleted }
            return f
        }
        let st: StatusResult
        if let given { st = given } else { st = try await status(limit: limit, prefix: location().prefix) }
        // `git rm --cached x`: deleted in the diff and untracked in status — keep the diff's entry.
        let listed = Set(files.map(\.path))
        var counted = 0
        for e in st.entries where e.change == .untracked && !listed.contains(e.path) {
            var f = ChangedFile(path: e.path, change: .untracked)
            // `diff HEAD` has no numstat for untracked files: count their lines, so the row shows «+N» like the others.
            // shortcut: only the first `untrackedCounts` (one git process each); raise when a batched count exists.
            if counted < Self.untrackedCounts {
                counted += 1
                let run = try? await inspectRun(["diff", "--no-index", "--numstat", "-z", "--", "/dev/null", e.path], ok: [0, 1])
                if let entry = run.flatMap({ parseNumstat($0.stdout).first }) { f.added = entry.added }
            }
            files.append(f)
        }
        let truncated = st.truncated || files.count > limit
        // Status may be capped while `diff HEAD` omits some of its entries (staged, then reverted): fewer files than the limit.
        if files.count > limit { files.removeLast(files.count - limit) }
        return ChangeSet(files: files, from: rev, mode: effective, baseMissing: baseMissing, truncated: truncated)
    }

    /// Untracked files whose lines `changedFiles` counts (one `git diff --no-index` each).
    static let untrackedCounts = 50

    public func diff(file: ChangedFile, from: String, maxLines: Int = 20_000) async throws -> FileDiff {
        let untracked = file.change == .untracked
        let paths = (untracked ? ["/dev/null"] : []) + (file.origPath.map { [$0] } ?? []) + [file.path]
        let target = untracked ? ["--no-index"] : [from]
        // `--no-index` exits 1 when the files differ.
        let ok: Set<Int32> = untracked ? [0, 1] : [0]
        let statRun = try await inspectRun(["diff", "--numstat", "-z"] + target + ["--"] + paths, ok: ok)
        // A directory, nested repository or directory symlink: git prints "Could not access" and exits 1.
        if untracked, statRun.status == 1, statRun.stdout.isEmpty, !statRun.stderr.isEmpty { return .notAFile }
        let stat = statRun.stdout
        let entries = parseNumstat(stat)
        if entries.contains(where: { $0.added == nil }) { return .binary }
        let total = entries.reduce(0) { $0 + ($1.added ?? 0) + ($1.deleted ?? 0) }
        if total > maxLines { return .tooLarge(lines: total) }
        let args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                    "--find-renames", "-U3"] + target + ["--"] + paths
        return parseUnifiedDiff(try await inspect(args, ok: ok))
    }

    private func inspect(_ args: [String], ok: Set<Int32> = [0]) async throws -> String {
        try await inspectRun(args, ok: ok).stdout
    }

    private func inspectRun(_ args: [String], ok: Set<Int32> = [0]) async throws -> RunResult {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, repo)
        guard ok.contains(r.status) else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }
}
