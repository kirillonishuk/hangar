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

    public func status(limit: Int = 5_000) async throws -> StatusResult {
        let out = try await inspect(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames"])
        return parseStatusV2(out, limit: limit)
    }

    /// The common git-dir: the main repository's for a linked worktree, else the same as `gitDir`.
    public func commonDir() async throws -> String {
        try await inspect(["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ignored entries relative to the top level; a wholly ignored directory comes as one `dir/` (not descended into).
    public func ignoredPaths() async throws -> [String] {
        let out = try await inspect(["status", "--porcelain=v2", "-z", "--ignored=matching", "--untracked-files=normal"])
        return out.split(separator: "\0", omittingEmptySubsequences: true).compactMap { $0.hasPrefix("! ") ? String($0.dropFirst(2)) : nil }
    }

    /// Tracked + untracked, not ignored; paths relative to the repository root.
    public func listFiles(limit: Int = 200_000) async throws -> FileListing {
        let root = try await toplevel()
        let tracked = try await inspect(["ls-files", "-c", "-z", "--format=%(objectmode) %(path)"], cwd: root)
        let others = try await inspect(["ls-files", "-o", "--exclude-standard", "-z"], cwd: root)
        var seen = Set<Substring>()  // unmerged entries are listed once per stage
        var paths: [String] = []
        var dirLinks = Set<String>()
        var truncated = false
        func add(_ p: Substring, link: Bool) -> Bool {
            guard seen.insert(p).inserted else { return true }
            if paths.count == limit { truncated = true; return false }
            let path = String(p)
            paths.append(path)
            if link, isDirectoryLink(root + "/" + path) { dirLinks.insert(path) }
            return true
        }
        for line in tracked.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " ") else { continue }
            guard add(line[line.index(after: space)...], link: line[..<space] == "120000") else { break }
        }
        if !truncated {
            // An untracked symlink looks like a file to git: only the file system tells.
            for p in others.split(separator: "\0", omittingEmptySubsequences: true) where !add(p, link: true) { break }
        }
        return FileListing(paths: paths, truncated: truncated, dirLinks: dirLinks)
    }

    /// shortcut: local lstat/stat, stage 6 (ssh) goes through Exec.
    private func isDirectoryLink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK, stat(path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR
    }

    // MARK: Changes

    /// `status`: the caller's own result (the inspector already ran it), else one is run here for the untracked files.
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
        let names = parseNameStatus(try await inspect(["diff", "--name-status", "-z", "--find-renames", rev]))
        let stats = parseNumstat(try await inspect(["diff", "--numstat", "-z", "--find-renames", rev]))
        var byPath: [String: NumstatEntry] = [:]
        for s in stats { byPath[s.path] = s }
        var files = names.map { f -> ChangedFile in
            var f = f
            if let s = byPath[f.path] { f.added = s.added; f.deleted = s.deleted }
            return f
        }
        let st: StatusResult
        if let given { st = given } else { st = try await status(limit: limit) }
        for e in st.entries where e.change == .untracked {
            files.append(ChangedFile(path: e.path, change: .untracked))
        }
        let truncated = st.truncated || files.count > limit
        // Status may be capped while `diff HEAD` omits some of its entries (staged, then reverted): fewer files than the limit.
        if files.count > limit { files.removeLast(files.count - limit) }
        return ChangeSet(files: files, from: rev, mode: effective, baseMissing: baseMissing, truncated: truncated)
    }

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

    private func inspect(_ args: [String], cwd: String? = nil, ok: Set<Int32> = [0]) async throws -> String {
        try await inspectRun(args, cwd: cwd, ok: ok).stdout
    }

    private func inspectRun(_ args: [String], cwd: String? = nil, ok: Set<Int32> = [0]) async throws -> RunResult {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, cwd ?? repo)
        guard ok.contains(r.status) else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }
}
