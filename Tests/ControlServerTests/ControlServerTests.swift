import Darwin
import Foundation
import Testing
import os
import AgentStatus
@testable import ControlServer
import TestSupport

/// Sockets live in /tmp/hg-<8 hex>/ — sun_path is 104 bytes, the temp dir is too long.
final class SocketDir {
    let dir: String
    var path: String { dir + "/s.sock" }
    init() {
        dir = "/tmp/hg-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        mkdir(dir, 0o700)
    }
    deinit { try? FileManager.default.removeItem(atPath: dir) }
}

@MainActor final class Inbox {
    var messages: [ControlMessage] = []
    /// Returns as soon as `n` arrive (messages are delivered on the main actor); a small `polls` checks that none do.
    func wait(count n: Int, polls: Int = 3000) async -> [ControlMessage] {
        _ = await waitUntil(polls: polls) { messages.count >= n }
        return messages
    }
}

/// Raw test client: reads the server's replies, which ControlClient deliberately ignores.
final class RawClient: @unchecked Sendable {
    let fd: Int32
    let timeout: Double
    init(_ path: String, timeout: Double = offMainBound) throws {
        self.timeout = timeout
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // generous default: a timeout reads as eof == false, never as success
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    deinit { Darwin.close(fd) }

    func send(_ s: String) { send(Data(s.utf8)) }
    func send(_ d: Data) {
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Reads until `lines` newline-terminated replies arrive, EOF, or the receive timeout — a test failure unless
    /// `timeoutExpected` (a check that nothing more comes).
    func read(lines: Int, timeoutExpected: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async -> (replies: [String], eof: Bool) {
        let r = await onThread { self.readBlocking(lines: lines) }
        if r.timedOut && !timeoutExpected {
            Issue.record("socket read timed out after \(timeout) s with \(r.replies.count) of \(lines == .max ? "EOF" : "\(lines)") replies", sourceLocation: sourceLocation)
        }
        return (r.replies, r.eof)
    }

    func readToEOF(sourceLocation: SourceLocation = #_sourceLocation) async -> (replies: [String], eof: Bool) {
        await read(lines: .max, sourceLocation: sourceLocation)
    }

    private func readBlocking(lines: Int) -> (replies: [String], eof: Bool, timedOut: Bool) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var seen = 0
        while seen < lines {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return (split(buf), n == 0, n < 0 && errno == EAGAIN) }
            buf.append(chunk, count: n)
            seen += chunk[..<n].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        return (split(buf), false, false)
    }


    private func split(_ d: Data) -> [String] {
        String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

private func event(_ kind: HookKind = .stop) -> ControlMessage {
    .event(EventMessage(tab: UUID(), leaf: UUID(), kind: kind, session: "s-1"))
}

private func line(_ m: ControlMessage) -> String { String(decoding: m.encoded(), as: UTF8.self) }

/// Holds request handlers until `open()`; `waiting` lets a test know a handler is parked.
@MainActor private final class Gate {
    var isOpen = false
    var waiting = 0
    var calls: [ControlCall] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        waiting += 1
        await withCheckedContinuation { parked.append($0) }
    }
    func open() {
        isOpen = true
        parked.forEach { $0.resume() }
        parked.removeAll()
    }
    func untilWaiting(_ n: Int) async { await until { waiting >= n } }
    func untilCalls(_ n: Int) async { await until { calls.count >= n } }
    private func until(_ done: () -> Bool) async { _ = await waitUntil(done) }
}

private func request(_ id: Int, _ method: String, _ params: String = "{}") -> String {
    #"{"v":1,"id":\#(id),"method":"\#(method)","params":\#(params)}"# + "\n"
}

private func screen(_ id: Int, bytes: Int) -> ControlResponse {
    .ok(id, ScreenResult(tab: UUID(), leaf: UUID(), text: String(repeating: "a", count: bytes), lines: 1, truncated: false))
}

private func startServer(_ dir: SocketDir, _ inbox: Inbox, idleTimeout: Double? = nil,
                         onRequest: (@MainActor (Int, ControlCall) async -> ControlResponse)? = nil) throws -> ControlServer {
    let server = onRequest.map { ControlServer(path: dir.path, handler: { inbox.messages.append($0) }, onRequest: $0) }
        ?? ControlServer(path: dir.path) { inbox.messages.append($0) }
    // Out of the way unless a test is about it: a test stalled by load past the 10 s default lost its connection.
    server.idleTimeout = idleTimeout ?? 600
    try server.start()
    return server
}

@Suite struct ControlServerTests {
    @Test func eventRoundTrip() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let m = event(.notification)
        #expect(ControlClient.send(m, to: dir.path))
        #expect(await inbox.wait(count: 1) == [m])

        let raw = try RawClient(dir.path)
        raw.send(line(m))
        #expect(await raw.read(lines: 1).replies == [#"{"ok":true}"#])
        #expect(await inbox.wait(count: 2).count == 2)
    }

    @Test func invalidLinesRejectedServerSurvives() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send("garbage\n{\"v\":2}\n{\"v\":1,\"type\":\"tabs\"}\n")
        let replies = await raw.read(lines: 3).replies
        #expect(replies == [#"{"ok":false,"error":"bad-json"}"#, #"{"ok":false,"error":"bad-version"}"#, #"{"ok":false,"error":"unknown-type"}"#])
        let m = event()
        raw.send(line(m))
        #expect(await raw.read(lines: 1).replies == [#"{"ok":true}"#])
        #expect(await inbox.wait(count: 1) == [m])
    }

    @Test func malformedRequestGetsNewFormatError() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send(#"{"v":1,"method":"projects.list"}"# + "\n" + #"{"v":1,"id":1,"method":5}"# + "\n" + #"{"v":1,"id":1,"method":"x","params":[]}"# + "\n")
        let replies = await raw.read(lines: 3).replies
        #expect(replies.count == 3)
        for r in replies {
            #expect(r.hasPrefix(#"{"id":null,"error":{"code":"bad-request","message":""#) && !r.contains(#""ok""#))
        }
        #expect(await inbox.wait(count: 1, polls: 10).isEmpty)
    }

    @Test func splitAndBatchedLines() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        let a = event(), b = event(.prompt), c = event(.tool)
        let s = line(a)
        let mid = s.index(s.startIndex, offsetBy: s.count / 2)
        raw.send(String(s[..<mid]))
        try await Task.sleep(for: .milliseconds(50))
        raw.send(String(s[mid...]))
        #expect(await raw.read(lines: 1).replies.count == 1)
        raw.send(line(b) + line(c))
        #expect(await raw.read(lines: 2).replies.count == 2)
        #expect(await inbox.wait(count: 3) == [a, b, c])
    }

    @Test func oversizeLineClosesConnection() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send(Data(repeating: 0x61, count: 70_000))
        let r = await raw.readToEOF()
        #expect(r.replies == [#"{"ok":false,"error":"too-large"}"#])
        #expect(r.eof)

        let m = event()
        #expect(ControlClient.send(m, to: dir.path))
        #expect(await inbox.wait(count: 1) == [m])
    }

    @Test func clientClosingEarlyDoesNotKillServer() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        for _ in 0..<50 {
            let raw = try RawClient(dir.path)
            raw.send(line(event()))
        }
        #expect(await inbox.wait(count: 50).count == 50)
    }

    @Test func concurrentClients() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let ok = OSAllocatedUnfairLock(initialState: 0)
        let path = dir.path
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            if ControlClient.send(event(), to: path) { ok.withLock { $0 += 1 } }
        }
        #expect(ok.withLock { $0 } == 20)
        #expect(await inbox.wait(count: 20).count == 20)
    }

    @Test func staleSocketReplaced() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in dir.path.utf8.enumerated() { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let m = event()
        #expect(ControlClient.send(m, to: dir.path))
        #expect(await inbox.wait(count: 1) == [m])
    }

    @Test func secondInstanceDetected() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let second = ControlServer(path: dir.path) { _ in }
        #expect(throws: ControlServerError.alreadyRunning(pid: getpid())) { try second.start() }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: dir.path), "the loser must not delete the winner's socket")
        let m = event()
        #expect(ControlClient.send(m, to: dir.path))
        #expect(await inbox.wait(count: 1) == [m])
    }

    @Test func pathTooLong() {
        let path = "/tmp/" + String(repeating: "a", count: 115)
        #expect(path.utf8.count == 120)
        let server = ControlServer(path: path) { _ in }
        #expect(throws: ControlServerError.pathTooLong) { try server.start() }
        #expect(!ControlClient.send(event(), to: path))
    }

    @Test func socketIsOwnerOnly() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        var st = stat()
        #expect(lstat(dir.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func sendToMissingSocketIsFastFalse() {
        let dir = SocketDir()
        let clock = SuspendingClock()  // blind to a system sleep mid-run
        var result = true
        let elapsed = clock.measure { result = ControlClient.send(event(), to: dir.path) }
        #expect(!result)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func thirtyThirdClientGetsEOF() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let clients = try (0..<ControlServer.maxConnections).map { _ in try RawClient(dir.path) }
        // The first 32 are accepted once a round-trip works on the last one.
        clients.last!.send(line(event()))
        #expect(await clients.last!.read(lines: 1).replies == [#"{"ok":true}"#])
        let extra = try RawClient(dir.path)
        let r = await extra.readToEOF()
        #expect(r.eof && r.replies.isEmpty)
        withExtendedLifetime(clients) {}
    }

    @Test func idleConnectionIsClosed() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 0.3)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send("{\"v\":1")  // no newline: never a full line
        let start = SuspendingClock.now  // blind to a system sleep mid-run
        let r = await raw.readToEOF()
        let elapsed = SuspendingClock.now - start
        #expect(r.eof)  // closed by the server's 0.3 s idle timer: a read timeout reads as eof == false
        #expect(elapsed < .seconds(20))  // well before the read timeout; the server queue waits for CPU under load
    }

    @Test func acceptEMFILESuspendsListenerUntilConnectionCloses() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let server = ControlServer(path: dir.path) { inbox.messages.append($0) }
        server.emfileRetry = 60  // the timer is covered by its own test; here only a closing connection may resume
        server.idleTimeout = 600  // under parallel load the test ran past the 10 s default: dropping idle `a` resumed the listener
        server.acceptCall = { fd in
            let fail = failures.withLock { (n: inout Int) -> Bool in if n > 0 { n -= 1; return true }; return false }
            if fail { errno = EMFILE; return -1 }
            return Darwin.accept(fd, nil, nil)
        }
        try server.start()
        defer { server.stop() }
        var a: RawClient? = try RawClient(dir.path)
        a!.send(line(event()))
        #expect(await a!.read(lines: 1).replies.count == 1)
        #expect(await inbox.wait(count: 1).count == 1)

        failures.withLock { $0 = 1 }
        let b = try RawClient(dir.path)
        b.send(line(event(.prompt)))
        // Listener is suspended, no spin: b is not served while a stays open.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await inbox.wait(count: 2, polls: 25).count == 1)
        #expect(failures.withLock { $0 } == 0, "accept was attempted exactly once")

        a = nil  // closing a connection resumes the listener
        #expect(await b.read(lines: 1).replies == [#"{"ok":true}"#])
        #expect(await inbox.wait(count: 2).count == 2)
    }

    @Test func deinitReleasesSocketFileDescriptors() async throws {
        let dir = SocketDir()
        var server: ControlServer? = ControlServer(path: dir.path) { _ in }
        try server!.start()
        let raw = try RawClient(dir.path)
        raw.send("{")
        try await Task.sleep(for: .milliseconds(50))
        server = nil
        let r = await raw.readToEOF()
        #expect(r.eof)
        #expect(ControlClient.send(event(), to: dir.path) == false)
    }

    @Test func acceptEMFILEWithNoConnectionsResumesByTimer() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let failures = OSAllocatedUnfairLock(initialState: 1)
        let server = ControlServer(path: dir.path) { inbox.messages.append($0) }
        server.emfileRetry = 0.2
        server.acceptCall = { fd in
            let fail = failures.withLock { (n: inout Int) -> Bool in if n > 0 { n -= 1; return true }; return false }
            if fail { errno = EMFILE; return -1 }
            return Darwin.accept(fd, nil, nil)
        }
        try server.start()
        defer { server.stop() }
        let m = event()
        #expect(ControlClient.send(m, to: dir.path))
        #expect(await inbox.wait(count: 1) == [m])
    }

    // MARK: requests

    @Test func requestGetsResponse() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox) { id, _ in .ok(id, ProjectsResult(projects: [])) }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(5, "projects.list"))
        #expect(await raw.read(lines: 1).replies == [#"{"id":5,"result":{"projects":[]}}"#])
    }

    @Test func invalidRequestAnsweredWithoutHandler() async throws {
        let dir = SocketDir(), inbox = Inbox(), gate = Gate()
        let server = try startServer(dir, inbox) { id, call in
            gate.calls.append(call)
            return .ok(id, ProjectsResult(projects: []))
        }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(1, "tasks.archive", #"{"task":"x"}"#))
        let replies = await raw.read(lines: 1).replies
        #expect(replies.count == 1 && replies[0].hasPrefix(#"{"id":1,"error":{"code":"confirm-required","#))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.calls.isEmpty)
    }

    @Test func slowRequestOutlivesIdleTimeout() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 0.2) { id, _ in
            try? await Task.sleep(for: .milliseconds(600))
            return .ok(id, ProjectsResult(projects: []))
        }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(2, "projects.list"))
        let r = await raw.read(lines: 1)
        #expect(r.replies == [#"{"id":2,"result":{"projects":[]}}"#])
        #expect(!r.eof)
    }

    @Test func partialLineAfterRequestStillTimesOut() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 0.2) { id, _ in .ok(id, ProjectsResult(projects: [])) }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(2, "projects.list") + #"{"v":1"#)
        let r = await raw.readToEOF()
        #expect(r.replies == [#"{"id":2,"result":{"projects":[]}}"#])
        #expect(r.eof)
    }

    @Test func largeResponseArrivesWhole() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox) { id, _ in screen(id, bytes: 900_000) }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(3, "tabs.read", #"{"tab":"t"}"#))
        try await Task.sleep(for: .milliseconds(300))
        let replies = await raw.read(lines: 1).replies
        #expect(replies.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(replies[0].utf8)) as? [String: Any]
        #expect(object?["id"] as? Int == 3)
        #expect(((object?["result"] as? [String: Any])?["text"] as? String)?.utf8.count == 900_000)
    }

    /// The idle deadline restarts on every write the reader accepts: a reader that keeps reading, slower than the
    /// whole timeout in total, gets the whole response.
    @Test func slowReaderOutlivesIdleTimeout() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 3) { id, _ in screen(id, bytes: 900_000) }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(4, "tabs.read", #"{"tab":"t"}"#))
        let fd = raw.fd
        // 4 KB every 20 ms: ≥ 4.4 s for the whole reply (more than the 3 s timeout), while a gap of 3 s (a thread
        // starved under a loaded run) stays unlikely; a 1 s timeout was seen to drop it under load.
        let data = await onThread { () -> Data in
            var buf = Data(), chunk = [UInt8](repeating: 0, count: 4096)
            while !buf.contains(0x0A) {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(chunk, count: n)
                usleep(20_000)
            }
            return buf
        }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(((object?["result"] as? [String: Any])?["text"] as? String)?.utf8.count == 900_000)
    }

    /// A reader that stopped (a CLI suspended with ^Z) is dropped `idleTimeout` after its last progress, so stalled
    /// replies cannot hold every slot and lock out hooks and the status line.
    @Test func stalledReadersAreDroppedAndFreeTheirSlots() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 0.3) { id, _ in screen(id, bytes: 900_000) }
        defer { server.stop() }
        let stalled = try (0..<ControlServer.maxConnections).map { _ in try RawClient(dir.path) }
        for (i, c) in stalled.enumerated() { c.send(request(i + 1, "tabs.read", #"{"tab":"t"}"#)) }
        // All slots hold a reply that is never read; a new client is served once they are dropped.
        var served = false
        _ = await waitUntil(polls: 300, every: .milliseconds(200)) {
            guard let fresh = try? RawClient(dir.path, timeout: 2) else { return false }
            fresh.send(line(event()))
            served = await fresh.read(lines: 1, timeoutExpected: true).replies == [#"{"ok":true}"#]
            return served
        }
        #expect(served)
        withExtendedLifetime(stalled) {}
    }

    @Test func responseAfterDisconnectDropped() async throws {
        let dir = SocketDir(), inbox = Inbox(), gate = Gate()
        // Idle timeout out of the way: under load `second` waits > 10 s for the main-actor reply and was closed (eof).
        let server = try startServer(dir, inbox, idleTimeout: 600) { id, _ in
            await gate.wait()
            return .ok(id, ProjectsResult(projects: []))
        }
        defer { server.stop() }
        var first: RawClient? = try RawClient(dir.path, timeout: offMainBound)
        first!.send(request(1, "projects.list"))
        await gate.untilWaiting(1)
        #expect(await gate.waiting == 1)
        first = nil
        try await Task.sleep(for: .milliseconds(100))  // the server sees EOF and drops the connection; its fd may be reused

        let second = try RawClient(dir.path, timeout: 0.5)
        second.send(line(event()))
        #expect(await second.read(lines: 1).replies == [#"{"ok":true}"#])
        await gate.open()

        // The first handler resumes before the third one runs, so once the third reply is here the first was settled.
        let third = try RawClient(dir.path, timeout: offMainBound)
        third.send(request(7, "projects.list"))
        #expect(await third.read(lines: 1).replies == [#"{"id":7,"result":{"projects":[]}}"#])
        let late = await second.read(lines: 1, timeoutExpected: true)
        #expect(late.replies.isEmpty && !late.eof)
        withExtendedLifetime(first) {}
    }

    @Test func inFlightCapPerConnection() async throws {
        let dir = SocketDir(), inbox = Inbox(), gate = Gate()
        let server = try startServer(dir, inbox) { id, _ in
            await gate.wait()
            return .ok(id, ProjectsResult(projects: []))
        }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send((1...9).map { request($0, "projects.list") }.joined())
        let early = await raw.read(lines: 1).replies
        #expect(early.count == 1 && early[0].hasPrefix(#"{"id":9,"error":{"code":"busy","#))
        await gate.untilWaiting(8)
        #expect(await gate.waiting == 8)
        await gate.open()
        let rest = await raw.read(lines: 8).replies
        #expect(rest.count == 8)
        #expect(rest.allSatisfy { $0.contains(#""result":{"projects":[]}"#) })
    }

    @Test func slowReaderOverOutboxCapDropped() async throws {
        let dir = SocketDir(), inbox = Inbox(), gate = Gate()
        let server = try startServer(dir, inbox) { id, call in
            if case .projectsList = call { return .ok(id, ProjectsResult(projects: [])) }
            gate.calls.append(call)
            return screen(id, bytes: 900_000)
        }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send((1...8).map { request($0, "tabs.read", #"{"tab":"t"}"#) }.joined())
        // Reading early would drain the outbox; wait until every reply has been handed to the server queue.
        await gate.untilCalls(8)
        #expect(await gate.calls.count == 8)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await raw.readToEOF().eof)

        let fresh = try RawClient(dir.path, timeout: offMainBound)
        fresh.send(request(1, "projects.list"))
        #expect(await fresh.read(lines: 1).replies == [#"{"id":1,"result":{"projects":[]}}"#])
    }

    @Test func oversizeResponseReplacedByTooLarge() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox) { id, _ in screen(id, bytes: ControlServer.maxResponse) }
        defer { server.stop() }
        let raw = try RawClient(dir.path, timeout: offMainBound)
        raw.send(request(4, "tabs.read", #"{"tab":"t"}"#))
        let replies = await raw.read(lines: 1).replies
        #expect(replies.count == 1 && replies[0].hasPrefix(#"{"id":4,"error":{"code":"too-large","#))
    }

    @Test func clientRequestRoundTrip() async throws {
        let dir = SocketDir(), inbox = Inbox(), gate = Gate()
        let server = try startServer(dir, inbox) { id, call in
            gate.calls.append(call)
            return .ok(id, TasksResult(tasks: []))
        }
        defer { server.stop() }
        let path = dir.path
        let result = await onThread { ControlClient.request(.tasksList(project: nil), to: path, timeout: offMainBound) }
        let data = try result.get()
        #expect(try JSONDecoder().decode(TasksResult.self, from: data) == TasksResult(tasks: []))
        #expect(await gate.calls == [.tasksList(project: nil)])
    }

    @Test func clientRequestReturnsServerError() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox) { id, _ in
            ControlResponse(id: id, body: .failure(ControlError(code: .notFound, message: "no such task")))
        }
        defer { server.stop() }
        let path = dir.path
        let result = await onThread { ControlClient.request(.tasksArchive(task: "x"), to: path, timeout: offMainBound) }
        #expect(result == .failure(ControlError(code: .notFound, message: "no such task")))
    }

    @Test func clientGetsTooLargeForOversizeLine() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let path = dir.path
        // Every `"` is escaped to two bytes, so the line passes maxLine although the text is within its own limit.
        let text = String(repeating: "\"", count: ControlMethod.maxText)
        let result = await onThread { ControlClient.request(.tabsSend(tab: "t", text: text, keys: []), to: path, timeout: offMainBound) }
        #expect(result.failureCode == .tooLarge)
    }

    @Test func clientMapsNullIdError() async throws {
        let dir = SocketDir()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = socketAddress(dir.path)!
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0 && listen(fd, 1) == 0)
        // A fake server: it answers whatever arrives with a request-shaped error that has no id.
        Thread {
            let peer = accept(fd, nil, nil)
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(peer, &chunk, chunk.count)
                if n <= 0 || chunk[..<n].contains(0x0A) { break }
            }
            let reply = Array(#"{"id":null,"error":{"code":"bad-request","message":"nope"}}"#.utf8 + [0x0A])
            _ = Darwin.write(peer, reply, reply.count)
            close(peer)
        }.start()
        let path = dir.path
        let result = await onThread { ControlClient.request(.projectsList, to: path, timeout: offMainBound) }
        #expect(result == .failure(ControlError(code: .badRequest, message: "nope")))
    }

    @Test func clientNotRunning() {
        let dir = SocketDir()
        let clock = SuspendingClock()  // blind to a system sleep mid-run
        var result: Result<Data, ControlError> = .success(Data())
        let elapsed = clock.measure { result = ControlClient.request(.projectsList, to: dir.path, timeout: 2) }
        #expect(result.failureCode == .notRunning)
        #expect(elapsed < .milliseconds(500))
    }

    @Test func clientTimeout() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox) { id, _ in
            try? await Task.sleep(for: .seconds(3))
            return .ok(id, ProjectsResult(projects: []))
        }
        defer { server.stop() }
        let path = dir.path
        // Timed inside the thread: under a parallel run the thread itself may start late.
        let (result, elapsed) = await onThread {
            let start = SuspendingClock.now
            let r = ControlClient.request(.projectsList, to: path, timeout: 0.3)
            return (r, SuspendingClock.now - start)
        }
        #expect(result.failureCode == .timeout)
        #expect(elapsed < .milliseconds(1500))
    }
}

private extension Result where Failure == ControlError {
    var failureCode: ControlErrorCode? { if case let .failure(e) = self { e.code } else { nil } }
}
