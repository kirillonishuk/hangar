import Foundation
import Testing
@testable import Update

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(ReleaseFeed.isNewer("0.10.0", than: "0.9.9"))
        #expect(ReleaseFeed.isNewer("v1.0.0", than: "0.99.0"))
        #expect(ReleaseFeed.isNewer("0.2.1", than: "0.2"))
        #expect(!ReleaseFeed.isNewer("0.2.0", than: "0.2.0"))
        #expect(!ReleaseFeed.isNewer("0.1.9", than: "0.2.0"))
        #expect(!ReleaseFeed.isNewer("0.3.0-beta", than: "0.3.0"))
    }

    @Test func rejectsGarbage() {
        #expect(SemVer("") == nil)
        #expect(SemVer("abc") == nil)
        #expect(SemVer("1.2.3.4") == nil)
        #expect(SemVer("1..2") == nil)
        #expect(!ReleaseFeed.isNewer("9.9.9", than: "dev"))
        #expect(SemVer("v0.3.0")?.description == "0.3.0")
    }
}

private func releaseJSON(tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [String]? = nil, body: String = "## What's new\r\n- faster\r\n") -> Data {
    let names = assets ?? ["Hangar-\(tag.dropFirst()).dmg", "Hangar-\(tag.dropFirst()).dmg.sha256", "hangar-demo.mp4"]
    let list = names.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/dl/\#($0)"}"# }.joined(separator: ",")
    let bodyJSON = String(data: try! JSONEncoder().encode(body), encoding: .utf8)!
    return Data(#"""
    {"tag_name":"\#(tag)","name":"Hangar","draft":\#(draft),"prerelease":\#(prerelease),
     "html_url":"https://example.com/releases/\#(tag)","body":\#(bodyJSON),"assets":[\#(list)]}
    """#.utf8)
}

@Suite struct ReleaseFeedTests {
    @Test func parsesTheReleaseAndPicksItsAssets() throws {
        let offer = try #require(try ReleaseFeed.parse(releaseJSON()))
        #expect(offer.version == "0.3.0")
        #expect(offer.dmg.lastPathComponent == "Hangar-0.3.0.dmg")
        #expect(offer.checksum.lastPathComponent == "Hangar-0.3.0.dmg.sha256")
        #expect(offer.notes == "## What's new\n- faster")
        #expect(offer.page?.absoluteString == "https://example.com/releases/v0.3.0")
    }

    @Test func ignoresDraftsPrereleasesAndMissingAssets() throws {
        #expect(try ReleaseFeed.parse(releaseJSON(draft: true)) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(prerelease: true)) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(assets: ["Hangar-0.3.0.dmg"])) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(assets: ["Hangar-0.2.0.dmg", "Hangar-0.2.0.dmg.sha256"])) == nil)
        #expect(try ReleaseFeed.parse(releaseJSON(tag: "nightly")) == nil)
        #expect(throws: (any Error).self) { try ReleaseFeed.parse(Data("{\"message\":\"Not Found\"}".utf8)) }
    }

    @Test func dropsTheInstallSectionAndFormatsLines() {
        let body = "### Install\n\n1. Download **Hangar-0.3.0.dmg**\n2. Drag it\n\n## What's Changed\n* feat: pill by @x in #9\n- fix: y\n\n\n\nTail"
        let notes = ReleaseFeed.trimNotes(body)
        #expect(!notes.contains("Download"))
        #expect(notes.hasPrefix("## What's Changed"))
        let lines = ReleaseFeed.noteLines(notes)
        #expect(lines.map(\.text) == ["What's Changed", "• feat: pill by @x in #9", "• fix: y", "", "Tail"])
        #expect(lines.map(\.heading) == [true, false, false, false, false])
    }

    @Test func cutsLongNotesOnALine() {
        let long = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let notes = ReleaseFeed.trimNotes(long)
        #expect(notes.count <= ReleaseFeed.notesLimit + 2)
        #expect(notes.hasSuffix("\n…"))
        #expect(notes.dropLast(2).hasSuffix("line \(notes.dropLast(2).split(separator: "\n").count)"))
    }
}

@Suite struct UpdateRecordTests {
    @Test func dueEvery24Hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateRecord().checkDue(now: now))
        #expect(!UpdateRecord(lastCheck: now.addingTimeInterval(-3600)).checkDue(now: now))
        #expect(UpdateRecord(lastCheck: now.addingTimeInterval(-UpdateRecord.interval)).checkDue(now: now))
        #expect(UpdateRecord(lastCheck: now.addingTimeInterval(3600)).checkDue(now: now))  // clock moved back
    }

    @Test func roundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = dir.appendingPathComponent("update.json")
        #expect(UpdateRecord.load(from: url) == UpdateRecord())
        let offer = UpdateOffer(version: "0.3.0", notes: "n", dmg: URL(string: "https://e/x.dmg")!, checksum: URL(string: "https://e/x.sha256")!)
        let record = UpdateRecord(lastCheck: Date(timeIntervalSince1970: 1_800_000_000), skipped: "0.2.9", offer: offer)
        try record.save(to: url)
        #expect(UpdateRecord.load(from: url) == record)
        try Data("garbage".utf8).write(to: url)
        #expect(UpdateRecord.load(from: url) == UpdateRecord())
    }
}

@Suite struct ChecksumTests {
    @Test func parsesShasumLines() {
        let hex = String(repeating: "aB", count: 32)
        #expect(Updater.parseChecksum("\(hex)  Hangar-0.3.0.dmg\n") == hex.lowercased())
        #expect(Updater.parseChecksum(hex) == hex.lowercased())
        #expect(Updater.parseChecksum("abc  Hangar.dmg") == nil)
        #expect(Updater.parseChecksum("") == nil)
        #expect(Updater.parseChecksum(String(repeating: "z", count: 64)) == nil)
    }

    @Test func refusesAMismatch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let dmg = dir.appendingPathComponent("Hangar-0.3.0.dmg")
        try Data("image".utf8).write(to: dmg)
        let sum = dir.appendingPathComponent("Hangar-0.3.0.dmg.sha256")
        // shasum -a 256 of "image"
        let good = try Updater.sha256(of: dmg)
        #expect(good == "6105d6cc76af400325e94d588ce511be5bfdbb73b437dc51eca43917d7a43e3d")
        try Data("\(good)  Hangar-0.3.0.dmg\n".utf8).write(to: sum)
        try Updater.verify(dmg, checksumFile: sum)
        try Data("\(String(repeating: "0", count: 64))  Hangar-0.3.0.dmg\n".utf8).write(to: sum)
        #expect(throws: UpdateError.checksumMismatch) { try Updater.verify(dmg, checksumFile: sum) }
        try Data("<html>".utf8).write(to: sum)
        #expect(throws: UpdateError.badChecksumFile) { try Updater.verify(dmg, checksumFile: sum) }
    }

    @Test func downloadsFileURLs() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let src = dir.appendingPathComponent("src.bin")
        try Data(repeating: 7, count: 300_000).write(to: src)
        let dest = dir.appendingPathComponent("out.bin")
        try await Updater.download(src, to: dest) { _ in }
        #expect(FileManager.default.contentsEqual(atPath: src.path, andPath: dest.path))
        await #expect(throws: UpdateError.self) { try await Updater.download(dir.appendingPathComponent("missing"), to: dest) { _ in } }
    }
}

@Suite struct BundleTests {
    @Test func verifiesIdAndVersion() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let app = try fakeApp(in: dir, name: "Hangar.app", version: "0.3.0", marker: "new")
        try Updater.verifyBundle(app, bundleId: "app.hangar.Hangar", version: "0.3.0")
        #expect(throws: UpdateError.wrongVersion("0.3.0")) { try Updater.verifyBundle(app, bundleId: "app.hangar.Hangar", version: "0.4.0") }
        #expect(throws: UpdateError.wrongBundle("app.hangar.Hangar")) { try Updater.verifyBundle(app, bundleId: "com.example.Other", version: "0.3.0") }
        #expect(try Updater.findApp(in: dir).path == app.path)
        #expect(Updater.canReplace(app))
        #expect(!Updater.canReplace(dir))
    }
}

/// The helper script against fake bundles in a temp dir (never a real /Applications).
@Suite struct HelperScriptTests {
    @Test func swapsTheBundleAfterThePidExits() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let target = try fakeApp(in: dir.appendingPathComponent("Apps"), name: "Hangar.app", version: "0.2.0", marker: "old")
        let source = try fakeApp(in: dir.appendingPathComponent("Volume"), name: "Hangar.app", version: "0.3.0", marker: "new")
        _ = try Updater.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Test;", source.path])
        let err = dir.appendingPathComponent("update-error.txt")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        let status = try await runScript(Updater.scriptArguments(pid: sleeper.processIdentifier, source: source, target: target,
                                                                 mount: nil, errorFile: err, relaunch: .none), in: dir)
        #expect(status == 0)
        #expect(!sleeper.isRunning)
        #expect(try marker(target) == "new")
        #expect(NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String == "0.3.0")
        #expect(try Updater.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", target.path]).status != 0)
        #expect(try marker(source) == "new")  // the image is untouched
        let left = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(left == ["Hangar.app"])
        #expect(!FileManager.default.fileExists(atPath: err.path))
    }

    @Test func keepsTheOldBundleWhenTheCopyFails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let target = try fakeApp(in: dir.appendingPathComponent("Apps"), name: "Hangar.app", version: "0.2.0", marker: "old")
        let err = dir.appendingPathComponent("update-error.txt")
        let status = try await runScript(Updater.scriptArguments(pid: 999_999, source: dir.appendingPathComponent("missing.app"), target: target,
                                                                 mount: nil, errorFile: err, relaunch: .none), in: dir)
        #expect(status != 0)
        #expect(try marker(target) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["Hangar.app"])
        #expect(try String(contentsOf: err, encoding: .utf8).contains("cannot copy"))
    }

    @Test func leavesAReadOnlyFolderAlone() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let apps = dir.appendingPathComponent("Apps")
        let target = try fakeApp(in: apps, name: "Hangar.app", version: "0.2.0", marker: "old")
        let source = try fakeApp(in: dir.appendingPathComponent("Volume"), name: "Hangar.app", version: "0.3.0", marker: "new")
        let err = dir.appendingPathComponent("update-error.txt")
        // A read-only folder: the copy next to the target can't be made, nothing is moved.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
        let status = try await runScript(Updater.scriptArguments(pid: 999_999, source: source, target: target,
                                                                 mount: nil, errorFile: err, relaunch: .none), in: dir)
        #expect(status != 0)
        #expect(try marker(target) == "old")
        #expect(FileManager.default.fileExists(atPath: err.path))
        #expect(!Updater.canReplace(target))
    }
}

// MARK: Helpers

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-update-tests-\(UUID().uuidString)/с пробелом")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func fakeApp(in dir: URL, name: String, version: String, marker: String) throws -> URL {
    let app = dir.appendingPathComponent(name)
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: NSDictionary = ["CFBundleIdentifier": "app.hangar.Hangar", "CFBundleShortVersionString": version, "CFBundleExecutable": "Hangar"]
    try info.write(to: contents.appendingPathComponent("Info.plist"))
    try Data(marker.utf8).write(to: contents.appendingPathComponent("MacOS/Hangar"))
    return app
}

func marker(_ app: URL) throws -> String {
    try String(contentsOf: app.appendingPathComponent("Contents/MacOS/Hangar"), encoding: .utf8)
}

/// `/bin/sh <script> args` off the main thread (the script waits for a pid).
func runScript(_ args: [String], in dir: URL) async throws -> Int32 {
    let path = dir.appendingPathComponent("hangar-update.sh")
    try Updater.script.write(to: path, atomically: true, encoding: .utf8)
    return try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try Updater.run("/bin/sh", [path.path] + args).status }) }.start()
    }
}
