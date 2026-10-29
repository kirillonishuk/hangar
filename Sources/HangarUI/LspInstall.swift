import Exec
import Foundation
import Update

/// A language server Settings → Advanced can download into Hangar's own folder (#102). Each lives in `<dir>/<rawValue>/`
/// with a marker file: only such folders are Hangar's and may be removed.
enum LspPackage: String, CaseIterable, Sendable {
    case pyright, gopls, rustAnalyzer = "rust-analyzer"

    /// The server's executable, relative to Hangar's language-server folder.
    var relativeExecutable: String {
        switch self {
        case .pyright: "pyright/node_modules/.bin/pyright-langserver"
        case .gopls: "gopls/gopls"
        case .rustAnalyzer: "rust-analyzer/rust-analyzer"
        }
    }

    /// The user's tool the install runs (nil: a plain download).
    var tool: String? {
        switch self {
        case .pyright: "npm"
        case .gopls: "go"
        case .rustAnalyzer: nil
        }
    }
}

enum LspInstallError: Error, Equatable {
    /// The tool failed: its exit status and the tail of its output.
    case tool(Int32, String)
    case noAsset
    case download(String)
    /// Not a folder Hangar installed (no marker, a symlink, outside the folder).
    case notOwned
    case missingExecutable
    /// The download or the unpacked server is bigger than allowed, or not the announced size.
    case tooLarge
    /// The unpacked file is not a Mac executable (Mach-O).
    case notExecutable
}

/// Downloads, finds and removes the servers of `LspPackage` (#102). Nothing outside the given folder is written: npm's
/// and Go's caches go to a temporary folder next to the staging one; no shell, no sudo.
enum LspInstaller {
    static let marker = ".hangar-lsp.json"
    static let rustFeed = URL(string: "https://api.github.com/repos/rust-lang/rust-analyzer/releases/latest")!
    /// The rust-analyzer download (~20 MB today) and the unpacked server (~50 MB): far above, a stop for anything odd.
    static let maxDownload = 100 << 20
    static let maxBinary = 300 << 20

    struct Marker: Codable, Equatable { var version: String }

    /// `<state dir>/lsp` (~/Library/Application Support/Hangar/lsp); DEBUG: `HANGAR_LSP_DIR`.
    static func directory(stateDir: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if DEBUG
        if let dir = env["HANGAR_LSP_DIR"], dir.hasPrefix("/") { return dir }
        #endif
        return stateDir + "/lsp"
    }

    /// The recorded version of a Hangar-installed package whose executable is there; nil otherwise.
    static func installed(_ package: LspPackage, in dir: String) -> Marker? {
        let folder = dir + "/" + package.rawValue
        guard isRealFolder(folder), FileManager.default.isExecutableFile(atPath: dir + "/" + package.relativeExecutable),
              let data = FileManager.default.contents(atPath: folder + "/" + marker) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// An absolute executable `name` in the login PATH or the usual places (`/usr/bin` shims skipped).
    static func tool(_ name: String, path: [String], home: String, isExecutable: (String) -> Bool) -> String? {
        let dirs = path.filter { $0.hasPrefix("/") && $0 != "/usr/bin" } + LspMap.knownDirs(home: home)
        return dirs.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/" + name }.first(where: isExecutable)
    }

    struct Command: Equatable {
        var executable: String
        var args: [String]
        var env: [String: String]
    }

    /// The app's environment the tools may see: home, temp, locale and proxies — nothing else (no DYLD_*, no tokens).
    static func baseEnvironment(_ env: [String: String]) -> [String: String] {
        let keep: Set<String> = ["HOME", "PATH", "TMPDIR", "LANG", "USER", "LOGNAME", "http_proxy", "https_proxy", "no_proxy",
                                 "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY"]
        return env.filter { keep.contains($0.key) || $0.key.hasPrefix("LC_") }
    }

    /// The install run for a tool-built package, as an argv (no shell: paths stay one argument each). `cache`: a
    /// temporary folder for npm's / Go's caches (removed afterwards), so the user's own caches are not written.
    static func command(_ package: LspPackage, staging: String, cache: String, tool: String, path: String?,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Command? {
        guard tool.hasPrefix("/"), staging.hasPrefix("/"), cache.hasPrefix("/") else { return nil }
        var env = baseEnvironment(environment)
        // npm's and go's own child tools (node) are found next to them when the login PATH is unknown.
        env["PATH"] = path ?? ((tool as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "/usr/bin:/bin"))
        switch package {
        case .pyright:
            env["npm_config_update_notifier"] = "false"
            env["npm_config_cache"] = cache + "/npm"
            env["npm_config_userconfig"] = "/dev/null"
            return Command(executable: tool, args: ["install", "--prefix", staging, "--ignore-scripts", "--no-package-lock",
                                                    "--no-audit", "--no-fund", "pyright"], env: env)
        case .gopls:
            env["GOBIN"] = staging
            env["GOTOOLCHAIN"] = "local"
            // -modcacherw: the module cache can be deleted afterwards (Go makes it read-only).
            env["GOFLAGS"] = "-mod=mod -modcacherw"
            env["GOMODCACHE"] = cache + "/mod"
            env["GOCACHE"] = cache + "/build"
            return Command(executable: tool, args: ["install", "golang.org/x/tools/gopls@latest"], env: env)
        case .rustAnalyzer: return nil
        }
    }

    /// The rust-analyzer asset for this Mac.
    static var rustAsset: String {
        #if arch(arm64)
        "rust-analyzer-aarch64-apple-darwin.gz"
        #else
        "rust-analyzer-x86_64-apple-darwin.gz"
        #endif
    }

    /// The release tag, the asset's URL and its size from a GitHub `releases/latest` answer; the URL must be
    /// `trusted`, the size known and at most `maxSize`.
    static func parseRelease(_ data: Data, asset: String, maxSize: Int = maxDownload,
                             trusted: (URL) -> Bool) -> (tag: String, url: URL, size: Int)? {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: String; var size: Int }
            var tag_name: String
            var assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), isVersion(release.tag_name),
              let a = release.assets.first(where: { $0.name == asset }), let url = URL(string: a.browser_download_url),
              trusted(url), a.size > 0, a.size <= maxSize else { return nil }
        return (release.tag_name, url, a.size)
    }

    /// A Mach-O executable (thin 64-bit or universal): what an unpacked rust-analyzer must be.
    static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let magic = [UInt8](h.readData(ofLength: 4))
        return magic == [0xcf, 0xfa, 0xed, 0xfe] || magic == [0xca, 0xfe, 0xba, 0xbe]
    }

    /// `gunzip -c gz > out`, stopped past `max` bytes (a gzip bomb) → `.tooLarge`.
    static func gunzip(_ gz: String, to out: String, max: Int) async throws {
        guard FileManager.default.createFile(atPath: out, contents: nil), let h = FileHandle(forWritingAtPath: out) else {
            throw LspInstallError.missingExecutable
        }
        defer { try? h.close() }
        final class Count: @unchecked Sendable { var n = 0; var over = false }
        let count = Count()
        let r = try await streamProcess("/usr/bin/gunzip", ["-c", "--", gz], cwd: "/", env: [:]) { chunk in
            count.n += chunk.count
            guard count.n <= max else { count.over = true; return false }
            h.write(chunk)
            return true
        }
        if count.over { throw LspInstallError.tooLarge }
        guard r.status == 0 else { throw LspInstallError.tool(r.status, tail(r)) }
    }

    /// `go version -m` output: the gopls module's version (`\tmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:…`).
    static func goplsVersion(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if f.count >= 3, f[0] == "mod", f[1] == "golang.org/x/tools/gopls", isVersion(String(f[2])) { return String(f[2]) }
        }
        return nil
    }

    /// A version or tag we show and record: short, no spaces or control characters.
    static func isVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }
    }

    /// Installs `package` into `<dir>/<name>`: built in a hidden staging folder, swapped in only when complete
    /// (a cancel or failure leaves the previous install as it was). `tool`: the user's npm / go; `path`: the PATH it
    /// runs with. Returns the installed version.
    static func install(_ package: LspPackage, dir: String, tool: String?, path: String?, feed: URL = rustFeed,
                        trusted: @escaping @Sendable (URL) -> Bool = ReleaseFeed.isTrusted,
                        maxDownload: Int = maxDownload, maxBinary: Int = maxBinary,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = dir + "/." + package.rawValue + "-" + id, cache = dir + "/." + package.rawValue + "-cache-" + id
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: false)
        defer {
            try? fm.removeItem(atPath: staging)
            try? fm.removeItem(atPath: cache)
        }
        let executable = staging + "/" + package.relativeExecutable.split(separator: "/").dropFirst().joined(separator: "/")
        let version: String
        switch package {
        case .rustAnalyzer:
            let data: Data
            do { data = try await Updater.fetch(feed, userAgent: "Hangar", trusted: trusted) } catch { throw LspInstallError.download(describe(error)) }
            guard let (tag, url, size) = parseRelease(data, asset: rustAsset, maxSize: maxDownload, trusted: trusted) else {
                throw LspInstallError.noAsset
            }
            let gz = staging + "/download.gz"
            do {
                try await Updater.download(url, to: URL(fileURLWithPath: gz), trusted: trusted, maxBytes: Int64(maxDownload), progress: progress)
            } catch UpdateError.tooLarge {
                throw LspInstallError.tooLarge
            } catch {
                throw LspInstallError.download(describe(error))
            }
            // GitHub publishes no checksum for these assets: the announced size is what can be checked.
            guard (try? fm.attributesOfItem(atPath: gz)[.size] as? NSNumber)?.intValue == size else { throw LspInstallError.tooLarge }
            try Task.checkCancellation()
            try await gunzip(gz, to: executable, max: maxBinary)
            try fm.removeItem(atPath: gz)
            guard isMachO(executable) else { throw LspInstallError.notExecutable }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
            removexattr(executable, "com.apple.quarantine", 0)
            version = tag
        case .pyright, .gopls:
            guard let tool, let c = command(package, staging: staging, cache: cache, tool: tool, path: path) else {
                throw LspInstallError.tool(127, "")
            }
            try fm.createDirectory(atPath: cache, withIntermediateDirectories: false)
            let r = try await runCaptured(c.executable, c.args, cwd: staging, env: c.env)
            try Task.checkCancellation()
            guard r.status == 0 else { throw LspInstallError.tool(r.status, tail(r)) }
            if package == .pyright {
                let json = fm.contents(atPath: staging + "/node_modules/pyright/package.json")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                version = (json?["version"] as? String).flatMap { isVersion($0) ? $0 : nil } ?? ""
            } else {
                let m = try? await runCaptured(tool, ["version", "-m", executable], cwd: staging, env: c.env)
                version = m.flatMap { goplsVersion($0.stdout) } ?? ""
            }
        }
        guard fm.isExecutableFile(atPath: executable) else { throw LspInstallError.missingExecutable }
        try JSONEncoder().encode(Marker(version: version)).write(to: URL(fileURLWithPath: staging + "/" + marker))
        try Task.checkCancellation()
        try replace(package, dir: dir, with: staging)
        return version
    }

    /// Puts `staging` at `<dir>/<name>`. A previous install (Hangar's only) is moved aside first and deleted only once
    /// the new one is in place; if that move fails, it is put back.
    static func replace(_ package: LspPackage, dir: String, with staging: String,
                        move: (String, String) throws -> Void = { try FileManager.default.moveItem(atPath: $0, toPath: $1) }) throws {
        let fm = FileManager.default
        let target = dir + "/" + package.rawValue
        guard fm.fileExists(atPath: target) || (try? fm.destinationOfSymbolicLink(atPath: target)) != nil else {
            try move(staging, target)
            return
        }
        guard owned(package, dir: dir) else { throw LspInstallError.notOwned }
        let old = dir + "/." + package.rawValue + "-old-" + UUID().uuidString
        try move(target, old)
        do {
            try move(staging, target)
        } catch {
            try? move(old, target)
            throw error
        }
        try? fm.removeItem(atPath: old)
    }

    /// Removes `<dir>/<name>` only if Hangar installed it: a real folder (not a symlink) right inside `dir`, with the marker.
    static func remove(_ package: LspPackage, dir: String) throws {
        guard owned(package, dir: dir) else { throw LspInstallError.notOwned }
        try FileManager.default.removeItem(atPath: dir + "/" + package.rawValue)
    }

    /// A real folder (not a symlink) right inside `dir`, with Hangar's marker.
    private static func owned(_ package: LspPackage, dir: String) -> Bool {
        let target = dir + "/" + package.rawValue
        return isRealFolder(target) && FileManager.default.fileExists(atPath: target + "/" + marker)
            && LspMap.resolved(target) == LspMap.resolved(dir) + "/" + package.rawValue
    }

    private static func isRealFolder(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// The last lines of a failed run, for the row's error text.
    private static func tail(_ r: RunResult) -> String {
        let text = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.http(let code): "HTTP \(code)"
        case UpdateError.untrusted(let url): url
        case UpdateError.network(let text): text
        default: error.localizedDescription
        }
    }
}
