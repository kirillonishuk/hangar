import Testing
@testable import Power

/// Records every IOPM call; `create` hands out ids 1, 2, … unless `failCreate`.
@MainActor final class FakeAssertions {
    var created: [String] = []
    var renamed: [(UInt32, String)] = []
    var released: [UInt32] = []
    var failCreate = false
    var failRename = false
    private var next: UInt32 = 0

    var assertions: PowerAssertions {
        PowerAssertions(
            create: { name in MainActor.assumeIsolated {
                self.created.append(name)
                if self.failCreate { return nil }
                self.next += 1
                return self.next
            } },
            rename: { id, name in MainActor.assumeIsolated {
                self.renamed.append((id, name))
                return !self.failRename
            } },
            release: { id in MainActor.assumeIsolated { self.released.append(id) } })
    }
}

/// Manual scheduler: stores bodies, counts cancels.
@MainActor final class ManualSchedule {
    var delays: [Duration] = []
    var bodies: [@MainActor () -> Void] = []
    var cancels = 0

    func schedule(_ d: Duration, _ body: @escaping @MainActor () -> Void) -> () -> Void {
        delays.append(d)
        bodies.append(body)
        return { MainActor.assumeIsolated { self.cancels += 1 } }
    }
}

@MainActor @Suite struct KeepAwakeTests {
    private func make() -> (KeepAwake, FakeAssertions, ManualSchedule) {
        let fake = FakeAssertions(), sched = ManualSchedule()
        let k = KeepAwake(assertions: fake.assertions, schedule: sched.schedule)
        return (k, fake, sched)
    }

    @Test func holdsWhileWorking() {
        let (k, fake, _) = make()
        k.update(working: 1, enabled: true)
        #expect(fake.created == ["Hangar: 1 agent working"])
        #expect(k.held && k.working == 1)
        k.update(working: 3, enabled: true)
        #expect(fake.renamed.count == 1 && fake.renamed[0].0 == 1 && fake.renamed[0].1 == "Hangar: 3 agents working")
        #expect(fake.created.count == 1)
        k.update(working: 3, enabled: true)
        #expect(fake.renamed.count == 1)
    }

    @Test func releaseAfterGrace() {
        let (k, fake, sched) = make()
        k.update(working: 1, enabled: true)
        k.update(working: 0, enabled: true)
        #expect(k.held)
        #expect(sched.delays == [.seconds(120)])
        // pmset shows the grace for what it is, not «1 agent working».
        #expect(fake.renamed.map(\.1) == ["Hangar: agents finished, keeping awake briefly"])
        sched.bodies[0]()
        #expect(fake.released == [1])
        #expect(!k.held)
        k.update(working: 0, enabled: true)
        #expect(sched.delays.count == 1)
    }

    @Test func noTimerWhenIdle() {
        let (k, fake, sched) = make()
        k.update(working: 0, enabled: true)
        #expect(fake.created.isEmpty && sched.delays.isEmpty)
    }

    @Test func zeroTwiceArmsOneTimer() {
        let (k, _, sched) = make()
        k.update(working: 1, enabled: true)
        k.update(working: 0, enabled: true)
        k.update(working: 0, enabled: true)
        #expect(sched.delays.count == 1)
    }

    @Test func flapWithinGraceKeepsOneAssertion() {
        let (k, fake, sched) = make()
        k.update(working: 1, enabled: true)
        k.update(working: 0, enabled: true)
        k.update(working: 1, enabled: true)
        #expect(fake.created.count == 1 && fake.released.isEmpty)
        #expect(sched.cancels == 1)
        #expect(fake.renamed.map(\.1) == ["Hangar: agents finished, keeping awake briefly", "Hangar: 1 agent working"])
    }

    @Test func staleTimerIgnored() {
        let (k, fake, sched) = make()
        k.update(working: 1, enabled: true)
        k.update(working: 0, enabled: true)
        k.update(working: 1, enabled: true)
        k.update(working: 0, enabled: true)
        #expect(sched.bodies.count == 2)
        sched.bodies[0]()
        #expect(fake.released.isEmpty && k.held)
        sched.bodies[1]()
        #expect(fake.released == [1] && !k.held)
    }

    @Test func disableReleasesImmediately() {
        let (k, fake, sched) = make()
        k.update(working: 2, enabled: true)
        k.update(working: 0, enabled: true)
        k.update(working: 2, enabled: false)
        #expect(fake.released == [1] && !k.held)
        #expect(sched.cancels == 1)
        k.update(working: 2, enabled: true)
        #expect(fake.created.count == 2 && k.held)
    }

    @Test func stopReleases() {
        let (k, fake, _) = make()
        k.update(working: 1, enabled: true)
        k.stop()
        #expect(fake.released == [1] && !k.held)
        k.update(working: 1, enabled: true)
        k.update(working: 2, enabled: true)
        #expect(fake.created.count == 1)
    }

    @Test func createFailureRetries() {
        let (k, fake, sched) = make()
        fake.failCreate = true
        k.update(working: 1, enabled: true)
        #expect(!k.held)
        k.update(working: 1, enabled: true)
        #expect(fake.created.count == 1)
        k.update(working: 2, enabled: true)
        #expect(fake.created.count == 2)
        k.update(working: 0, enabled: true)
        #expect(sched.delays.isEmpty)
    }

    @Test func renameFallbackRecreates() {
        let (k, fake, _) = make()
        k.update(working: 1, enabled: true)
        fake.failRename = true
        k.update(working: 2, enabled: true)
        #expect(fake.created == ["Hangar: 1 agent working", "Hangar: 2 agents working"])
        #expect(fake.released == [1])
        #expect(k.held)
        k.stop()
        #expect(fake.released == [1, 2])
    }

    @Test func taskScheduleRunsAndCancels() async {
        var ran = 0
        _ = KeepAwake.taskSchedule(.milliseconds(1)) { ran += 1 }
        let cancel = KeepAwake.taskSchedule(.seconds(60)) { ran += 100 }
        cancel()
        for _ in 0..<200 where ran == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(ran == 1)
    }
}
