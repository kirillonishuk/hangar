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
        D=\(shellQuote(dir))
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
        if [ -f "$D/hang" ]; then exec sleep 600; fi
        [ -n "$master" ] && echo $$ > "$D/master.pid" && echo $$ > "$D/master-$host.pid"
        export HOME="$D/home"
        cd "$HOME" || exit 255
        exec sh -c "$*"
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
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
