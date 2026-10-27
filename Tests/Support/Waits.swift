import Foundation

// Shared waits for every test target. All targets run in one test process, where the @MainActor UI suites hold the
// main actor for seconds at a time (a 100 ms sleep was measured resuming after 5-10 s), so wall-clock budgets lie.

/// Polls `cond` until true. The budget counts polls, not wall time: a stalled main actor (or a busy cooperative pool)
/// stretches each sleep but cannot use up the checks, and `polls × every` (60 s by default) is the floor in wall time.
/// Runs on the caller's actor, so `cond` may read main-actor state.
public func waitUntil(polls: Int = 3000, every: Duration = .milliseconds(20), isolation: isolated (any Actor)? = #isolation,
                      _ cond: () async -> Bool) async -> Bool {
    for _ in 0..<polls {
        if await cond() { return true }
        try? await Task.sleep(for: every)
    }
    return await cond()
}

/// Wall-clock budget for blocking waits off the main actor (socket reads, child exits, CLI requests): what they wait
/// for is often answered on the main actor, so it must outlast a stall; generous, a timeout only ever means failure.
public let offMainBound: Double = 60

/// Runs a blocking wait on its own thread. Not the cooperative pool (one thread per core: blocking it stalls every
/// async test) nor GCD's global queue: its ~64 threads fill with other suites' blocking waits and a queued block
/// starts seconds late.
/// A throwing body returns a `Result`.
public func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread { c.resume(returning: body()) }.start() }
}
