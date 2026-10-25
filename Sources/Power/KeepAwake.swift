import Foundation
import IOKit.pwr_mgt
import Observation
import os

let powerLog = Logger(subsystem: "dev.hangar", category: "Power")

/// The three IOPM calls, swappable in tests.
public struct PowerAssertions: Sendable {
    public var create: @Sendable (String) -> UInt32?
    public var rename: @Sendable (UInt32, String) -> Bool
    public var release: @Sendable (UInt32) -> Void

    public init(create: @escaping @Sendable (String) -> UInt32?, rename: @escaping @Sendable (UInt32, String) -> Bool,
                release: @escaping @Sendable (UInt32) -> Void) {
        self.create = create
        self.rename = rename
        self.release = release
    }

    /// `PreventUserIdleSystemSleep`: the display may still sleep.
    public static let system = PowerAssertions(
        create: { name in
            var id = IOPMAssertionID(0)
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            return r == kIOReturnSuccess ? id : nil
        },
        rename: { id, name in IOPMAssertionSetProperty(id, kIOPMAssertionNameKey as CFString, name as CFString) == kIOReturnSuccess },
        release: { id in _ = IOPMAssertionRelease(id) })
}

/// Holds a sleep assertion while agents work; drops it `grace` after the last one stops (spec §5.2).
/// The grace timer is the only timer and exists only between "working became 0" and its firing.
@MainActor @Observable public final class KeepAwake {
    public private(set) var held = false
    public private(set) var working = 0

    @ObservationIgnored private let assertions: PowerAssertions
    @ObservationIgnored private let grace: Duration
    @ObservationIgnored private let schedule: (Duration, @escaping @MainActor () -> Void) -> (() -> Void)
    @ObservationIgnored private var id: UInt32?
    /// Count in the assertion's current name.
    @ObservationIgnored private var namedCount = 0
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var cancelPending: (() -> Void)?
    /// Bumped on every cancel so a timer body that already fired (or wasn't cancelled in time) does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopped = false

    public init(assertions: PowerAssertions = .system, grace: Duration = .seconds(120),
                schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = KeepAwake.taskSchedule) {
        self.assertions = assertions
        self.grace = grace
        self.schedule = schedule
    }

    /// Shown by `pmset -g assertions`; fixed English, since pmset can't show Cyrillic (decision #46).
    /// 0: the grace after the last agent stopped.
    static func name(_ n: Int) -> String {
        n == 0 ? "Hangar: agents finished, keeping awake briefly" : n == 1 ? "Hangar: 1 agent working" : "Hangar: \(n) agents working"
    }

    nonisolated public static func taskSchedule(_ delay: Duration, _ body: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { body() }
        }
        return { task.cancel() }
    }

    public func update(working n: Int, enabled on: Bool) {
        guard !stopped else { return }
        if n != working || on != enabled { powerLog.info("keep-awake working=\(n) enabled=\(on) held=\(self.held)") }
        // A failed create is retried only when the count or the setting changes, not on every status tick.
        let retry = n != working || !enabled
        if working != n { working = n }  // status ticks with an unchanged count don't redraw observers
        enabled = on
        guard on else { releaseNow(); return }
        if n > 0 {
            cancelGrace()
            if let old = id {
                guard n != namedCount else { return }
                if assertions.rename(old, Self.name(n)) {
                    namedCount = n
                } else if let new = assertions.create(Self.name(n)) {
                    // Create before release so the Mac is never unguarded in between.
                    assertions.release(old)
                    id = new
                    namedCount = n
                }
            } else if retry {
                id = assertions.create(Self.name(n))
                powerLog.info("keep-awake created \(self.id.map(String.init) ?? "nil", privacy: .public)")
                namedCount = n
                held = id != nil
            }
        } else if let old = id, cancelPending == nil {
            // A failed rename keeps the old name: the assertion itself is what matters.
            if namedCount != 0, assertions.rename(old, Self.name(0)) { namedCount = 0 }
            let g = generation
            cancelPending = schedule(grace) { [weak self] in
                guard let self, self.generation == g else { return }
                self.cancelPending = nil
                self.releaseNow()
            }
        }
    }

    /// Releases now and ignores later updates (app quit).
    public func stop() {
        releaseNow()
        stopped = true
    }

    private func cancelGrace() {
        generation += 1
        cancelPending?()
        cancelPending = nil
    }

    private func releaseNow() {
        cancelGrace()
        if let id {
            assertions.release(id)
            powerLog.info("keep-awake released \(id)")
        }
        id = nil
        if held { held = false }
    }
}
