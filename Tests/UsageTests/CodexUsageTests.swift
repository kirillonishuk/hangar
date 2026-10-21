import Foundation
import Testing
import Exec
@testable import Usage

private let now = Date(timeIntervalSince1970: 1_760_000_000)
// verify: проверить, когда codex будет установлен — фикстура по документированной схеме
private let fixture = #"{"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":1760011000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1760200000},"planType":"plus"}}"#

private func tmpDir() throws -> URL {
    let d = URL(fileURLWithPath: "/tmp/hg-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func script(_ body: String, in dir: URL) throws -> String {
    let f = dir.appendingPathComponent("codex")
    try ("#!/bin/sh\n[ \"$1\" = warm ] && exit 0\n" + body).write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    // First exec of a fresh file is slow (system scan); warm it so the 500 ms timeout test is not racing it.
    let w = Process(); w.executableURL = f; w.arguments = ["warm"]; w.standardInput = FileHandle.nullDevice
    try w.run(); w.waitUntilExit()
    return f.path
}
private func alive(_ pid: String) -> Bool {
    guard let p = Int32(pid) else { return false }
    return kill(p, 0) == 0
}
/// Bounded poll (no fixed sleeps): true as soon as `cond` holds, false after `seconds`.
private func waitUntil(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}
private func pgrepCount(_ marker: String) -> Int {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", marker]
    let out = Pipe(); p.standardOutput = out
    try? p.run(); p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
}

@Test func codexMapping() throws {
    let obj = try JSONSerialization.jsonObject(with: Data(fixture.utf8))
    let u = try #require(codexUsage(fromResult: obj, now: now))
    #expect(u.windows.map(\.kind) == [.session, .weekly])
    #expect(u.windows.map(\.usedPercent) == [22, 100])
    #expect(u.windows[0].resetsAt == Date(timeIntervalSince1970: 1_760_011_000))
    #expect(u.plan == "plus")
    let odd = try JSONSerialization.jsonObject(with: Data(#"{"x":{"usedPercent":5,"windowDurationMins":60}}"#.utf8))
    #expect(codexUsage(fromResult: odd, now: now) == nil)
    #expect(codexUsage(fromResult: [String: Any](), now: now) == nil)
}

@Test func codexReaderWithFakeServer() async throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pidFile = dir.appendingPathComponent("pid").path
    let exe = try script("""
    [ "$1" = app-server ] || exit 3
    echo $$ > \(pidFile)
    read a; read b; read c
    case "$a" in *'"initialize"'*'"id":0'*) ;; *) exit 4;; esac
    case "$b" in *'"initialized"'*) ;; *) exit 5;; esac
    case "$c" in *'account/rateLimits/read'*'"id":1'*) ;; *) exit 6;; esac
    echo '{"method":"thread/started","params":{}}'
    echo '{"id":0,"result":{}}'
    echo '{"id":1,"result":\(fixture)}'
    sleep 30
    """, in: dir)
    let u = try await CodexUsageReader(executable: exe).read(now: now)
    #expect(u.windows.map(\.usedPercent) == [22, 100])
    #expect(u.plan == "plus")
    let pid = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let gone = await waitUntil { !alive(pid) }
    #expect(gone)
}

@Test func codexReaderServerRepliesAndExits() async throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let exe = try script("read a; read b; read c\necho '{\"id\":1,\"result\":\(fixture)}'\nexit 0\n", in: dir)
    let u = try await CodexUsageReader(executable: exe).read(now: now)
    #expect(u.windows.map(\.usedPercent) == [22, 100])
    let bare = try script("read a; read b; read c\nprintf '%s' '{\"id\":1,\"result\":\(fixture)}'\nexit 0\n", in: dir)
    let u2 = try await CodexUsageReader(executable: bare).read(now: now)
    #expect(u2.plan == "plus")
}

@Test func codexReaderFailures() async throws {
    let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let marker = String(Int.random(in: 600_000...899_999))
    let hang = try script("touch \(dir.path)/started\nsleep \(marker)\n", in: dir)
    let t0 = Date()
    await #expect(throws: (any Error).self) {
        try await CodexUsageReader(executable: hang, timeout: .milliseconds(500)).read(now: now)
    }
    // Killed at the 0.5 s timeout, not after the 600 000 s sleep; slack for a loaded test machine.
    #expect(Date().timeIntervalSince(t0) < 6)
    // The script ran (otherwise the kill proves nothing) and its sleep grandchild is gone too (group kill).
    let started = await waitUntil { FileManager.default.fileExists(atPath: dir.path + "/started") }
    #expect(started)
    let reaped = await waitUntil { pgrepCount("sleep \(marker)") == 0 }
    #expect(reaped)

    let err = try script(#"read a; read b; read c; echo '{"id":1,"error":{"message":"x"}}'; sleep 30"#, in: dir)
    await #expect(throws: (any Error).self) { try await CodexUsageReader(executable: err).read(now: now) }

    let exit = try script("read a; exit 0", in: dir)
    await #expect(throws: (any Error).self) { try await CodexUsageReader(executable: exit).read(now: now) }

    let junk = try script("echo not json; echo '{\"id\":1,\"result\":{}}'", in: dir)
    await #expect(throws: (any Error).self) { try await CodexUsageReader(executable: junk).read(now: now) }

    await #expect(throws: (any Error).self) { try await CodexUsageReader(executable: dir.path + "/missing").read(now: now) }
}

@Test func resolveCodexParsesPath() async {
    let ok = Runner { args, _ in
        #expect(args == ["/bin/zsh", "-l", "-i", "-c", "command -v codex"])
        return RunResult(status: 0, stdout: "banner\n/opt/homebrew/bin/codex\n", stderr: "")
    }
    #expect(await resolveCodex(runner: ok, shell: "/bin/zsh") == "/opt/homebrew/bin/codex")
    let none = Runner { _, _ in RunResult(status: 1, stdout: "", stderr: "") }
    #expect(await resolveCodex(runner: none, shell: "/bin/zsh") == nil)
}

@Test func refreshGate() {
    var g = CodexRefreshGate()
    let t = now
    do { let r = g.begin(afterTurn: false, now: t); #expect(r == true) }
    do { let r = g.begin(afterTurn: false, now: t); #expect(r == false) }
    g.end(now: t)
    do { let r = g.begin(afterTurn: true, now: t.addingTimeInterval(30)); #expect(r == false) }
    do { let r = g.begin(afterTurn: true, now: t.addingTimeInterval(61)); #expect(r == true) }
    g.end(now: t)
    do { let r = g.begin(afterTurn: false, now: t.addingTimeInterval(1)); #expect(r == true) }
}
