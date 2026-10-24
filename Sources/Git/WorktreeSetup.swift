import Darwin
import Foundation

/// Entries (from `ignoredEntries`) that `patterns` select, in entry order. gitignore-like: a pattern without `/`
/// matches the last component at any depth, one with `/` (or a leading `/`) the whole relative path; a trailing `/`
/// is dropped. Patterns or entries with `..` select nothing, so nothing outside the project is ever named.
public func matchIgnored(_ patterns: [String], _ entries: [String]) -> [String] {
    func escapes(_ p: String) -> Bool { p.split(separator: "/").contains("..") }
    let globs: [(glob: String, wholePath: Bool)] = patterns.compactMap { raw in
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchored = p.hasPrefix("/")
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        guard !p.isEmpty, !escapes(p) else { return nil }
        return (p, anchored || p.contains("/"))
    }
    return entries.filter { entry in
        guard !entry.isEmpty, !entry.hasPrefix("/"), !escapes(entry) else { return false }
        let name = (entry as NSString).lastPathComponent
        return globs.contains { g in fnmatch(g.glob, g.wholePath ? entry : name, g.wholePath ? FNM_PATHNAME : 0) == 0 }
    }
}

extension Git {
    /// Ignored, untracked entries of the work tree, relative, without a trailing `/`. An ignored folder is one entry:
    /// git does not descend into it (nor through symlinks), so every entry lies inside the project.
    public func ignoredEntries() async throws -> [String] {
        let args = ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]
        let r = try await runner.run(["git", "--no-optional-locks"] + args, repo)
        guard r.status == 0 else { throw GitError(args: args, status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return r.stdout.split(separator: "\0").map { s in
            var e = String(s)
            while e.hasSuffix("/") { e.removeLast() }
            return e
        }
    }

    /// Copies `entry` of the main folder into the same place in `worktree` on the runner's machine: an APFS clone
    /// (`cp -c`) here, `cp --reflink=auto` on a server, else a plain copy. Symlinks are copied as links, never followed.
    /// A missing source or an existing destination is skipped.
    public func copyIgnored(_ entry: String, into worktree: String) async throws {
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
        let args = ["/bin/sh", "-c", script, "sh", repo + "/" + entry, worktree + "/" + entry]
        let r = try await runner.run(args, repo)
        guard r.status == 0 else { throw GitError(args: ["cp", entry], status: r.status, stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
