import CryptoKit
import Foundation
import Exec

/// A fake `ssh` (sh script) that runs the remote command locally with HOME = `<dir>/home`; never touches the network.
/// Behaviour switches are files in `dir`, visible to any process: `fail` (`auth` / `refused`) → exit 255, `hang` → sleep; each master's pid → `master.pid` and `master-<host>.pid`.
enum FakeSSH {
    static func make(dir: String) throws -> (path: String, log: String, home: String) {
        let fm = FileManager.default
        let home = dir + "/home", log = dir + "/log", path = dir + "/ssh"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        D=${0%/*}  # the script's own dir: the same content (and scan) for every test
        for a in "$@"; do printf '%s\\n' "$a"; done >> "$D/log"
        printf '%s\\n' '---' >> "$D/log"
        ctl=; fwd=; master=
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; break ;;
            -O) ctl=$2; shift 2 ;;
            -R) fwd=$2; shift 2 ;;
            -o|-S|-L|-p|-l|-i) shift 2 ;;
            -M) master=1; shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        host=$1; shift
        case "$ctl" in
          forward) ln -sf "${fwd#*:}" "${fwd%%:*}"; exit 0 ;;
          exit) kill "$(cat "$D/master.pid")" 2>/dev/null; exit 0 ;;
          ?*) exit 0 ;;
        esac
        if [ -f "$D/fail" ]; then
          case "$(cat "$D/fail")" in
            *auth*) echo 'Permission denied (publickey).' >&2 ;;
            *) echo 'ssh: connect to host dev port 22: Connection refused' >&2 ;;
          esac
          exit 255
        fi
        # exec: killing the fake ssh must not leave a stray sleep behind.
        if [ -f "$D/hang" ]; then exec sleep 300; fi
        [ -n "$master" ] && echo $$ > "$D/master.pid" && echo $$ > "$D/master-$host.pid"
        export HOME="$D/home"
        cd "$HOME" || exit 255
        exec sh -c "$*"
        """
        try writeScript(script, to: path)
        return (path, log, home)
    }

    /// The logged invocations, each one argv.
    static func calls(_ log: String) -> [[String]] {
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        var calls: [[String]] = [], cur: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" { calls.append(cur); cur = [] } else { cur.append(String(line)) }
        }
        return calls
    }
}

/// Puts an executable script at `path` as a hard link to a per-content copy shared by all tests and runs. macOS
/// security-scans every new executable on its first exec, one at a time (XprotectService); fresh per-test scripts
/// queue there for minutes in a full parallel run, a link to an already-scanned file is not scanned again.
/// Scripts find their test's files via `$0`, so the content (and the scan) is shared. Never write to `path` in
/// place afterwards: replace it (`atomically: true`, or `writeScript` again).
func writeScript(_ text: String, to path: String) throws {
    let fm = FileManager.default
    let cache = "/tmp/hangar-test-scripts-\(getuid())"
    try fm.createDirectory(atPath: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // A shared /tmp: only a private directory of this user may supply executables.
    let attrs = try fm.attributesOfItem(atPath: cache)
    guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
    else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: cache]) }
    let data = Data(text.utf8)
    let cached = cache + "/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let intact = fm.contents(atPath: cached) == data
        && ((try? fm.attributesOfItem(atPath: cached)[.posixPermissions]) as? NSNumber)?.intValue == 0o755
    if !intact {
        let tmp = cached + "." + UUID().uuidString
        try data.write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        _ = rename(tmp, cached)  // atomic; a parallel writer of the same content wins equally
        try? fm.removeItem(atPath: tmp)
    }
    try? fm.removeItem(atPath: path)
    guard link(cached, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
