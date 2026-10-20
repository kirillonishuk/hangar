import Darwin
import Foundation
import Testing
import os
import AgentStatus
@testable import ControlServer

/// Sockets live in /tmp/hg-<8 hex>/ — sun_path is 104 bytes, the temp dir is too long.
private final class SocketDir {
    let dir: String
    var path: String { dir + "/s.sock" }
    init() {
        dir = "/tmp/hg-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        mkdir(dir, 0o700)
    }
    deinit { try? FileManager.default.removeItem(atPath: dir) }
}

@MainActor private final class Inbox {
    var messages: [ControlMessage] = []
    /// Returns as soon as `n` arrive; the generous default only matters under a loaded parallel test run.
    func wait(count n: Int, seconds: Double = 10) async -> [ControlMessage] {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while messages.count < n && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return messages
    }
}

/// Raw test client: reads the server's replies, which ControlClient deliberately ignores.
private final class RawClient {
    let fd: Int32
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)  // generous: a timeout reads as eof == false, never as success
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

    /// Reads until `lines` newline-terminated replies arrive, EOF, or the receive timeout.
    func read(lines: Int) -> (replies: [String], eof: Bool) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buf.filter({ $0 == 0x0A }).count < lines {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { return (split(buf), n == 0) }
            buf.append(chunk, count: n)
        }
        return (split(buf), false)
    }

    func readToEOF() -> (replies: [String], eof: Bool) { read(lines: .max) }

    private func split(_ d: Data) -> [String] {
        String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

private func event(_ kind: HookKind = .stop) -> ControlMessage {
    .event(EventMessage(tab: UUID(), leaf: UUID(), kind: kind, session: "s-1"))
}

private func line(_ m: ControlMessage) -> String { String(decoding: m.encoded(), as: UTF8.self) }

private func startServer(_ dir: SocketDir, _ inbox: Inbox, idleTimeout: Double? = nil) throws -> ControlServer {
    let server = ControlServer(path: dir.path) { inbox.messages.append($0) }
    if let idleTimeout { server.idleTimeout = idleTimeout }
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
        #expect(raw.read(lines: 1).replies == [#"{"ok":true}"#])
        #expect(await inbox.wait(count: 2).count == 2)
    }

    @Test func invalidLinesRejectedServerSurvives() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send("garbage\n{\"v\":2}\n{\"v\":1,\"type\":\"tabs\"}\n")
        let replies = raw.read(lines: 3).replies
        #expect(replies == [#"{"ok":false,"error":"bad-json"}"#, #"{"ok":false,"error":"bad-version"}"#, #"{"ok":false,"error":"unknown-type"}"#])
        let m = event()
        raw.send(line(m))
        #expect(raw.read(lines: 1).replies == [#"{"ok":true}"#])
        #expect(await inbox.wait(count: 1) == [m])
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
        #expect(raw.read(lines: 1).replies.count == 1)
        raw.send(line(b) + line(c))
        #expect(raw.read(lines: 2).replies.count == 2)
        #expect(await inbox.wait(count: 3) == [a, b, c])
    }

    @Test func oversizeLineClosesConnection() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send(Data(repeating: 0x61, count: 70_000))
        let r = raw.readToEOF()
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
        let clock = ContinuousClock()
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
        #expect(clients.last!.read(lines: 1).replies == [#"{"ok":true}"#])
        let extra = try RawClient(dir.path)
        let r = extra.readToEOF()
        #expect(r.eof && r.replies.isEmpty)
        withExtendedLifetime(clients) {}
    }

    @Test func idleConnectionIsClosed() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let server = try startServer(dir, inbox, idleTimeout: 0.3)
        defer { server.stop() }
        let raw = try RawClient(dir.path)
        raw.send("{\"v\":1")  // no newline: never a full line
        let clock = ContinuousClock()
        var r: (replies: [String], eof: Bool) = ([], false)
        let elapsed = clock.measure { r = raw.readToEOF() }
        #expect(r.eof)  // closed by the 0.3 s idle timer, not the 10 s read timeout
        #expect(elapsed < .seconds(5))
    }

    @Test func acceptEMFILESuspendsListenerUntilConnectionCloses() async throws {
        let dir = SocketDir(), inbox = Inbox()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let server = ControlServer(path: dir.path) { inbox.messages.append($0) }
        server.emfileRetry = 60  // the timer is covered by its own test; here only a closing connection may resume
        server.acceptCall = { fd in
            let fail = failures.withLock { (n: inout Int) -> Bool in if n > 0 { n -= 1; return true }; return false }
            if fail { errno = EMFILE; return -1 }
            return Darwin.accept(fd, nil, nil)
        }
        try server.start()
        defer { server.stop() }
        var a: RawClient? = try RawClient(dir.path)
        a!.send(line(event()))
        #expect(a!.read(lines: 1).replies.count == 1)
        #expect(await inbox.wait(count: 1).count == 1)

        failures.withLock { $0 = 1 }
        let b = try RawClient(dir.path)
        b.send(line(event(.prompt)))
        // Listener is suspended, no spin: b is not served while a stays open.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await inbox.wait(count: 2, seconds: 0.2).count == 1)
        #expect(failures.withLock { $0 } == 0, "accept was attempted exactly once")

        a = nil  // closing a connection resumes the listener
        #expect(b.read(lines: 1).replies == [#"{"ok":true}"#])
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
        let r = raw.readToEOF()
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
}
