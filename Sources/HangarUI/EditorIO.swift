import Exec
import Foundation

/// Size and modification time (seconds): what tells a file changed on disk.
/// shortcut: remote mtimes are whole seconds — an outside rewrite of the same size within the second of a load goes unseen.
struct FileStamp: Equatable, Sendable {
    var size: Int64
    var mtime: Double
}

enum EditorRead: Equatable, Sendable {
    case text(String, FileStamp)
    case tooLarge(Int64)
    case binary
    case missing
}

struct EditorIOError: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// The editor's file access: this Mac directly, a server through the host's runner (argv, no shell strings) and its
/// stdin writer. Writes are atomic: a hidden `.<name>.hangar-tmp` next to the file, then a rename over it.
struct EditorIO: Sendable {
    var isLocal: Bool
    /// Reads the file unless it is over `maxBytes`.
    var read: @Sendable (_ path: String, _ maxBytes: Int) async throws -> EditorRead
    /// nil: the file is gone.
    var stat: @Sendable (_ path: String) async throws -> FileStamp?
    var write: @Sendable (_ path: String, _ text: String) async throws -> FileStamp

    /// NUL in the first 8 KB, or not UTF-8.
    static func decodeText(_ data: Data) -> String? {
        guard !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let local = EditorIO(
        isLocal: true,
        read: { path, maxBytes in
            guard let stamp = localStamp(path) else { return .missing }
            if stamp.size > maxBytes { return .tooLarge(stamp.size) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let text = decodeText(data) else { return .binary }
            return .text(text, stamp)
        },
        stat: { localStamp($0) },
        write: { path, text in
            // Through a symlink: the file it points at is replaced, the link stays.
            let target = realPath(path)
            let dir = (target as NSString).deletingLastPathComponent
            let tmp = dir + "/." + (target as NSString).lastPathComponent + ".hangar-tmp"
            let mode = (try? FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int) ?? 0o644
            guard FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
                throw EditorIOError(description: String(cString: strerror(errno)))
            }
            guard rename(tmp, target) == 0 else {
                let message = String(cString: strerror(errno))
                unlink(tmp)
                throw EditorIOError(description: message)
            }
            guard let stamp = localStamp(target) else { throw EditorIOError(description: "stat failed") }
            return stamp
        })

    private static func localStamp(_ path: String) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), a[.type] as? FileAttributeType != .typeDirectory,
              let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size.int64Value, mtime: date.timeIntervalSince1970)
    }

    /// `size mtime` of `$1` (GNU stat, else BSD); `missing` when there is no such file.
    private static let statScript = #"stat -c '%s %Y' -- "$1" 2>/dev/null || stat -f '%z %m' -- "$1" 2>/dev/null || echo missing"#
    /// The stamp line, then the bytes when `$1` is at most `$2` bytes.
    private static let readScript = #"""
    [ -f "$1" ] || { echo missing; exit 0; }
    st=$(stat -c '%s %Y' -- "$1" 2>/dev/null || stat -f '%z %m' -- "$1") || exit 1
    printf '%s\n' "$st"
    [ "${st%% *}" -le "$2" ] && exec cat -- "$1"
    exit 0
    """#
    /// stdin → a temp file beside `$1` (its mode copied), renamed over it; then the new stamp.
    private static let writeScript = #"""
    f=$1
    if [ -L "$f" ]; then r=$(readlink -f -- "$f") && f=$r; fi
    t="$(dirname -- "$f")/.$(basename -- "$f").hangar-tmp"
    if [ -f "$f" ]; then cp -p -- "$f" "$t" || exit 1; fi
    cat > "$t" || { rm -f -- "$t"; exit 1; }
    mv -f -- "$t" "$f" || { rm -f -- "$t"; exit 1; }
    stat -c '%s %Y' -- "$f" 2>/dev/null || stat -f '%z %m' -- "$f"
    """#

    static func parseStamp(_ line: Substring) -> FileStamp? {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let size = Int64(parts[0]), let mtime = Double(parts[1]) else { return nil }
        return FileStamp(size: size, mtime: mtime)
    }

    /// `runner`: the host's commands; `write`: `/bin/sh -c script sh args…` with stdin (`RemoteHosts.write`).
    static func remote(runner: Runner, write: @escaping @Sendable (_ script: String, _ args: [String], _ input: Data) async throws -> RunResult) -> EditorIO {
        @Sendable func failed(_ r: RunResult) -> EditorIOError {
            EditorIOError(description: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "exit \(r.status)" : r.stderr)
        }
        return EditorIO(
            isLocal: false,
            read: { path, maxBytes in
                let r = try await runner.run(["sh", "-c", readScript, "sh", path, String(maxBytes)], "/")
                guard r.status == 0 else { throw failed(r) }
                let head = r.stdout.prefix { $0 != "\n" }
                if head == "missing" { return .missing }
                guard let stamp = parseStamp(head) else { throw failed(r) }
                if stamp.size > maxBytes { return .tooLarge(stamp.size) }
                let text = String(r.stdout.dropFirst(head.count + 1))
                // The runner decodes stdout as UTF-8 with replacement characters: those mean "not UTF-8".
                guard !text.contains("\0"), !text.contains("\u{FFFD}") else { return .binary }
                return .text(text, stamp)
            },
            stat: { path in
                let r = try await runner.run(["sh", "-c", statScript, "sh", path], "/")
                guard r.status == 0 else { throw failed(r) }
                let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return line == "missing" ? nil : parseStamp(Substring(line))
            },
            write: { path, text in
                let r = try await write(writeScript, [path], Data(text.utf8))
                guard r.status == 0, let stamp = parseStamp(Substring(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) else {
                    throw failed(r)
                }
                return stamp
            })
    }
}

enum DiskChange: Equatable { case none, reload, conflict }

/// A file changed on disk: a clean buffer takes it silently, a dirty one asks. A deleted file leaves the buffer as is.
func diskChange(loaded: FileStamp?, current: FileStamp?, dirty: Bool) -> DiskChange {
    guard let current, current != loaded else { return .none }
    return dirty ? .conflict : .reload
}
