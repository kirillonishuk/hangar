import Foundation

/// Per-task `HANGAR_PORT` (decision #60): parallel worktrees run dev servers without clashing (`vite --port $HANGAR_PORT`).
public let taskPortRange = 41000...48999

/// FNV-1a over the id's bytes: stable across launches (Swift's `hashValue` is seeded per process).
func fnv1a(_ id: UUID) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 } }
    return h
}

/// The id's port, or the next one up (wrapping in the range) not in `taken`; `derived` overrides the start (tests).
public func taskPort(for id: UUID, taken: Set<Int> = [], derived: Int? = nil) -> Int {
    let count = taskPortRange.count, low = taskPortRange.lowerBound
    let start = derived ?? low + Int(fnv1a(id) % UInt64(count))
    for step in 0..<count {
        let port = low + (start - low + step) % count
        if !taken.contains(port) { return port }
    }
    return start  // every port taken (8000 tasks): share
}

extension WorkspaceState {
    /// Tasks without a port (new, or from an older state.json) get one unique among all tasks.
    mutating func assignMissingPorts() {
        var taken = Set(tasks.compactMap(\.port))
        for i in tasks.indices where tasks[i].port == nil {
            let port = taskPort(for: tasks[i].id, taken: taken)
            tasks[i].port = port
            taken.insert(port)
        }
    }
}
