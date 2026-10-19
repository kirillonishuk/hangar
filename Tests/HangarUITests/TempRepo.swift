import Foundation

/// Copy of Tests/GitTests/TempRepo.swift (test targets share no code). Real temporary repositories under `<tmp>/hangar-git-<uuid>/проект с пробелом/` (space + Cyrillic on purpose).
/// The user's git configuration never influences the fixture.
struct TempRepo {
    let root: String
    let base: String      // "<root>/проект с пробелом"
    var origin: String { base + "/origin.git" }
    var repo: String { base + "/repo" }
    var worktrees: String { base + ".worktrees" }  // sibling of base, inside root

    /// Bare origin + clone `repo` with one commit on `main`, pushed, `origin/HEAD` set.
    init() throws {
        root = NSTemporaryDirectory() + "hangar-git-\(UUID().uuidString)"
        base = root + "/проект с пробелом"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", origin, in: base)
        try git("clone", "-q", origin, repo, in: base)
        try git("checkout", "-q", "-B", "main", in: repo)
        try commit(file: "a.txt", on: "main")
        try git("push", "-q", "-u", "origin", "main", in: repo)
        try git("remote", "set-head", "origin", "main", in: repo)
    }

    /// A plain `git init` repo without remote; `branch` is the initial branch.
    init(emptyWithBranch branch: String = "main") throws {
        root = NSTemporaryDirectory() + "hangar-git-\(UUID().uuidString)"
        base = root + "/проект с пробелом"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try git("init", "-q", "-b", branch, repo, in: base)
    }

    @discardableResult
    func git(_ args: String..., in dir: String) throws -> String {
        try run(args, in: dir)
    }

    @discardableResult
    func run(_ args: [String], in dir: String, extraEnv: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["LC_ALL"] = "C"
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env.merge(extraEnv) { $1 }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TempRepo", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args) failed: \(String(decoding: errData, as: UTF8.self))"])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits `file` (unique content) on `branch` in `dir` (default: `repo`); `date` is a unix timestamp.
    func commit(file: String, on branch: String, in dir: String? = nil, date: Int? = nil) throws {
        let d = dir ?? repo
        if (try? git("symbolic-ref", "--short", "HEAD", in: d)) != branch { try git("checkout", "-q", branch, in: d) }
        let content = UUID().uuidString
        try content.write(toFile: d + "/" + file, atomically: true, encoding: .utf8)
        try git("add", file, in: d)
        if let date {
            let iso = "\(date) +0000"
            _ = try run(["commit", "-q", "-m", "c \(file)", "--date", iso], in: d, extraEnv: ["GIT_COMMITTER_DATE": iso])
        } else {
            try git("commit", "-q", "-m", "c \(file)", in: d)
        }
    }

    /// Pushes `branch` from `repo` to origin.
    func pushBranch(_ branch: String) throws {
        try git("push", "-q", "origin", branch, in: repo)
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
