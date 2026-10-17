import Foundation
import Testing
@testable import Workspace

@MainActor @Suite struct StoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hangar-store-\(UUID().uuidString)")
    }

    private func sample(_ name: String = "a") -> WorkspaceState {
        var s = WorkspaceState()
        let p = s.addProject(name: "app", path: "/repo/app")
        _ = s.addTask(projectId: p, name: name)
        return s
    }

    private struct Boom: Error {}

    @Test func missingFileLoadsEmpty() {
        let store = StateStore(directory: tempDir())
        guard case .empty = store.load() else { Issue.record("expected .empty"); return }
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = tempDir()
        let state = sample()
        try StateStore(directory: dir).saveNow(state)
        guard case .loaded(let loaded) = StateStore(directory: dir).load() else {
            Issue.record("expected .loaded"); return
        }
        #expect(loaded == state)
    }

    @Test func saveIsAtomic() throws {
        let dir = tempDir()
        let store = StateStore(directory: dir)
        let old = sample("old")
        try store.saveNow(old)
        try store.saveNow(sample("new"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
        let data = try Data(contentsOf: dir.appendingPathComponent("state.json"))
        _ = try JSONDecoder().decode(WorkspaceState.self, from: data)

        // Encoding failure leaves the previous file untouched.
        let before = data
        store.encode = { _ in throw Boom() }
        #expect(throws: Boom.self) { try store.saveNow(sample("third")) }
        #expect(try Data(contentsOf: dir.appendingPathComponent("state.json")) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["state.json"])
    }

    @Test func corruptFileIsBackedUp() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("state.json")
        try Data("{not json".utf8).write(to: file)
        let store = StateStore(directory: dir)
        guard case .recoveredFromCorrupt(let backup) = store.load() else {
            Issue.record("expected .recoveredFromCorrupt"); return
        }
        #expect(backup.lastPathComponent == "state.json.bak")
        #expect(try Data(contentsOf: backup) == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try store.saveNow(sample())
        guard case .loaded = store.load() else { Issue.record("expected .loaded"); return }
    }

    @Test func debouncedSavesCoalesce() async throws {
        let dir = tempDir()
        let store = StateStore(directory: dir, debounce: .milliseconds(50))
        var writes = 0
        store.writeHook = { _ in writes += 1 }
        store.scheduleSave(sample("1"))
        store.scheduleSave(sample("2"))
        let last = sample("3")
        store.scheduleSave(last)
        try await Task.sleep(for: .milliseconds(200))
        #expect(writes == 1)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected .loaded"); return }
        #expect(loaded == last)
    }
}
