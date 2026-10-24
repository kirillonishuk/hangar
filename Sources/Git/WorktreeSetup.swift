import Darwin
import Foundation

/// A project's «copy into worktree» list and setup command when it has none of its own (decision #NN-worktree-setup),
/// from the lockfiles at the repository top. pnpm/yarn/bun reinstall from their store (hardlinks, fast, no extra
/// space), so `node_modules` is not cloned; npm (or no lockfile) clones it (APFS: no extra space) and installs nothing.
public struct WorktreeDefaults: Equatable, Sendable {
    public var copy: [String]
    public var command: String?

    public init(lockfiles: Set<String>) {
        let env = [".env*", ".venv", "vendor/bundle"]
        if lockfiles.contains("pnpm-lock.yaml") {
            (copy, command) = (env, "pnpm install --frozen-lockfile --prefer-offline")
        } else if lockfiles.contains("yarn.lock") {
            (copy, command) = (env, lockfiles.contains(".yarnrc.yml") ? "yarn install --immutable" : "yarn install --frozen-lockfile")
        } else if lockfiles.contains("bun.lockb") || lockfiles.contains("bun.lock") {
            (copy, command) = (env, "bun install --frozen-lockfile")
        } else {
            (copy, command) = ([".env*", "node_modules", ".venv", "vendor/bundle"], nil)
        }
    }

    /// The files `init(lockfiles:)` looks at.
    public static let markers = ["pnpm-lock.yaml", "yarn.lock", ".yarnrc.yml", "bun.lockb", "bun.lock", "package-lock.json"]
}

/// Entries (from `ignoredEntries`, top-relative) that `patterns` select, in entry order. gitignore-like: a pattern
/// without `/` (or starting with `**/`) matches the last component at any depth, except under `node_modules`, `.git`,
/// `dist`, `.turbo`; one with `/` (or a leading `/`) matches the whole path; a trailing `/` is dropped.
/// Patterns or entries with `..` select nothing, so nothing outside the project is ever named.
public func matchIgnored(_ patterns: [String], _ entries: [String]) -> [String] {
    func escapes(_ p: String) -> Bool { p.split(separator: "/").contains("..") }
    let skipped: Set<Substring> = ["node_modules", ".git", "dist", ".turbo"]
    let globs: [(glob: String, wholePath: Bool)] = patterns.compactMap { raw in
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchored = p.hasPrefix("/")
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        while p.hasPrefix("**/") { p.removeFirst(3) }
        guard !p.isEmpty, !escapes(p), !p.contains("**") else { return nil }
        return (p, anchored || p.contains("/"))
    }
    return entries.filter { entry in
        guard !entry.isEmpty, !entry.hasPrefix("/"), !escapes(entry) else { return false }
        let parts = entry.split(separator: "/")
        let nameOnly = !parts.dropLast().contains { skipped.contains($0) }
        return globs.contains { g in
            g.wholePath ? fnmatch(g.glob, entry, FNM_PATHNAME) == 0 : nameOnly && fnmatch(g.glob, String(parts.last!), 0) == 0
        }
    }
}

extension Git {
    /// Ignored, untracked entries of the whole repository, relative to its top, without a trailing `/`. An ignored
    /// folder is one entry: git does not descend into it (nor through symlinks), so every entry lies inside the repo.
    public func ignoredEntries() async throws -> [String] {
        let args = ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--full-name", "--", ":/"]
        return try await lines(args).map { s in
            var e = s
            while e.hasSuffix("/") { e.removeLast() }
            return e
        }
    }

    /// Which of `WorktreeDefaults.markers` are tracked at the repository top.
    public func lockfiles() async throws -> Set<String> {
        Set(try await lines(["ls-files", "-z", "--full-name", "--"] + WorktreeDefaults.markers.map { ":(top,literal)" + $0 }))
    }

    /// Copies `entry` of the main checkout (`top`, from `toplevel()`) into the same place in `worktree` on the runner's
    /// machine: an APFS clone (`cp -c`) here, `cp --reflink=auto` on a server, else a plain copy. Symlinks are copied
    /// as they are (a relative pnpm link keeps resolving inside the copy), never followed.
    /// A missing source or an existing destination is skipped.
    public func copyIgnored(_ entry: String, from top: String, into worktree: String) async throws {
        let (fast, plain) = runner.isLocal ? ("cp -cpR", "cp -pR") : ("cp -a --reflink=auto", "cp -a")
        // The destination did not exist, so removing a half-made first attempt touches nothing of the user's.
        let script = """
        s=$1 d=$2
        if [ -e "$d" ] || [ -L "$d" ] || { [ ! -e "$s" ] && [ ! -L "$s" ]; }; then exit 0; fi
        mkdir -p -- "${d%/*}" || exit 1
        \(fast) -- "$s" "$d" 2>/dev/null && exit 0
        rm -rf -- "$d"
        exec \(plain) -- "$s" "$d"
        """
        let args = ["/bin/sh", "-c", script, "sh", top + "/" + entry, worktree + "/" + entry]
        let r = try await runner.run(args, repo)
        guard r.status == 0 else { throw GitError(args: ["cp", entry], status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func lines(_ args: [String]) async throws -> [String] {
        let r = try await runner.run(["git", "--no-optional-locks"] + args, repo)
        guard r.status == 0 else { throw GitError(args: args, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.stdout.split(separator: "\0").map(String.init)
    }
}
