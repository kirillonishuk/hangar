import Foundation

/// Worktrees an agent made or moved into on its own (decision HD-134): Hangar follows them, never changes them unasked.

/// `path` equals `folder` or lies inside it (both normalized the same way).
public func pathIsInside(_ path: String, folder: String) -> Bool {
    let f = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
    return path == f || path.hasPrefix(f == "/" ? "/" : f + "/")
}

/// The deepest listed (not prunable) worktree holding `path`: a worktree nested in another one wins.
public func worktree(containing path: String, in list: [WorktreeEntry], normalize: (String) -> String = { $0 }) -> WorktreeEntry? {
    let p = normalize(path)
    return list.filter { !$0.prunable && pathIsInside(p, folder: normalize($0.path)) }
        .max { normalize($0.path).count < normalize($1.path).count }
}

/// The agent reported `cwd`: the other linked worktree it works in, or nil — in the chat's own checkout (any subfolder),
/// in the main checkout, or outside the repository.
public func otherWorktree(cwd: String, chatFolder: String, in list: [WorktreeEntry],
                           normalize: (String) -> String = { $0 }) -> WorktreeEntry? {
    guard let at = worktree(containing: cwd, in: list, normalize: normalize), let main = list.first,
          normalize(at.path) != normalize(main.path) else { return nil }
    let own = worktree(containing: chatFolder, in: list, normalize: normalize)
    return own.map { normalize($0.path) == normalize(at.path) } == true ? nil : at
}

/// Linked worktrees no chat uses (`used`: every chat's folder, archived ones too): made by an agent or by hand.
public func unusedWorktrees(_ list: [WorktreeEntry], used: [String], normalize: (String) -> String = { $0 }) -> [WorktreeEntry] {
    let taken = Set(used.map(normalize))
    return list.dropFirst().filter { !$0.prunable && !taken.contains(normalize($0.path)) }
}

/// A chat's name for a copy's branch (HD-141): after the last `/`, and only the tracker key when it leads and is
/// followed by the end or a separator and a non-digit (`user/aut-1076-epik-…` → `aut-1076`; `release-2026-11` stays).
public func shortChatName(branch: String) -> String {
    let rest = branch.split(separator: "/").last.map(String.init) ?? branch
    return rest.prefixMatch(of: /^([A-Za-z]+-[0-9]+)(?:$|[-_.][^0-9])/).map { String($0.output.1) } ?? rest
}

/// The branch git has checked out at `path` now (an agent's `branch -m` / `checkout -b`); nil — not listed or detached.
public func registeredBranch(at path: String, in list: [WorktreeEntry], normalize: (String) -> String = { $0 }) -> String? {
    let p = normalize(path)
    return list.dropFirst().first { !$0.prunable && normalize($0.path) == p }?.branch
}

/// Linked worktrees strictly inside `folder`, relative to it (`.claude/worktrees/x`): separate checkouts nested in a chat's folder.
public func nestedWorktrees(in folder: String, list: [WorktreeEntry], normalize: (String) -> String = { $0 }) -> [String] {
    let f = normalize(folder)
    return list.dropFirst().compactMap { e in
        let p = normalize(e.path)
        guard !e.prunable, p != f, pathIsInside(p, folder: f) else { return nil }
        return String(p.dropFirst(f == "/" ? 1 : f.count + 1))
    }
}

/// The `.git/info/exclude` lines that hide these nested worktrees (relative to the top level): their parent folder
/// (`/.claude/worktrees/`, so the agent's next one is hidden too), or the folder itself when it sits at the top.
public func excludeLines(for nested: [String]) -> [String] {
    var out: [String] = []
    for rel in nested {
        let parent = (rel as NSString).deletingLastPathComponent
        let line = "/" + (parent.isEmpty ? rel : parent) + "/"
        if !out.contains(line) { out.append(line) }
    }
    return out
}

extension Git {
    /// Those of `paths` (relative to the repository folder) git does not ignore (`git check-ignore`).
    public func notIgnored(_ paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        // A folder is checked as one (`dir/`); exit 1 — none ignored, 0 — some, anything else — the check failed.
        let r = try await runner.run(["git", "--no-optional-locks", "check-ignore", "--"] + paths.map { $0 + "/" }, repo)
        guard r.status == 0 || r.status == 1 else { throw GitError(args: ["check-ignore"], status: r.status, stderr: r.stderr.trimmed) }
        let ignored = Set(r.stdout.split(separator: "\n").map { String($0.hasSuffix("/") ? $0.dropLast() : $0) })
        return paths.filter { !ignored.contains($0) }
    }

    /// Appends `lines` to the repository's `info/exclude` (local, never committed), each once; only on the user's click.
    /// Returns the file's path.
    @discardableResult
    public func appendToExclude(_ lines: [String]) async throws -> String {
        var file = try await exec(["rev-parse", "--git-path", "info/exclude"]).trimmed
        if !file.hasPrefix("/") { file = repo + "/" + file }
        let script = #"""
        f=$1; shift
        mkdir -p "$(dirname "$f")" || exit 1
        [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ] && { echo >> "$f" || exit 1; }
        for l; do grep -qxF -- "$l" "$f" 2>/dev/null || printf '%s\n' "$l" >> "$f" || exit 1; done
        """#
        let r = try await runner.run(["sh", "-c", script, "sh", file] + lines, "/")
        guard r.status == 0 else { throw GitError(args: ["info/exclude"], status: r.status, stderr: r.stderr.trimmed) }
        return file
    }
}
