import Foundation
import Testing
@testable import HangarUI
import Update
import TestSupport

@MainActor @Suite struct UpdateModelTests {
    private func feedJSON(_ tag: String) -> Data {
        Data(#"""
        {"tag_name":"\#(tag)","draft":false,"prerelease":false,"body":"notes","assets":[
          {"name":"Hangar-\#(tag.dropFirst()).dmg","browser_download_url":"https://github.com/o/r/releases/download/v1/a.dmg"},
          {"name":"Hangar-\#(tag.dropFirst()).dmg.sha256","browser_download_url":"https://github.com/o/r/releases/download/v1/a.dmg.sha256"}]}
        """#.utf8)
    }

    private func makeModel(tag: String = "v0.3.0", current: String? = "0.2.0", feed: URL? = URL(string: "file:///feed.json"))
        throws -> (UpdateModel, Counter) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-update-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = UpdateModel(stateDir: dir, current: current, feed: feed, bundle: dir.appendingPathComponent("Hangar.app"))
        let counter = Counter()
        let data = feedJSON(tag)
        model.fetch = { _ in counter.n += 1; return data }
        return (model, counter)
    }

    private func settle(_ model: UpdateModel) async {
        _ = await waitUntil { model.phase != .checking }
    }

    @Test func findsANewerReleaseAndRemembersIt() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.start()
        await settle(model)
        #expect(counter.n == 1)
        #expect(model.pill?.version == "0.3.0")
        // Another launch minutes later checks again; a failed check keeps the stored offer's pill.
        let again = UpdateModel(stateDir: model.stateDir, current: "0.2.0", feed: model.feed, bundle: model.bundle)
        again.fetch = { _ in counter.n += 1; throw UpdateError.http(403) }
        again.start()
        await until { if case .checkFailed = again.phase { true } else { false } }
        #expect(counter.n == 2)
        #expect(again.pill?.version == "0.3.0")
        // Running that version now: nothing to offer.
        let updated = UpdateModel(stateDir: model.stateDir, current: "0.3.0", feed: model.feed, bundle: model.bundle)
        updated.start()
        #expect(updated.offer == nil)
    }

    /// Activation checks at most hourly; a launch always checks (the owner's 0.4.0 missed 0.4.1 for a day).
    @Test func activationChecksHourlyLaunchAlways() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        var now = Date()
        model.now = { now }
        model.checkIfDue()
        await settle(model)
        now += 59 * 60
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 1)
        now += 60
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 2)
        let relaunched = UpdateModel(stateDir: model.stateDir, current: "0.2.0", feed: model.feed, bundle: model.bundle)
        relaunched.now = { now + 60 }
        relaunched.fetch = model.fetch
        relaunched.start()
        await settle(relaunched)
        #expect(counter.n == 3)
    }

    /// Up to date, then a release appears: the next due check shows its pill.
    @Test func aReleaseAfterAnEmptyCheckShowsThePill() async throws {
        let (model, counter) = try makeModel(tag: "v0.2.0")
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        var now = Date()
        model.now = { now }
        model.checkIfDue()
        await settle(model)
        #expect(model.phase == .upToDate && model.pill == nil)
        let newer = feedJSON("v0.3.0")
        model.fetch = { _ in counter.n += 1; return newer }
        now += UpdateRecord.interval
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 2)
        #expect(model.pill?.version == "0.3.0")
    }

    @Test func skippedVersionHidesThePillUntilAManualCheck() async throws {
        let (model, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.checkNow()
        await settle(model)
        model.skip()
        #expect(model.pill == nil)
        #expect(model.offer?.version == "0.3.0")
        model.checkNow()
        await settle(model)
        #expect(model.pill?.version == "0.3.0")
    }

    @Test func offWhenDisabledOrWithoutAFeed() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.enabled = { false }
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 0)
        let (noFeed, c2) = try makeModel(feed: nil)
        defer { try? FileManager.default.removeItem(at: noFeed.stateDir) }
        noFeed.checkNow()
        noFeed.checkIfDue()
        #expect(c2.n == 0)
        let (dev, c3) = try makeModel(current: nil)
        defer { try? FileManager.default.removeItem(at: dev.stateDir) }
        dev.checkNow()
        #expect(c3.n == 0 && dev.feed == nil)
    }

    @Test func olderOrSameReleaseIsUpToDate() async throws {
        let (model, _) = try makeModel(tag: "v0.2.0")
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.checkNow()
        await settle(model)
        #expect(model.phase == .upToDate)
        #expect(model.offer == nil)
    }

    private func until(_ cond: () -> Bool) async { _ = await waitUntil(cond) }

    private let fakeStaged = UpdateModel.Staged(app: URL(fileURLWithPath: "/nonexistent/Hangar.app"),
                                                mount: URL(fileURLWithPath: "/nonexistent/vol"), dir: URL(fileURLWithPath: "/nonexistent/dir"))

    /// Staged → later checks (manual or a day later) neither drop `.ready` nor re-prepare; «Перезапустить» after a
    /// cancelled quit only quits again.
    @Test func readyIsNotDisturbedByChecks() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        var now = Date()
        model.now = { now }
        model.otherInstanceRunning = { false }
        let prepared = Counter(), quits = Counter()
        let staged = fakeStaged
        model.prepare = { _, _ in prepared.n += 1; return .staged(staged) }
        model.quit = { quits.n += 1 }
        model.checkNow()
        await settle(model)
        model.install()
        await until { model.phase == .ready }
        #expect(quits.n == 1 && prepared.n == 1)
        model.checkNow()
        now += 2 * UpdateRecord.interval
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 1)
        #expect(model.phase == .ready)
        #expect(model.staged == staged)
        model.later()
        model.install()  // the quit was cancelled; the sheet's «Перезапустить»
        #expect(quits.n == 2 && prepared.n == 1)
        #expect(model.phase == .ready)
    }

    @Test func aDoubleClickPreparesOnce() async throws {
        let (model, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.otherInstanceRunning = { false }
        let prepared = Counter(), quits = Counter()
        let staged = fakeStaged
        model.prepare = { _, _ in
            prepared.n += 1
            try await Task.sleep(for: .milliseconds(100))
            return .staged(staged)
        }
        model.quit = { quits.n += 1 }
        model.checkNow()
        await settle(model)
        model.install()
        model.install()
        model.checkNow()
        #expect(model.phase == .downloading(nil))
        await until { model.phase == .ready }
        #expect(prepared.n == 1 && quits.n == 1)
    }

    @Test func refusesWhileAnotherCopyRuns() async throws {
        let (model, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        let prepared = Counter()
        model.prepare = { _, _ in prepared.n += 1; return .manual }
        model.otherInstanceRunning = { true }
        model.checkNow()
        await settle(model)
        model.install()
        #expect(model.phase == .otherInstance)
        #expect(prepared.n == 0)
    }

    @Test func aFailedCheckWaitsAnHourToo() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.fetch = { _ in counter.n += 1; throw UpdateError.http(403) }
        model.checkIfDue()
        await until { if case .checkFailed = model.phase { true } else { false } }
        #expect(model.record.lastCheck != nil)
        model.checkIfDue()  // the next activation
        await settle(model)
        #expect(counter.n == 1)
    }

    /// The GitHub feed trusts only GitHub; a DEBUG test feed (any other URL) may serve assets from anywhere.
    @Test func onlyATestFeedTrustsOtherHosts() async throws {
        let json = Data(#"""
        {"tag_name":"v0.3.0","assets":[{"name":"Hangar-0.3.0.dmg","browser_download_url":"file:///tmp/f/Hangar-0.3.0.dmg"},
          {"name":"Hangar-0.3.0.dmg.sha256","browser_download_url":"file:///tmp/f/Hangar-0.3.0.dmg.sha256"}]}
        """#.utf8)
        for (feed, expected) in [(ReleaseFeed.github, nil), (URL(string: "file:///tmp/f/latest.json")!, "0.3.0")] {
            let (model, _) = try makeModel(feed: feed)
            defer { try? FileManager.default.removeItem(at: model.stateDir) }
            model.fetch = { _ in json }
            model.checkNow()
            await settle(model)
            #expect(model.offer?.version == expected)
        }
    }

    @Test func readsAndClearsTheHelpersError() throws {
        let (model, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        try Data("cannot move /x\n".utf8).write(to: model.errorURL)
        model.enabled = { false }
        model.start()
        #expect(model.installError == "cannot move /x")
        #expect(!FileManager.default.fileExists(atPath: model.errorURL.path))
    }
}

@MainActor final class Counter {
    var n = 0
}

/// Settings → General → «Версия» (#99): install from Settings without the status-bar pill.
@MainActor @Suite struct UpdateSettingsButtonTests {
    @Test func buttonFollowsThePhase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-update-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = UpdateModel(stateDir: dir, current: "0.2.0", feed: URL(string: "file:///feed.json"), bundle: dir.appendingPathComponent("Hangar.app"))
        let json = Data(#"""
        {"tag_name":"v0.3.0","assets":[{"name":"Hangar-0.3.0.dmg","browser_download_url":"https://github.com/o/r/releases/download/v1/a.dmg"},
          {"name":"Hangar-0.3.0.dmg.sha256","browser_download_url":"https://github.com/o/r/releases/download/v1/a.dmg.sha256"}]}
        """#.utf8)
        model.fetch = { _ in json }
        #expect(model.settingsButton == nil)  // nothing found yet
        model.checkNow()
        _ = await waitUntil { model.phase != .checking }
        #expect(model.settingsButton == .install("0.3.0"))
        model.skip()
        #expect(model.settingsButton == .install("0.3.0"))  // skipped hides the pill, not the Settings button
        model.otherInstanceRunning = { false }
        let gate = Counter()
        model.prepare = { _, _ in
            _ = await waitUntil { gate.n > 0 }
            return .staged(UpdateModel.Staged(app: dir.appendingPathComponent("New.app"), mount: dir.appendingPathComponent("vol"),
                                              dir: dir.appendingPathComponent("x")))
        }
        let quits = Counter()
        model.quit = { quits.n += 1 }
        model.install()  // the Settings button: the sheet's flow
        #expect(model.settingsButton == .busy)
        gate.n = 1
        _ = await waitUntil { model.phase == .ready }
        #expect(quits.n == 1)
        #expect(model.settingsButton == .restart)  // the quit was cancelled: «Перезапустить»
        let noFeed = UpdateModel(stateDir: dir, current: "0.2.0", feed: nil, bundle: model.bundle)
        #expect(noFeed.settingsButton == nil)
    }
}
