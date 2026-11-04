import Darwin

/// Tool shells still running under an agent (spec sub-sessions §6): its direct children that lead their own process group.
/// Claude Code starts every Bash tool command (background ones too) detached, in a group of its own; its MCP servers and
/// `caffeinate` stay in claude's group, so they never count. nil — the pid is gone or not ours.
public func detachedChildren(of pid: Int32) -> Int? {
    guard pid > 1, kill(pid, 0) == 0 else { return nil }
    let own = getpgid(pid)
    guard own > 0 else { return nil }
    var buffer = [pid_t](repeating: 0, count: 512)
    let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    guard bytes >= 0 else { return nil }
    // The call returns a count of pids on macOS (not bytes, despite the header); both are bounded by the buffer.
    let n = min(Int(bytes), buffer.count)
    return buffer.prefix(n).filter { child in
        guard child > 0 else { return false }
        let group = getpgid(child)
        return group == child && group != own
    }.count
}
