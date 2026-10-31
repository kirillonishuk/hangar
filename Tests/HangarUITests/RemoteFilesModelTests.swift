import Exec
import Foundation
import Testing
@testable import HangarUI
import TestSupport

/// The inspector's Files of a host terminal (#124) on stub listing/upload: what loads when, offline, conflicts, close.
@MainActor @Suite struct RemoteFilesModelTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _lists: [String] = []
        private var _uploads: [(name: String, dir: String, replace: Bool)] = []
        var lists: [String] { lock.lock(); defer { lock.unlock() }; return _lists }
        var uploads: [(name: String, dir: String, replace: Bool)] { lock.lock(); defer { lock.unlock() }; return _uploads }
        func list(_ p: String) { lock.lock(); _lists.append(p); lock.unlock() }
        func upload(_ n: String, _ d: String, _ r: Bool) { lock.lock(); _uploads.append((n, d, r)); lock.unlock() }
    }

    let leaf = UUID()
    let link = RemoteShellLink(host: "box", controlPath: "/tmp/hs-test", sshPath: "/usr/bin/false")

    private func model(_ calls: Calls, entries: [String] = ["a.txt"], hang: Bool = false) -> RemoteFilesModel {
        let m = RemoteFilesModel()
        m.debounce = .zero
        m.isUp = { _ in true }
        m.stopMaster = { _ in }
        m.removeLeftover = { _, dir, name in calls.list("leftover " + dir + "/" + name) }
        m.lister = { _, path in
            calls.list(path)
            return RemoteListing(entries: entries.map { RemoteEntry(name: $0, kind: .file) })
        }
        m.uploader = { _, source, dir, replace, progress in
            calls.upload(source.name, dir, replace)
            if hang { try await Task.sleep(nanoseconds: 120_000_000_000) }
            progress(source.bytes)
        }
        m.register(leaf, link: link)
        return m
    }

    private func files(_ names: [String]) throws -> (dir: String, urls: [URL]) {
        let dir = NSTemporaryDirectory() + "rfm " + UUID().uuidString.prefix(6) + "-тест"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let urls = try names.map { n -> URL in
            let u = URL(fileURLWithPath: dir + "/" + n)
            try Data("x".utf8).write(to: u)
            return u
        }
        return (dir, urls)
    }

    @Test func loadsOnlyWhileShownAndOnEveryPrompt() async throws {
        let calls = Calls()
        let m = model(calls)
        m.pwd(leaf, "/srv")
        #expect(calls.lists.isEmpty)  // not shown: only remembered
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        #expect(calls.lists == ["/srv"] && m.listedPath == "/srv" && m.cwdKnown)
        m.pwd(leaf, "/srv")  // the same folder after a command: listed again
        #expect(await waitUntil { calls.lists.count == 2 })
        m.pwd(leaf, "/etc")
        #expect(await waitUntil { m.listedPath == "/etc" })
        // Untrusted text and unknown leaves change nothing.
        m.pwd(leaf, "relative")
        m.pwd(leaf, "/x\u{7}y")
        m.pwd(UUID(), "/root")
        #expect(m.path == "/etc")
        m.follow(nil)
        m.pwd(leaf, "/tmp")
        #expect(calls.lists.count == 3)
    }

    /// The inspector asks before the leaf's surface has launched (restore, a new tab): it follows once registered.
    @Test func followsALeafLaunchedLater() async throws {
        let calls = Calls()
        let m = model(calls)
        let later = UUID()
        m.follow(later)
        #expect(m.shown == nil)
        m.register(later, link: link)
        #expect(m.shown?.leaf == later)
    }

    @Test func unknownFolderIsTheHome() async throws {
        let calls = Calls()
        let m = model(calls)
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        #expect(calls.lists == [RemoteFilesModel.home] && !m.cwdKnown)
        #expect(RemoteFilesModel.display(RemoteFilesModel.home) == "~" && RemoteFilesModel.display("./x") == "~/x")
    }

    @Test func offlineKeepsTheLastListing() async throws {
        let calls = Calls()
        let m = model(calls)
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        m.isUp = { _ in false }
        m.reload()
        #expect(m.offline && m.listing != nil && !m.canUpload)
        m.isUp = { _ in true }
        m.titleChanged(leaf)  // logged in again
        #expect(await waitUntil { !m.offline })
    }

    @Test func conflictAskedOnceForAll() async throws {
        let calls = Calls()
        let m = model(calls, entries: ["a.txt", "b.txt"])
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, urls) = try files(["a.txt", "b.txt", "c.txt"])
        m.upload(urls)
        #expect(await waitUntil { m.conflict != nil })
        #expect(m.conflict?.name == "a.txt" && m.conflict?.more == 1)
        m.answer(replace: true, forAll: true)
        #expect(await waitUntil { m.upload == nil && calls.uploads.count == 3 })
        #expect(calls.uploads.map(\.replace) == [true, true, false])
        #expect(m.batchDone == 3 && m.uploadErrors.isEmpty)
    }

    @Test func skipAndEscape() async throws {
        let calls = Calls()
        let m = model(calls, entries: ["a.txt", "b.txt"])
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, urls) = try files(["a.txt", "b.txt", "c.txt"])
        m.upload(urls)
        #expect(await waitUntil { m.conflict?.name == "a.txt" })
        m.answer(replace: false, forAll: false)  // skip a.txt only
        #expect(await waitUntil { m.conflict?.name == "b.txt" })
        m.answer(replace: nil, forAll: false)  // Esc: the rest of the batch stops
        #expect(await waitUntil { m.upload == nil && m.conflict == nil })
        #expect(calls.uploads.isEmpty)
    }

    @Test func nameTakenMeanwhileIsAsked() async throws {
        let calls = Calls()
        let m = model(calls, entries: [])
        var first = true
        m.uploader = { _, source, dir, replace, _ in
            calls.upload(source.name, dir, replace)
            if await MainActor.run(body: { let f = first; first = false; return f }) { throw RemoteFileError.exists(source.name) }
        }
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, urls) = try files(["a.txt"])
        m.upload(urls)
        #expect(await waitUntil { m.conflict != nil })
        m.answer(replace: true, forAll: false)
        #expect(await waitUntil { m.upload == nil && calls.uploads.count == 2 })
        #expect(calls.uploads.map(\.replace) == [false, true])
    }

    /// Closing the tab: its upload stops at once (nothing waits on the master), the master is told to exit.
    @Test func closingTheLeafStopsItsUploadAndMaster() async throws {
        let calls = Calls()
        let m = model(calls, entries: [], hang: true)
        var stopped: [RemoteShellLink] = []
        m.stopMaster = { stopped.append($0) }
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, urls) = try files(["big.bin"])
        m.upload(urls)
        #expect(await waitUntil { m.upload?.waiting == false })
        m.retain([])
        #expect(await waitUntil { m.upload == nil })
        #expect(stopped == [link] && m.shown == nil && m.uploadErrors.isEmpty)
        #expect(calls.lists.contains("leftover /srv/big.bin"))
        #expect(m.link(of: leaf) == nil)
    }

    @Test func aDropDuringAnUploadIsTheNextBatch() async throws {
        let calls = Calls()
        let m = model(calls, entries: ["a.txt"])
        m.pwd(leaf, "/srv")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, first) = try files(["a.txt"])
        let (_, second) = try files(["b.txt"])
        m.upload(first)
        #expect(await waitUntil { m.conflict != nil })
        m.upload(second, into: "/srv/public")
        m.answer(replace: false, forAll: false)
        #expect(await waitUntil { m.upload == nil && calls.uploads.count == 1 })
        #expect(calls.uploads.first?.name == "b.txt" && calls.uploads.first?.dir == "/srv/public")
    }

    @Test func failuresStayWithTheirLeaf() async throws {
        let calls = Calls()
        let m = model(calls, entries: [])
        m.uploader = { _, _, dir, _, _ in throw RemoteFileError.noAccess(dir) }
        m.pwd(leaf, "/etc")
        m.follow(leaf)
        #expect(await waitUntil { m.listing != nil })
        let (_, urls) = try files(["a.txt"])
        m.upload(urls)
        #expect(await waitUntil { m.uploadErrors.count == 1 && m.upload == nil })
        let other = UUID()
        m.register(other, link: link)
        m.follow(other)
        #expect(m.uploadErrors.isEmpty)
    }

    @Test func errorsReadAsWhatToDo() {
        #expect(RemoteFilesModel.message(RemoteFileError.noAccess("/etc"), name: "x") == L10n.uploadNoAccess("x", "/etc"))
        #expect(RemoteFilesModel.message(RemoteFileError.offline, name: "x") == L10n.uploadOffline("x"))
        #expect(RemoteFilesModel.message(RemoteFileError.incomplete("x"), name: "x") == L10n.uploadIncomplete("x"))
    }
}
