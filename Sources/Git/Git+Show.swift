import Exec
import Foundation

extension Git {
    /// The file's text at `rev` (`path` from the top level; `./…` from `repo`); nil when it is not in that revision.
    public func show(rev: String, path: String) async throws -> String? {
        guard !rev.hasPrefix("-") else { return nil }
        let r = try await runner.run(["git", "--no-optional-locks", "show", "--no-textconv", "\(rev):\(path)"], repo)
        return r.status == 0 ? r.stdout : nil
    }

    /// The file's bytes at `rev` (an image's old side); nil when it is not there, over `maxBytes`, or the repo is on a
    /// server. shortcut: local only — `Runner` decodes stdout as text; give it a byte channel when remote images are wanted.
    public func blob(rev: String, path: String, maxBytes: Int) async throws -> Data? {
        guard runner.isLocal, !rev.hasPrefix("-"), localDeveloperToolMissing("git") == nil else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        let box = BlobBuffer(max: maxBytes)
        let r = try await streamProcess("/usr/bin/env", ["git", "--no-optional-locks", "cat-file", "blob", "\(rev):\(path)"],
                                        cwd: repo, env: env) { box.append($0) }
        return r.status == 0 ? box.result : nil
    }
}

/// The blob's chunks as they arrive; past `max` it gives up (and the run is cut).
private final class BlobBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let max: Int
    private var data = Data()
    private var over = false

    init(max: Int) { self.max = max }

    func append(_ chunk: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !over, data.count + chunk.count <= max else { over = true; return false }
        data.append(chunk)
        return true
    }

    var result: Data? {
        lock.lock(); defer { lock.unlock() }
        return over ? nil : data
    }
}
