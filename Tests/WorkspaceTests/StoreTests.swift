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
        var tasks: [Task<Void, Never>] = []
        for name in ["1", "2"] {
            store.scheduleSave(sample(name))
            tasks.append(try #require(store.pending))
        }
        let last = sample("3")
        store.scheduleSave(last)
        tasks.append(try #require(store.pending))
        // Every scheduled save has run to its end (cancelled or written): no clock involved.
        for task in tasks { await task.value }
        #expect(writes == 1)
        #expect(store.pending == nil)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected .loaded"); return }
        #expect(loaded == last)
    }

    @Test func incompatibleSchemaIsBackedUp() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("state.json"))
        guard case .recoveredFromCorrupt(let backup) = StateStore(directory: dir).load() else {
            Issue.record("expected .recoveredFromCorrupt"); return
        }
        #expect(try Data(contentsOf: backup) == Data("{}".utf8))
    }

    @Test func saveNowDiscardsPendingSave() async throws {
        let dir = tempDir()
        let store = StateStore(directory: dir, debounce: .milliseconds(50))
        var writes = 0
        store.writeHook = { _ in writes += 1 }
        store.scheduleSave(sample("pending"))
        let final = sample("final")
        try store.saveNow(final)
        try await Task.sleep(for: .milliseconds(200))
        #expect(writes == 1)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected .loaded"); return }
        #expect(loaded == final)
    }

    @Test func olderBackupIsReplaced() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old bak".utf8).write(to: dir.appendingPathComponent("state.json.bak"))
        try Data("{new bad".utf8).write(to: dir.appendingPathComponent("state.json"))
        guard case .recoveredFromCorrupt(let backup) = StateStore(directory: dir).load() else {
            Issue.record("expected .recoveredFromCorrupt"); return
        }
        #expect(try Data(contentsOf: backup) == Data("{new bad".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
    }

    @Test func unreadableFileIsNeverOverwritten() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("state.json")
        try Data("{\"keep\":1}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = StateStore(directory: dir, debounce: .milliseconds(10))
        guard case .unreadable(let url) = store.load() else { Issue.record("expected .unreadable"); return }
        #expect(url == file)
        try store.saveNow(sample())
        store.scheduleSave(sample())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == Data("{\"keep\":1}".utf8))
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int ?? -1) & 0o777
    }

    @Test func newStateDirectoryIs0700() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try StateStore(directory: dir).saveNow(sample())
        #expect(mode(dir) == 0o700)
    }

    @Test func existingOpenStateDirectoryIsTightenedOnlyWhenAsked() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try StateStore(directory: dir).saveNow(sample())  // not the default path: someone else's directory
        #expect(mode(dir) == 0o755)
        ensurePrivateDirectory(dir, tightenExisting: true)
        #expect(mode(dir) == 0o700)
    }

    @Test func intermediateDirectoriesKeepDefaultPermissions() throws {
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("child")
        ensurePrivateDirectory(dir, tightenExisting: false)
        #expect(mode(dir) == 0o700)
        #expect(mode(parent) != 0o700)
    }

    @Test func stricterStateDirectoryIsLeftAlone() throws {
        let dir = tempDir()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        ensurePrivateDirectory(dir, tightenExisting: true)
        #expect(mode(dir) == 0o500)
    }
}
