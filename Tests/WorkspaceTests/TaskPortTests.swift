import Foundation
import Testing
@testable import Workspace

/// Per-task `HANGAR_PORT` (decision #60): stable, derived from the id, unique among tasks, persisted.
@Suite struct TaskPortTests {
    @Test func derivedIsStableAndInRange() {
        let id = UUID(uuidString: "0B6C4A52-7C1E-4C1A-9A55-3F1A2B3C4D5E")!
        #expect(taskPort(for: id) == taskPort(for: id))
        for _ in 0..<500 { #expect(taskPortRange.contains(taskPort(for: UUID()))) }
        // Fixed hash, not Swift's per-process seeded `hashValue`.
        #expect(taskPort(for: id) == 41000 + Int(fnv1a(id) % 8000))
    }

    @Test func collisionTakesNextFreeAndWraps() {
        let id = UUID()
        let p = taskPort(for: id)
        #expect(taskPort(for: id, taken: [p]) == (p == taskPortRange.upperBound ? taskPortRange.lowerBound : p + 1))
        let next = p == taskPortRange.upperBound ? taskPortRange.lowerBound : p + 1
        #expect(taskPort(for: id, taken: [p, next]) != p && taskPort(for: id, taken: [p, next]) != next)
        #expect(taskPort(for: id, taken: [taskPortRange.upperBound], derived: taskPortRange.upperBound) == taskPortRange.lowerBound)
    }

    @Test func addTaskPersistsUniquePorts() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        let ids = (0..<300).map { s.addTask(projectId: p, name: "t\($0)") }
        let ports = ids.compactMap { id in s.tasks.first { $0.id == id }?.port }
        #expect(ports.count == 300 && Set(ports).count == 300)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == s)
    }

    /// state.json from before ports: each task gets one on load, unique, kept from then on.
    @Test func olderStateGetsPorts() throws {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        for i in 0..<3 { _ = s.addTask(projectId: p, name: "t\(i)") }
        for i in s.tasks.indices { s.tasks[i].port = nil }
        let loaded = try JSONDecoder().decode(WorkspaceState.self, from: try JSONEncoder().encode(s))
        let ports = loaded.tasks.compactMap(\.port)
        #expect(ports.count == 3 && Set(ports).count == 3)
        #expect(loaded.tasks[0].port == taskPort(for: loaded.tasks[0].id))
    }
}
