import Foundation

/// Stops a child: SIGTERM, then SIGKILL after 2 s to whatever is left (pids are not reused that fast).
/// `group` — the child leads its own process group (Process makes it so), so its helpers die with it.
public func terminateProcess(_ pid: pid_t, group: Bool) {
    let target = group ? -pid : pid
    kill(target, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(target, SIGKILL) }
}
