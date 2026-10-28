import Exec
import Foundation
import Testing
@testable import HangarUI

/// Open / save / external change of the editor's files, local and through the host runner (#80).
@MainActor @Suite struct EditorSessionTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-ed-\(UUID())").path

    init() throws { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

    private final class Sink { var sent: [EditorCommand] = [] }

    private func session(_ io: EditorIO = .local, limits: EditorLimits = EditorLimits()) -> (EditorSession, Sink) {
        let sink = Sink()
        return (EditorSession(io: io, limits: limits) { sink.sent.append($0) }, sink)
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let path = dir + "/" + name
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        return path
    }

    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// Moves the file's mtime so a same-second rewrite still counts as a change.
    private func touch(_ path: String, _ offset: TimeInterval = 5) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: path)
    }

    private func opened(_ sink: Sink) -> [EditorOpen] {
        sink.sent.compactMap { if case .open(let o) = $0 { o } else { nil } }
    }

    @Test func opensTextAtLine() async throws {
        let path = try write("App.tsx", "const a = 1\n")
        let (s, sink) = session()
        await s.open(path: path, line: 4, column: 2)
        let o = try #require(opened(sink).first)
        #expect(o.text == "const a = 1\n")
        #expect(!o.readOnly && o.notice == nil)
        #expect(o.line == 4 && o.column == 2)
        // Again: only focused at the new line, not loaded twice.
        await s.open(path: path, line: 9, column: nil)
        #expect(opened(sink).count == 1)
        #expect(sink.sent.last == .activate(path: path, line: 9, column: 1))
    }

    @Test func largeIsReadOnlyHugeAndBinaryAreRefused() async throws {
        let limits = EditorLimits(editable: 10, refuse: 20)
        let mid = try write("mid.txt", String(repeating: "a", count: 15))
        let huge = try write("huge.txt", String(repeating: "a", count: 25))
        let bin = dir + "/b.bin"
        try Data([0x7f, 0x45, 0x00, 0x01]).write(to: URL(fileURLWithPath: bin))
        let (s, sink) = session(limits: limits)
        for p in [mid, huge, bin] { await s.open(path: p, line: nil, column: nil) }
        let o = opened(sink)
        #expect(o[0].readOnly && o[0].text?.count == 15 && o[0].notice != nil)
        #expect(o[1].text == nil && o[1].notice != nil)
        #expect(o[2].text == nil && o[2].notice != nil)
        #expect(s.isReadOnly(mid))
    }

    /// Go to definition into node_modules (#82): shown read-only; editable TS goes on to the language server.
    @Test func dependenciesOpenReadOnlyAndTextGoesToTheLanguageServer() async throws {
        try FileManager.default.createDirectory(atPath: dir + "/node_modules/lib", withIntermediateDirectories: true)
        let dep = try write("node_modules/lib/index.d.ts", "export declare const x: 1;\n")
        let own = try write("a.ts", "let a = 1\n")
        let (s, sink) = session()
        var handed: [String] = []
        s.onOpened = { path, _ in handed.append(path) }
        await s.open(path: dep, line: nil, column: nil)
        await s.open(path: own, line: nil, column: nil)
        let o = opened(sink)
        #expect(o[0].readOnly && o[0].notice == L10n.editorDependencyReadOnly)
        #expect(!o[1].readOnly && o[1].notice == nil)
        #expect(s.isReadOnly(dep) && !s.isReadOnly(own))
        #expect(handed == [dep, own])
    }

    @Test func savesAtomicallyKeepingMode() async throws {
        let path = try write("run.sh", "echo a\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let (s, sink) = session()
        await s.open(path: path, line: nil, column: nil)
        await s.handle(.changed(file: path, dirty: true))
        #expect(s.isDirty(path))
        await s.handle(.save(file: path, text: "echo b\n"))
        #expect(read(path) == "echo b\n")
        #expect(sink.sent.last == .saved(path: path))
        #expect(!s.isDirty(path))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["run.sh"])  // no temp file left
    }

    @Test func cleanBufferReloadsSilently() async throws {
        let path = try write("a.txt", "one\n")
        let (s, sink) = session()
        await s.open(path: path, line: nil, column: nil)
        try "two\n".write(toFile: path, atomically: false, encoding: .utf8)
        try touch(path)
        await s.checkDisk()
        #expect(sink.sent.last == .reload(path: path, text: "two\n"))
        await s.checkDisk()  // nothing new
        #expect(sink.sent.filter { if case .reload = $0 { true } else { false } }.count == 1)
    }

    /// An editor pane moving to the other Monaco page (splits) takes its unsaved buffer along: still dirty there.
    @Test func adoptKeepsDirtyBuffer() async throws {
        let path = try write("moved.txt", "disk\n")
        let stamp = try #require(try await EditorIO.local.stat(path))
        let (s, sink) = session()
        var dirtied: [Bool] = []
        s.onDirty = { _, d in dirtied.append(d) }
        s.adopt(path: path, text: "edited", file: EditorSession.File(stamp: stamp, dirty: true), line: 3, column: 2)
        #expect(s.isDirty(path))
        #expect(dirtied == [true])  // the tab's dot / close prompt see the adopted buffer as unsaved
        let o = try #require(opened(sink).first)
        #expect(o.text == "edited" && o.dirty && !o.readOnly)
        #expect(o.line == 3 && o.column == 2)
        // It saves like any open file.
        await s.handle(.save(file: path, text: "edited"))
        #expect(read(path) == "edited" && !s.isDirty(path))
    }

    /// A save that finished while the pane moved gives its stamp, but the carried buffer stays unsaved: text typed on
    /// the old page during the move must never be adopted as clean.
    @Test func carriedFileKeepsDirtyTakesLatestStamp() {
        let old = FileStamp(size: 1, mtime: 1), saved = FileStamp(size: 2, mtime: 2)
        let moved = EditorSession.File(stamp: old, dirty: true)
        let latest = EditorSession.File(stamp: saved, dirty: false, conflict: true)
        let file = EditorSession.File.carried(moved, latest: latest)
        #expect(file.dirty && file.stamp == saved && file.conflict)
        #expect(EditorSession.File.carried(moved, latest: nil).stamp == old)
    }

    /// The same file open in two panes (two sessions): the second save of a stale buffer asks, it doesn't overwrite.
    @Test func secondSessionSaveOfSameFileConflicts() async throws {
        let path = try write("both.txt", "start\n")
        let (a, _) = session()
        let (b, sinkB) = session()
        await a.open(path: path, line: nil, column: nil)
        await b.open(path: path, line: nil, column: nil)
        await a.handle(.changed(file: path, dirty: true))
        await b.handle(.changed(file: path, dirty: true))
        await a.handle(.save(file: path, text: "a"))
        await b.handle(.save(file: path, text: "b"))
        #expect(sinkB.sent.last == .conflict(path: path, shown: true))
        #expect(b.files[path]?.conflict == true)
        #expect(read(path) == "a")
    }

    @Test func dirtyBufferGetsConflictBar() async throws {
        let path = try write("a.txt", "one\n")
        let (s, sink) = session()
        await s.open(path: path, line: nil, column: nil)
        await s.handle(.changed(file: path, dirty: true))
        try "theirs\n".write(toFile: path, atomically: false, encoding: .utf8)
        try touch(path)
        await s.checkDisk()
        #expect(sink.sent.last == .conflict(path: path, shown: true))
        // Saving over it is refused while the bar is up.
        await s.handle(.save(file: path, text: "mine\n"))
        #expect(read(path) == "theirs\n")
        // «Оставить мой»: the bar goes, the next save overwrites.
        await s.handle(.conflict(file: path, keepMine: true))
        #expect(sink.sent.last == .conflict(path: path, shown: false))
        await s.handle(.save(file: path, text: "mine\n"))
        #expect(read(path) == "mine\n")
    }

    @Test func conflictReloadTakesDisk() async throws {
        let path = try write("a.txt", "one\n")
        let (s, sink) = session()
        await s.open(path: path, line: nil, column: nil)
        await s.handle(.changed(file: path, dirty: true))
        try "theirs\n".write(toFile: path, atomically: false, encoding: .utf8)
        try touch(path)
        // Saving finds the change on disk itself (no watcher event yet).
        await s.handle(.save(file: path, text: "mine\n"))
        #expect(read(path) == "theirs\n")
        #expect(sink.sent.last == .conflict(path: path, shown: true))
        await s.handle(.conflict(file: path, keepMine: false))
        #expect(sink.sent.suffix(2) == [.conflict(path: path, shown: false), .reload(path: path, text: "theirs\n")])
        #expect(!s.isDirty(path))
    }

    @Test func unknownFilesAndReadOnlySavesAreIgnored() async throws {
        let path = try write("mid.txt", String(repeating: "a", count: 15))
        let (s, sink) = session(limits: EditorLimits(editable: 10, refuse: 20))
        await s.handle(.save(file: "/etc/hosts", text: "x"))
        #expect(sink.sent.isEmpty)
        await s.open(path: path, line: nil, column: nil)
        await s.handle(.save(file: path, text: "b"))
        #expect(read(path) == String(repeating: "a", count: 15))
    }

    @Test func remoteReadWriteThroughFakeSSH() async throws {
        let fake = try FakeSSH.make(dir: dir + "/ssh")
        let control = dir + "/cm"
        let io = EditorIO.remote(runner: .ssh(host: "dev", controlPath: control, sshPath: fake.path)) { script, args, input in
            try await sshWrite(host: "dev", controlPath: control, sshPath: fake.path, script: script, args: args, input: input)
        }
        let folder = dir + "/it's a dir"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/$(touch pwned) \"q\".ts"
        try "let a = 'é'\n".write(toFile: path, atomically: false, encoding: .utf8)
        let (s, sink) = session(io)
        await s.open(path: path, line: nil, column: nil)
        #expect(opened(sink).first?.text == "let a = 'é'\n")
        await s.handle(.save(file: path, text: "let b = \"ü\"\n"))
        #expect(read(path) == "let b = \"ü\"\n")
        #expect(sink.sent.last == .saved(path: path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == [(path as NSString).lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: dir + "/ssh/home/pwned"))
        // Changed on the server: a clean buffer reloads on the next check (focus).
        try "remote edit\n".write(toFile: path, atomically: false, encoding: .utf8)
        try touch(path)
        await s.checkDisk()
        #expect(sink.sent.last == .reload(path: path, text: "remote edit\n"))
    }

    /// The diff's working side: read without a page `open`, then saved and watched like an editor file.
    @Test func adoptedFileSavesAndConflicts() async throws {
        let path = try write("w.txt", "base\n")
        let (s, sink) = session()
        let opened = try #require(await s.adopt(path: path))
        #expect(opened.text == "base\n" && !opened.readOnly)
        #expect(sink.sent.isEmpty)
        await s.handle(.save(file: path, text: "edited\n"))
        #expect(read(path) == "edited\n")
        await s.handle(.changed(file: path, dirty: true))
        try "agent\n".write(toFile: path, atomically: false, encoding: .utf8)
        try touch(path)
        await s.checkDisk()
        #expect(sink.sent.last == .conflict(path: path, shown: true))
        #expect(await s.adopt(path: dir + "/missing.txt") == nil)
    }

    @Test func diskChangeRules() {
        let a = FileStamp(size: 1, mtime: 1), b = FileStamp(size: 2, mtime: 1)
        #expect(diskChange(loaded: a, current: a, dirty: true) == .none)
        #expect(diskChange(loaded: a, current: b, dirty: false) == .reload)
        #expect(diskChange(loaded: a, current: b, dirty: true) == .conflict)
        #expect(diskChange(loaded: a, current: nil, dirty: false) == .none)  // deleted: the buffer stays
    }

    /// A tab shown while its file still loads (#83): the disk check must not "reload" it on top of the load — that
    /// reload arrived as an edit and left a clean buffer dirty.
    @Test func diskCheckSkipsAFileStillLoading() async throws {
        let path = try write("slow.ts", "a\n")
        let gate = Gate()
        var io = EditorIO.local
        let read = io.read
        io.read = { p, max in await gate.wait(); return try await read(p, max) }
        let (s, sink) = session(io)
        let open = Task { await s.open(path: path, line: nil, column: nil) }
        await Task.yield()
        let check = Task { await s.checkDisk() }
        for _ in 0..<20 { await Task.yield() }  // the check gets as far as it can while the file loads
        await gate.open()
        await open.value
        await check.value
        #expect(sink.sent.filter { if case .reload = $0 { true } else { false } }.isEmpty)
        #expect(opened(sink).count == 1 && !s.isDirty(path))
    }

    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async { if !isOpen { await withCheckedContinuation { waiting.append($0) } } }
        func open() { isOpen = true; waiting.forEach { $0.resume() }; waiting = [] }
    }
}
