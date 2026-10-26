import Exec

extension Git {
    /// The file's text at `rev` (`path` from the top level; `./…` from `repo`); nil when it is not in that revision.
    public func show(rev: String, path: String) async throws -> String? {
        guard !rev.hasPrefix("-") else { return nil }
        let r = try await runner.run(["git", "--no-optional-locks", "show", "--no-textconv", "\(rev):\(path)"], repo)
        return r.status == 0 ? r.stdout : nil
    }
}
