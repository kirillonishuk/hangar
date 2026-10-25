import Foundation
import Exec

extension Git {
    /// One file of a commit against its first parent (the empty tree for a root commit), as `commit(hash:)` lists it:
    /// `path` / `origPath` are top-relative, whatever folder git runs in. Read-only, never the working tree.
    public func commitFileDiff(hash: String, path: String, origPath: String? = nil, maxLines: Int = 20_000) async throws -> FileDiff {
        guard (4...64).contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
            throw GitError(args: [], status: 128, stderr: "invalid hash")
        }
        let rev = hash.lowercased() + "^{commit}"
        let paths = ([origPath].compactMap { $0 } + [path]).map { ":(top,literal)" + $0 }
        // As `commit(hash:)`: a merge shows what it brought in (`-m --first-parent`), renames are followed.
        let show = ["show", "--no-color", "--no-ext-diff", "--no-textconv", "--format=", "-m", "--first-parent", "--find-renames"]
        let entries = parseNumstat(try await commitDiffRun(show + ["--numstat", "-z", rev, "--"] + paths))
        if entries.contains(where: { $0.added == nil }) { return .binary }
        let total = entries.reduce(0) { $0 + ($1.added ?? 0) + ($1.deleted ?? 0) }
        if total > maxLines { return .tooLarge(lines: total) }
        return parseUnifiedDiff(try await commitDiffRun(show + ["--src-prefix=a/", "--dst-prefix=b/", "-U3", rev, "--"] + paths))
    }

    private func commitDiffRun(_ args: [String]) async throws -> String {
        let full = ["--no-optional-locks"] + args
        let r = try await runner.run(["git"] + full, repo)
        guard r.status == 0 else {
            throw GitError(args: full, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }
}
