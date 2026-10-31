import Foundation

// Files of «<host> · терминал» (#64, spec 2026-10-31-remote-files-design): the tab's own ssh is the master, its shell
// reports the folder (OSC 7), the inspector lists and uploads through that master — never a second login.

extension SSHPaths {
    /// The master socket of one host-terminal leaf: per leaf, so closing one tab never waits for another's sessions.
    public func shellControlPath(_ leaf: UUID) -> String { dir + "/hs-" + fnv1a64Hex(leaf.uuidString.lowercased()) }
}

/// `ssh -G <host>` as `key → value` (keys lowercase, first value wins): the user's ssh config for this host without
/// connecting. nil when ssh fails or takes longer than `timeout` (a slow `Match exec`).
/// shortcut: runs synchronously at a tab's launch (milliseconds normally, bounded by `timeout`); async when launches are.
public func sshResolvedOptions(host: String, sshPath: String, timeout: TimeInterval = 2) -> [String: String]? {
    guard let host = validSSHHost(host) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: sshPath)
    p.arguments = ["-G", "--", host]
    p.standardInput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { return nil }
    let data = Captured()
    let reader = Thread { data.set(out.fileHandleForReading.readDataToEndOfFile()) }
    reader.start()
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        return nil
    }
    data.wait()
    guard p.terminationStatus == 0 else { return nil }
    return parseSSHOptions(String(decoding: data.value.prefix(1 << 20), as: UTF8.self))
}

private final class Captured: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private(set) var value = Data()
    func set(_ d: Data) { value = d; sem.signal() }
    func wait() { sem.wait() }
}

func parseSSHOptions(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].lowercased()
        if out[key] == nil { out[key] = String(parts[1]) }
    }
    return out
}

/// How a host terminal tab logs in (#124). Never worse than a plain `ssh -t` (#64):
/// - `ssh -G` failed, or no master can be used → a plain login, no files panel;
/// - the host's config has a RemoteCommand (ssh refuses a second one) or the hook failed before → no hook;
/// - the user's own ControlMaster/ControlPath → the tab keeps theirs (no `-S`), the panel uses their socket;
/// - else Hangar's own per-leaf socket (`ownControlPath`; nil when its folder is unsafe).
public struct HostShellPlan: Equatable, Sendable {
    public var hook: Bool
    /// The master the files panel goes through; nil = no panel.
    public var controlPath: String?
    /// `-S controlPath -o ControlMaster=auto -o ControlPersist=no` on the tab (Hangar's own master).
    public var ownMaster: Bool

    public init(hook: Bool, controlPath: String?, ownMaster: Bool) {
        self.hook = hook; self.controlPath = controlPath; self.ownMaster = ownMaster
    }

    public static let plain = HostShellPlan(hook: false, controlPath: nil, ownMaster: false)
}

public func hostShellPlan(resolved: [String: String]?, ownControlPath: String?, noHook: Bool) -> HostShellPlan {
    guard let o = resolved else { return .plain }
    let remoteCommand = o["remotecommand"].map { !$0.isEmpty && $0 != "none" } ?? false
    let userPath = o["controlpath"].flatMap { $0.isEmpty || $0 == "none" ? nil : $0 }
    let userMaster = !["false", "no"].contains(o["controlmaster"] ?? "false")
    let path: String?, own: Bool
    if userMaster || userPath != nil { (path, own) = (userPath, false) } else { (path, own) = (ownControlPath, ownControlPath != nil) }
    return HostShellPlan(hook: path != nil && !remoteCommand && !noHook, controlPath: path, ownMaster: own)
}

/// Scripts that reach a server through its login shell are one line without `!`: tcsh/csh reject a newline inside
/// quotes and expand `!` even there. Written one statement per line here, each line ending where a space may follow.
func oneLine(_ script: String) -> String {
    script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
}

/// Runs in the server's login shell before the user's shell: adds a prompt hook that reports `$PWD` as
/// `OSC 7 kitty-shell-cwd://localhost<path>` (Ghostty drops OSC 7 of any other host; `kitty-shell-cwd` takes the path
/// raw). Nothing is installed: zsh gets a temporary ZDOTDIR (deleted when read; a watcher deletes it after a minute if
/// /etc/zshenv redirects ZDOTDIR and it is never read), bash an exported PROMPT_COMMAND for a normal login shell, fish `-C`; any other shell starts as
/// before. The hook keeps `$?` for the user's prompt.
public let hostShellLoginScript = oneLine(#"""
s=${SHELL:-/bin/sh};
case ${s##*/} in
zsh) d=$(mktemp -d "${TMPDIR:-/tmp}/hangar.XXXXXX" 2>/dev/null) || exec "$s" -l;
printf '%s\n' 'if [[ -n $HANGAR_ZDOTDIR_SET ]]; then ZDOTDIR=$HANGAR_ZDOTDIR; else unset ZDOTDIR; fi' 'command rm -rf -- "$HANGAR_HOOK_DIR"; unset HANGAR_ZDOTDIR HANGAR_ZDOTDIR_SET HANGAR_HOOK_DIR' '[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"' '__hangar_cwd() { local s=$?; builtin printf "\033]7;kitty-shell-cwd://localhost%s\007" "$PWD"; return $s; }' 'autoload -Uz add-zsh-hook && add-zsh-hook precmd __hangar_cwd' > "$d/.zshenv" || { rm -rf "$d"; exec "$s" -l; };
(i=0; while [ -d "$d" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done; rm -rf "$d") </dev/null >/dev/null 2>&1 &
HANGAR_ZDOTDIR_SET=${ZDOTDIR+1}; HANGAR_ZDOTDIR=${ZDOTDIR-}; HANGAR_HOOK_DIR=$d; ZDOTDIR=$d;
export HANGAR_ZDOTDIR_SET HANGAR_ZDOTDIR HANGAR_HOOK_DIR ZDOTDIR;
exec "$s" -l;;
bash) PROMPT_COMMAND='__hangar_s=$?; printf "\033]7;kitty-shell-cwd://localhost%s\007" "$PWD"; (exit $__hangar_s)';
export PROMPT_COMMAND;
exec "$s" -l;;
fish) exec "$s" -l -C 'function __hangar_cwd --on-event fish_prompt; printf "\e]7;kitty-shell-cwd://localhost%s\a" "$PWD"; end';;
esac;
exec "$s" -l
"""#)

/// A folder reported by a server's shell (OSC 7): untrusted, so only an absolute path of ≤ 4096 bytes without control
/// characters is kept. It is only ever an argument of commands on that server, never a path on this Mac.
public func validRemoteCwd(_ s: String) -> String? {
    guard s.hasPrefix("/"), s.utf8.count <= 4096 else { return nil }
    for u in s.unicodeScalars where u.value < 0x20 || (0x7f...0x9f).contains(u.value) { return nil }
    return s
}

/// A host terminal leaf's master: background commands go through it or fail at once (`offline`) — never log in anew.
public struct RemoteShellLink: Sendable, Equatable, Hashable {
    public var host: String
    public var controlPath: String
    public var sshPath: String
    /// Hangar started this master (its `-S` on the tab); false: the user's own ControlMaster from ssh config, which
    /// Hangar uses but never ends.
    public var owned: Bool

    public init(host: String, controlPath: String, sshPath: String, owned: Bool = true) {
        self.host = host; self.controlPath = controlPath; self.sshPath = sshPath; self.owned = owned
    }

    /// The master's socket exists (the tab is logged in); a stale one fails in ssh itself.
    public var isUp: Bool { FileManager.default.fileExists(atPath: controlPath) }

    /// ssh argv for `script` on the host. ProxyCommand=false: without a live master ssh would otherwise dial the host
    /// directly (a second login); with it, that attempt fails at once with 255. nil for an invalid host.
    public func argv(script: String, args: [String]) -> [String]? {
        guard let host = validSSHHost(host) else { return nil }
        return sshBaseArgs(controlPath: controlPath) + ["-o", "ProxyCommand=/usr/bin/false", "-T", "--", host,
                                                        remoteShellArgs(script: script, args)]
    }

    /// ssh argv running `argv` in `cwd` on the host with stdio kept open (Search), PATH as sshd gives it.
    public func streamArgv(cwd: String, argv: [String]) -> [String]? { self.argv(script: remoteRunScript, args: ["", cwd] + argv) }

    /// `ssh -O exit`: the master ends now (its tab is closed), not when its last multiplexed session does.
    public var exitArgv: [String]? {
        guard owned, let host = validSSHHost(host) else { return nil }
        return ["-S", controlPath, "-O", "exit", "--", host]
    }
}

public enum RemoteFileError: Error, Equatable, Sendable {
    /// No live master (still logging in, connection lost, tab closed).
    case offline
    case missing(String)
    case noAccess(String)
    /// The name is taken (asked: replace / skip).
    case exists(String)
    /// A file over a folder or a folder over a file: never replaced.
    case kindClash(String)
    case noTar
    /// The stream ended early (cancel, broken connection): nothing was put under the real name.
    case incomplete(String)
    case failed(String)
}

public struct RemoteEntry: Hashable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case dir, dirLink, file, link }
    public var name: String
    public var kind: Kind
    public var id: String { name }
    public var isDir: Bool { kind == .dir || kind == .dirLink }

    public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
}

public struct RemoteListing: Equatable, Sendable {
    public static let limit = 5000
    public static let maxOutput = 1 << 20
    public var entries: [RemoteEntry] = []
    public var truncated = false

    public init(entries: [RemoteEntry] = [], truncated: Bool = false) { self.entries = entries; self.truncated = truncated }
}

/// `$1` folder, `$2` limit. Prints `<type><name>\0` per entry (d folder, D link to a folder, l other link, f other),
/// `T\0` past the limit. Exit 3: no such folder, 4: not readable. No `ls` parsing, no GNU `find`.
let remoteListScript = oneLine(#"""
cd -- "$1" 2>/dev/null || { [ -d "$1" ] && exit 4; exit 3; };
[ -r . ] || exit 4;
n=0;
for f in .* *; do
case "$f" in .|..) continue;; esac;
[ -e "$f" ] || [ -L "$f" ] || continue;
n=$((n+1));
if [ "$n" -gt "$2" ]; then printf 'T\000'; exit 0; fi;
if [ -d "$f" ]; then if [ -L "$f" ]; then t=D; else t=d; fi; elif [ -L "$f" ]; then t=l; else t=f; fi;
printf '%s%s\000' "$t" "$f";
done
"""#)

/// Strict reading of the listing (server output is untrusted): unknown records are dropped, at most `limit` entries;
/// folders first, then by name as Finder sorts.
public func parseRemoteListing(_ data: Data, limit: Int = RemoteListing.limit) -> RemoteListing {
    var out = RemoteListing()
    for record in data.split(separator: 0, omittingEmptySubsequences: true) {
        guard let type = record.first else { continue }
        if type == UInt8(ascii: "T"), record.count == 1 { out.truncated = true; continue }
        let kind: RemoteEntry.Kind
        switch type {
        case UInt8(ascii: "d"): kind = .dir
        case UInt8(ascii: "D"): kind = .dirLink
        case UInt8(ascii: "f"): kind = .file
        case UInt8(ascii: "l"): kind = .link
        default: continue
        }
        let name = String(decoding: record.dropFirst(), as: UTF8.self)
        guard validUploadName(name) != nil else { continue }
        if out.entries.count >= limit { out.truncated = true; break }
        out.entries.append(RemoteEntry(name: name, kind: kind))
    }
    out.entries.sort { a, b in
        a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    return out
}

/// One folder of the server through the leaf's master.
public func listRemoteFolder(_ link: RemoteShellLink, path: String, limit: Int = RemoteListing.limit) async throws -> RemoteListing {
    guard link.isUp, let argv = link.argv(script: remoteListScript, args: [path, String(limit)]) else { throw RemoteFileError.offline }
    let r = try await runProcess(link.sshPath, argv, cwd: "/", env: ProcessInfo.processInfo.environment, maxOutput: RemoteListing.maxOutput)
    let raw = Data(r.stdout.utf8)
    // Cut at the cap (ssh killed): what came is shown, marked as cut.
    if raw.count >= RemoteListing.maxOutput {
        var listing = parseRemoteListing(raw.prefix(raw.lastIndex(of: 0) ?? 0), limit: limit)
        listing.truncated = true
        return listing
    }
    switch r.status {
    case 0: return parseRemoteListing(raw, limit: limit)
    case 3: throw RemoteFileError.missing(path)
    case 4: throw RemoteFileError.noAccess(path)
    case 255: throw RemoteFileError.offline
    default: throw RemoteFileError.failed(firstLine(r.stderr))
    }
}

/// A file or folder name that is safe as one path component on the server.
public func validUploadName(_ s: String) -> String? {
    guard !s.isEmpty, s != ".", s != "..", !s.contains("/"), s.utf8.count <= 255 else { return nil }
    for u in s.unicodeScalars where u.value < 0x20 || u.value == 0x7f { return nil }
    return s
}

/// `$1` folder, `$2` name, `$3` local mode (octal), `$4` 1 = replace, `$5` size; stdin = the file. Written to a hidden
/// `.<name>.hangar-part` beside it (`set -C`: a link planted under that name in a shared folder is never followed) and
/// moved in only when complete, so a broken stream never leaves a half file under the real name. A new file gets the
/// local mode under the server's umask; a replaced file keeps its mode and (where allowed) owner; a replaced link is
/// replaced, not followed. Exit 4 no folder access, 10 name taken (checked before and after the transfer), 11 a folder
/// (or a link to one) has the name, 13 write failed (stderr), 14 incomplete.
let remoteFileUploadScript = oneLine(#"""
n=$2; r=$4;
cd -- "$1" 2>/dev/null || exit 4;
ex() { [ -e "$n" ] || [ -L "$n" ]; };
if ex; then [ "$r" = 1 ] || exit 10; if [ -d "$n" ]; then exit 11; fi; fi;
m=$(printf '%o' $((0$3 & ~0$(umask) & 0777)));
t=".$n.hangar-part";
rm -f -- "$t";
set -C;
cat > "$t" || { rm -f -- "$t"; exit 13; };
set +C;
if [ "$(wc -c < "$t" | tr -d ' ')" = "$5" ]; then :; else rm -f -- "$t"; exit 14; fi;
if ex; then
if [ "$r" = 1 ]; then :; else rm -f -- "$t"; exit 10; fi;
if [ -d "$n" ]; then rm -f -- "$t"; exit 11; fi;
if [ -L "$n" ]; then rm -f -- "$n"; else m=$(stat -c %a -- "$n" 2>/dev/null || stat -f %Lp -- "$n" 2>/dev/null || echo "$m"); o=$(stat -c %u:%g -- "$n" 2>/dev/null || stat -f %u:%g -- "$n" 2>/dev/null); [ -z "$o" ] || chown -- "$o" "$t" 2>/dev/null; fi;
fi;
chmod -- "$m" "$t" 2>/dev/null;
mv -f -- "$t" "$n" || { rm -f -- "$t"; exit 13; }
"""#)

/// `$1` folder, `$2` name, `$3` 1 = merge into an existing folder, `$4` number of files; stdin = a tar of `./<name>/`.
/// Unpacked into a hidden `.<name>.hangar-part/`, checked (a folder with all its files), then moved in — or, when the
/// name is taken and merging was chosen, copied into the existing folder with `cp -R`: same names are overwritten in
/// place (their mode stays), existing folders keep their mode and time, nothing on the server is deleted. A link to a
/// folder under the name is a clash, never followed. Exit codes as the file script, 12 = no tar.
let remoteFolderUploadScript = oneLine(#"""
n=$2; r=$3;
cd -- "$1" 2>/dev/null || exit 4;
command -v tar >/dev/null 2>&1 || exit 12;
ex() { [ -e "$n" ] || [ -L "$n" ]; };
real() { if [ -L "$n" ]; then return 1; fi; [ -d "$n" ]; };
if ex; then [ "$r" = 1 ] || exit 10; real || exit 11; fi;
t=".$n.hangar-part";
rm -rf -- "$t";
mkdir -- "$t" || exit 13;
tar -xf - -C "$t" || { rm -rf -- "$t"; exit 14; };
ok=0; if [ -L "$t/$n" ]; then ok=0; elif [ -d "$t/$n" ]; then [ "$(find "$t/$n" -type f | wc -l | tr -d ' ')" = "$4" ] && ok=1; fi;
if [ "$ok" = 1 ]; then :; else rm -rf -- "$t"; exit 14; fi;
if ex; then
if [ "$r" = 1 ]; then :; else rm -rf -- "$t"; exit 10; fi;
real || { rm -rf -- "$t"; exit 11; };
cp -R -- "$t/$n/." "$n/" || { rm -rf -- "$t"; exit 13; };
rm -rf -- "$t";
else
mv -- "$t/$n" "$n" || { rm -rf -- "$t"; exit 13; };
rmdir -- "$t";
fi
"""#)

/// Longest name an upload takes: `.<name>.hangar-part` must still fit NAME_MAX (255 bytes).
public let uploadNameLimit = 255 - ".".utf8.count - ".hangar-part".utf8.count

/// What an upload sends: its size in bytes for the progress (a folder: its files plus tar headers, an estimate).
public struct UploadSource: Equatable, Sendable {
    public var url: URL
    public var name: String
    public var isFolder: Bool
    public var bytes: Int64
    public var files: Int
    public var mode: Int

    /// nil for something that is neither a readable file nor a folder (or has a name unsafe on the server).
    public init?(_ url: URL) {
        let real = url.resolvingSymlinksInPath()
        guard let name = validUploadName(real.lastPathComponent), name.utf8.count <= uploadNameLimit,
              let attrs = try? FileManager.default.attributesOfItem(atPath: real.path) else { return nil }
        self.url = real
        self.name = name
        self.mode = (attrs[.posixPermissions] as? Int ?? 0o644) & 0o777
        switch attrs[.type] as? FileAttributeType {
        case .typeRegular?:
            isFolder = false
            bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            files = 1
        case .typeDirectory?:
            isFolder = true
            var total: Int64 = 0, count = 0
            let e = FileManager.default.enumerator(at: real, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let item = e?.nextObject() as? URL {
                guard let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
                count += 1
                total += Int64(v.fileSize ?? 0) + 512
            }
            bytes = total
            files = count
        default:
            return nil
        }
    }
}

/// The local tar of a folder upload (`./<name>`: a name starting with `-` is never an option): no macOS metadata (`._*`, xattrs, ACLs, flags), owner root — as `scp` leaves files
/// to the server's user.
func uploadTarArgs(_ source: UploadSource) -> [String] {
    ["--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "--uid", "0", "--gid", "0", "--uname", "root",
     "--gname", "root", "-cf", "-", "-C", source.url.deletingLastPathComponent().path, "./" + source.name]
}

/// Puts `source` into the server folder `dir` through the leaf's master; `replace`: overwrite a file / merge a folder.
/// `progress` gets the bytes sent so far. Cancel stops the transfer; nothing appears under the real name then.
public func uploadToRemote(_ link: RemoteShellLink, source: UploadSource, dir: String, replace: Bool,
                           progress: @escaping @Sendable (Int64) -> Void) async throws {
    let script = source.isFolder ? remoteFolderUploadScript : remoteFileUploadScript
    let args = source.isFolder ? [dir, source.name, replace ? "1" : "0", String(source.files)]
        : [dir, source.name, String(source.mode, radix: 8), replace ? "1" : "0", String(source.bytes)]
    guard link.isUp, let argv = link.argv(script: script, args: args) else { throw RemoteFileError.offline }
    let feed: @Sendable (FileHandle) -> Void = { sink in
        if source.isFolder { feedTar(source, to: sink, progress: progress) } else { feedFile(source.url, to: sink, progress: progress) }
    }
    let r = try await runProcess(link.sshPath, argv, cwd: "/", env: ProcessInfo.processInfo.environment, maxOutput: 64 << 10, feed: feed)
    if let error = uploadError(status: r.status, stderr: r.stderr, name: source.name, dir: dir) { throw error }
}

func uploadError(status: Int32, stderr: String, name: String, dir: String) -> RemoteFileError? {
    switch status {
    case 0: nil
    case 4: .noAccess(dir)
    case 10: .exists(name)
    case 11: .kindClash(name)
    case 12: .noTar
    case 13: stderr.localizedCaseInsensitiveContains("permission denied") ? .noAccess(dir) : .failed(firstLine(stderr))
    case 14: .incomplete(name)
    case 255: .offline
    default: .failed(firstLine(stderr))
    }
}

private func feedFile(_ url: URL, to sink: FileHandle, progress: @Sendable (Int64) -> Void) {
    guard let file = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? file.close() }
    var sent: Int64 = 0
    while let chunk = try? file.read(upToCount: 256 << 10), !chunk.isEmpty {
        guard writeChunk(chunk, to: sink) else { return }
        sent += Int64(chunk.count)
        progress(sent)
    }
}

private func feedTar(_ source: UploadSource, to sink: FileHandle, progress: @Sendable (Int64) -> Void) {
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = uploadTarArgs(source)
    var env = ProcessInfo.processInfo.environment
    env["COPYFILE_DISABLE"] = "1"
    tar.environment = env
    let out = Pipe()
    tar.standardOutput = out
    tar.standardError = FileHandle.nullDevice
    tar.standardInput = FileHandle.nullDevice
    guard (try? tar.run()) != nil else { return }
    var sent: Int64 = 0
    let reader = out.fileHandleForReading
    while let chunk = try? reader.read(upToCount: 256 << 10), !chunk.isEmpty {
        guard writeChunk(chunk, to: sink) else { tar.terminate(); break }
        sent += Int64(chunk.count)
        progress(sent)
    }
    tar.waitUntilExit()
}

/// false when the reader is gone (ssh ended: cancel, lost connection, the server refused early).
private func writeChunk(_ data: Data, to sink: FileHandle) -> Bool {
    let fd = sink.fileDescriptor
    return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}

let removeLeftoverScript = #"cd -- "$1" 2>/dev/null && rm -rf -- ".$2.hangar-part""#

/// After a cancelled upload: its hidden `.<name>.hangar-part` goes (the server side may have been cut before its own
/// cleanup ran). Only that temp name is ever removed.
public func removeUploadLeftover(_ link: RemoteShellLink, dir: String, name: String) async {
    guard validUploadName(name) != nil, link.isUp,
          let argv = link.argv(script: removeLeftoverScript, args: [dir, name]) else { return }
    _ = try? await runProcess(link.sshPath, argv, cwd: "/", env: ProcessInfo.processInfo.environment, maxOutput: 4096)
}

/// Ends the master of a closed host-terminal leaf (fire and forget).
public func stopRemoteMaster(_ link: RemoteShellLink) {
    guard let args = link.exitArgv, link.isUp else { return }
    Task.detached { _ = try? await runProcess(link.sshPath, args, cwd: "/", env: ProcessInfo.processInfo.environment, maxOutput: 4096) }
}

private func firstLine(_ s: String) -> String {
    let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return String(line.prefix(200))
}
