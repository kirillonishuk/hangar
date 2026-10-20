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

    private func inspect(_ args: [String], cwd: String? = nil) async throws -> String {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, cwd ?? repo)
        guard r.status == 0 else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }
}
