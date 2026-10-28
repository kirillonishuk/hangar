import CryptoKit
import Foundation

public enum UpdateError: Error, Equatable, Sendable {
    case http(Int)
    case network(String)
    case badChecksumFile
    case checksumMismatch
    case mount(String)
    case noApp
    /// The DMG's app has another bundle id (the found one).
    case wrongBundle(String)
    /// The DMG's app has another version than the release (the found one).
    case wrongVersion(String)
    case helper(String)
    /// A redirect to a host outside `ReleaseFeed.trustedHosts`.
    case untrusted(String)
    /// `codesign --verify --deep --strict` refused the new app.
    case signature(String)
    /// The download is bigger than allowed (by its Content-Length or the bytes received).
    case tooLarge
}

/// Follows a redirect only to a trusted URL (`ReleaseFeed.isTrusted` in release builds).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trusted: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var refused: URL?

    init(trusted: @escaping @Sendable (URL) -> Bool) { self.trusted = trusted }

    var refusedURL: URL? { lock.withLock { refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, trusted(url) else {
            lock.withLock { refused = request.url }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}

/// Fetching, checking and installing a release (decision #86). No UI: `UpdateModel` (HangarUI) drives it.
public enum Updater {
    /// GET with the GitHub API headers; the system proxy applies (URLSession). Non-2xx HTTP → `.http(code)`.
    public static func fetch(_ url: URL, userAgent: String,
                             trusted: @escaping @Sendable (URL) -> Bool = ReleaseFeed.isTrusted) async throws -> Data {
        guard trusted(url) else { throw UpdateError.untrusted(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let guardian = RedirectGuard(trusted: trusted)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request, delegate: guardian) } catch {
            if let bad = guardian.refusedURL { throw UpdateError.untrusted(bad.absoluteString) }
            throw UpdateError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw UpdateError.http(http.statusCode) }
        return data
    }

    /// Downloads `url` to `dest` (replaced), reporting 0…1 (or nothing when the size is unknown); the URL and every
    /// redirect must be `trusted`. More than `maxBytes` (announced or received) → `.tooLarge`.
    public static func download(_ url: URL, to dest: URL, trusted: @escaping @Sendable (URL) -> Bool = ReleaseFeed.isTrusted,
                                maxBytes: Int64 = .max, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard trusted(url) else { throw UpdateError.untrusted(url.absoluteString) }
        try await Download(dest: dest, trusted: trusted, maxBytes: maxBytes, progress: progress).run(url)
    }

    /// The hash of a `shasum -a 256` line (`<hex>  Hangar-X.Y.Z.dmg`), lower-cased; nil if it isn't one.
    public static func parseChecksum(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first, token.count == 64,
              token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses (`checksumMismatch`) unless `file` hashes to the one in `checksumFile`.
    public static func verify(_ file: URL, checksumFile: URL) throws {
        guard let text = try? String(contentsOf: checksumFile, encoding: .utf8), let expected = parseChecksum(text) else {
            throw UpdateError.badChecksumFile
        }
        guard try sha256(of: file) == expected else { throw UpdateError.checksumMismatch }
    }

    /// `hdiutil attach -nobrowse -readonly`; returns the mount point.
    public static func mount(_ dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard out.status == 0 else { throw UpdateError.mount(out.error) }
        let plist = try? PropertyListSerialization.propertyList(from: out.output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let point = entities.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateError.mount("no mount point") }
        return URL(fileURLWithPath: point)
    }

    public static func detach(_ mountPoint: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    /// `Hangar.app` at the top of the image, else the only `.app` there; a real directory, never a symlink.
    public static func findApp(in dir: URL) throws -> URL {
        let fm = FileManager.default
        // `attributesOfItem` doesn't follow symlinks: a link to elsewhere is not an app.
        func isRealDir(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory }
        let hangar = dir.appendingPathComponent("Hangar.app")
        if isRealDir(hangar) { return hangar }
        let apps = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }
            .map { dir.appendingPathComponent($0) }.filter(isRealDir)
        guard apps.count == 1 else { throw UpdateError.noApp }
        return apps[0]
    }

    /// The new app's signature must be intact (ad-hoc releases: integrity, not identity — decision #86).
    public static func verifySignature(_ app: URL) throws {
        let out = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard out.status == 0 else { throw UpdateError.signature(out.error) }
    }

    /// The new app must be Hangar (`bundleId`) of exactly the release's `version`.
    public static func verifyBundle(_ app: URL, bundleId: String, version: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let id = info?["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleId else { throw UpdateError.wrongBundle(id) }
        let found = info?["CFBundleShortVersionString"] as? String ?? ""
        guard found == version else { throw UpdateError.wrongVersion(found) }
    }

    /// The running bundle can be swapped in place: an `.app` whose folder and bundle we may write
    /// (not a read-only volume, not App Translocation, not another user's /Applications).
    public static func canReplace(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        return bundle.pathExtension == "app" && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: bundle.path)
    }

    public enum Relaunch: Sendable {
        /// `open` the new bundle (release).
        case open
        /// Run its executable directly with our environment (DEBUG: keeps the isolated state dir; `open` would drop it).
        case exec(String)
        /// Tests.
        case none
    }

    /// Waits for `pid` to exit, then copies `source` next to `target`, swaps them with two renames (the old bundle is
    /// put back if the second fails), removes quarantine, detaches `mount`, relaunches. Failures go to `errorFile`.
    public static let script = #"""
    #!/bin/sh
    # Hangar updater (decision #86): args pid source target mount errorfile relaunch [executable]
    # System tools by absolute path; never the user's PATH. HANGAR_UPDATE_MV / HANGAR_UPDATE_WAIT are test-only.
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    MV=${HANGAR_UPDATE_MV:-/bin/mv}
    pid=$1 src=$2 dst=$3 mnt=$4 err=$5 relaunch=$6 exe=$7
    here=$(/usr/bin/dirname "$0")
    fail() { printf '%s\n' "$1" > "$err"; }
    # The image is detached and the download dir (DMG, checksum, this script) removed on every path.
    cleanup() {
      if [ -n "$mnt" ]; then /usr/bin/hdiutil detach "$mnt" -quiet >/dev/null 2>&1; fi
      case "$(/usr/bin/basename "$here")" in hangar-update-*) /bin/rm -rf "$here" ;; esac
    }
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt "${HANGAR_UPDATE_WAIT:-600}" ]; then fail "Hangar did not quit"; cleanup; exit 1; fi
      /bin/sleep 0.2
    done
    dir=$(/usr/bin/dirname "$dst"); name=$(/usr/bin/basename "$dst")
    new="$dir/.$name.hangar-new.$$"; old="$dir/.$name.hangar-old.$$"
    ok=0
    /bin/rm -rf "$new"
    if ! /usr/bin/ditto "$src" "$new" 2>/dev/null; then
      fail "cannot copy the new app to $dir"
    elif [ ! -d "$new" ] || [ -L "$new" ]; then
      fail "the new app is not a folder"
    else
      /usr/bin/xattr -dr com.apple.quarantine "$new" 2>/dev/null
      if ! "$MV" "$dst" "$old" 2>/dev/null; then
        fail "cannot move $dst"
      elif ! "$MV" "$new" "$dst" 2>/dev/null; then
        /bin/mv "$old" "$dst"
        fail "cannot put the new app at $dst"
      else
        ok=1
        /bin/rm -rf "$old"
      fi
    fi
    /bin/rm -rf "$new"
    cleanup
    case "$relaunch" in
      open) /usr/bin/open "$dst" ;;
      exec) /usr/bin/nohup "$dst/$exe" >/dev/null 2>&1 & ;;
    esac
    [ "$ok" = 1 ]
    """#

    /// The arguments of `script` after its path.
    public static func scriptArguments(pid: Int32, source: URL, target: URL, mount: URL?, errorFile: URL, relaunch: Relaunch) -> [String] {
        let mode: [String] = switch relaunch {
        case .open: ["open"]
        case .exec(let exe): ["exec", exe]
        case .none: ["none"]
        }
        return [String(pid), source.path, target.path, mount?.path ?? "", errorFile.path] + mode
    }

    /// Writes `script` into `dir` and starts it detached (it outlives us: it waits for our exit).
    public static func launchHelper(in dir: URL, arguments: [String]) throws {
        let path = dir.appendingPathComponent("hangar-update.sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path.path] + arguments
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        } catch {
            throw UpdateError.helper(error.localizedDescription)
        }
    }

    struct Output {
        var status: Int32
        var output: Data
        var error: String
    }

    /// Runs a tool to completion (call off the main thread).
    static func run(_ tool: String, _ args: [String], environment: [String: String]? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, output: data,
                      error: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One download task with progress (the async `URLSession.download` reports none).
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let guardian: RedirectGuard
    private let progress: @Sendable (Double) -> Void
    private let maxBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(dest: URL, trusted: @escaping @Sendable (URL) -> Bool, maxBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.dest = dest
        self.maxBytes = maxBytes
        guardian = RedirectGuard(trusted: trusted)
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock { continuation = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guardian.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { failure = UpdateError.tooLarge }
            downloadTask.cancel()
            return
        }
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns: move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { failure = UpdateError.http(http.statusCode) }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxBytes {
            lock.withLock { failure = UpdateError.tooLarge }
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            lock.withLock { failure = UpdateError.network(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, stored) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { continuation = nil }
            return (continuation, failure)
        }
        if let bad = guardian.refusedURL { c?.resume(throwing: UpdateError.untrusted(bad.absoluteString)) }
        else if let stored, error != nil { c?.resume(throwing: stored) }  // cancelled by us (too large)
        else if let error { c?.resume(throwing: UpdateError.network(error.localizedDescription)) }
        else if let stored { c?.resume(throwing: stored) }
        else { c?.resume() }
    }
}
