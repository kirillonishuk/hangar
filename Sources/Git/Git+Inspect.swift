import Foundation

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

    /// Tracked + untracked, not ignored; paths relative to the repository root.
    public func listFiles(limit: Int = 200_000) async throws -> FileListing {
        let root = try await toplevel()
        let out = try await inspect(["ls-files", "-co", "--exclude-standard", "-z"], cwd: root)
        var seen = Set<Substring>()  // unmerged entries are listed once per stage
        var paths: [String] = []
        var truncated = false
        for p in out.split(separator: "\0", omittingEmptySubsequences: true) where seen.insert(p).inserted {
            if paths.count == limit { truncated = true; break }
            paths.append(String(p))
        }
        return FileListing(paths: paths, truncated: truncated)
    }

    // MARK: Changes

    public func changedFiles(_ mode: DiffMode, limit: Int = 5_000) async throws -> ChangeSet {
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
        for e in try await status(limit: limit).entries where e.change == .untracked {
            files.append(ChangedFile(path: e.path, change: .untracked))
        }
        let truncated = files.count > limit
        if truncated { files.removeLast(files.count - limit) }
        return ChangeSet(files: files, from: rev, mode: effective, baseMissing: baseMissing, truncated: truncated)
    }

    public func diff(file: ChangedFile, from: String, maxLines: Int = 20_000) async throws -> FileDiff {
        let untracked = file.change == .untracked
        let paths = (untracked ? ["/dev/null"] : []) + (file.origPath.map { [$0] } ?? []) + [file.path]
        let target = untracked ? ["--no-index"] : [from]
        // `--no-index` exits 1 when the files differ.
        let ok: Set<Int32> = untracked ? [0, 1] : [0]
        let stat = try await inspect(["diff", "--numstat", "-z"] + target + ["--"] + paths, ok: ok)
        let entries = parseNumstat(stat)
        if entries.contains(where: { $0.added == nil }) { return .binary }
        let total = entries.reduce(0) { $0 + ($1.added ?? 0) + ($1.deleted ?? 0) }
        if total > maxLines { return .tooLarge(lines: total) }
        let args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                    "--find-renames", "-U3"] + target + ["--"] + paths
        return parseUnifiedDiff(try await inspect(args, ok: ok))
    }

    private func inspect(_ args: [String], cwd: String? = nil, ok: Set<Int32> = [0]) async throws -> String {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, cwd ?? repo)
        guard ok.contains(r.status) else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }
}
