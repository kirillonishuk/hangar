import Foundation
import Testing
@testable import HangarUI
import Update

@MainActor @Suite struct UpdateModelTests {
    private func feedJSON(_ tag: String) -> Data {
        Data(#"""
        {"tag_name":"\#(tag)","draft":false,"prerelease":false,"body":"notes","assets":[
          {"name":"Hangar-\#(tag.dropFirst()).dmg","browser_download_url":"https://example.com/a.dmg"},
          {"name":"Hangar-\#(tag.dropFirst()).dmg.sha256","browser_download_url":"https://example.com/a.dmg.sha256"}]}
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
        for _ in 0..<200 where model.phase == .checking { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func findsANewerReleaseAndRemembersIt() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        model.start()
        await settle(model)
        #expect(counter.n == 1)
        #expect(model.pill?.version == "0.3.0")
        // Another launch within 24 h: no request, the stored offer still shows.
        let again = UpdateModel(stateDir: model.stateDir, current: "0.2.0", feed: model.feed, bundle: model.bundle)
        again.fetch = { _ in counter.n += 1; return Data() }
        again.start()
        await settle(again)
        #expect(counter.n == 1)
        #expect(again.pill?.version == "0.3.0")
        // Running that version now: nothing to offer.
        let updated = UpdateModel(stateDir: model.stateDir, current: "0.3.0", feed: model.feed, bundle: model.bundle)
        updated.start()
        #expect(updated.offer == nil)
    }

    @Test func checksAgainAfterADay() async throws {
        let (model, counter) = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.stateDir) }
        var now = Date()
        model.now = { now }
        model.checkIfDue()
        await settle(model)
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 1)
        now += UpdateRecord.interval
        model.checkIfDue()
        await settle(model)
        #expect(counter.n == 2)
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
