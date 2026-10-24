import Darwin
import Foundation
import AgentStatus
import ControlServer

// Hooks must never see output or a non-zero exit from `event`: stdout of some hooks goes into the
// agent's context and exit code 2 blocks the prompt. A closed pipe must not kill us either.
signal(SIGPIPE, SIG_IGN)

/// stdin up to 1 MiB within a ~1 s total budget (a silent open pipe must not hold up a hook or the status line);
/// the rest is drained while the budget lasts so the writer does not get EPIPE. TTY → nil.
// shortcut: statusline input above 1 MiB is truncated for the original command too (real payloads are a few KB)
func readStdin() -> Data? {
    guard isatty(0) == 0 else { return nil }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { break }
        var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32((deadline - now) / 1_000_000) + 1)
        if ready < 0 && errno == EINTR { continue }
        if ready <= 0 { break }
        let n = read(0, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        if data.count < maxStdin { data.append(chunk, count: min(n, maxStdin - data.count)) }
    }
    return data
}

/// PATH lookup without `/usr/bin/env`, so an argv[0] like `-x` or `A=b` cannot be misread as an option or assignment.
func resolveExecutable(_ name: String) -> URL? {
    if name.contains("/") { return URL(fileURLWithPath: name) }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if access(candidate, X_OK) == 0 { return URL(fileURLWithPath: candidate) }
    }
    return nil
}

func defaultSocketPath() -> String {
    ProcessInfo.processInfo.environment["HANGAR_SOCKET"]
        ?? NSHomeDirectory() + "/Library/Application Support/Hangar/hangar.sock"
}

func runEvent(_ rest: [String]) -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let args = Array(rest.dropFirst())
    let payloadIsArg = args.last?.hasPrefix("{") == true
    let inHangar = UUID(uuidString: env["HANGAR_TAB_ID"] ?? "") != nil && UUID(uuidString: env["HANGAR_LEAF_ID"] ?? "") != nil
        && env["HANGAR_SOCKET"] != nil
    let stdin = payloadIsArg || !inHangar ? nil : readStdin()
    if let kind = rest.first, let message = eventMessage(kind: kind, args: args, env: env, stdin: stdin),
       let socket = env["HANGAR_SOCKET"] {
        _ = ControlClient.send(.event(message), to: socket)
    }
    // The original notify command still runs outside Hangar or without the app.
    if rest.first == "codex-notify", let argv = chainedArgv(args), let exe = resolveExecutable(argv[0]) {
        let p = Process()
        p.executableURL = exe
        p.arguments = Array(argv.dropFirst()) + (payloadIsArg ? [args[args.count - 1]] : [])
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
    return 0
}

func runStatusline(_ rest: [String]) -> Int32 {
    let stdin = readStdin() ?? Data()
    let windows = statuslineWindows(stdin)
    if !windows.isEmpty {
        _ = ControlClient.send(.usage(UsageMessage(agent: "claude", windows: windows)), to: defaultSocketPath())
    }
    guard let i = rest.firstIndex(of: "--then"), i + 1 < rest.count else { return 0 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", rest[i + 1]]
    let pipe = Pipe()
    p.standardInput = pipe
    guard (try? p.run()) != nil else { return 1 }
    // A writer thread: a command that does not read its stdin must not block us.
    let writer = pipe.fileHandleForWriting
    DispatchQueue.global().async {
        try? writer.write(contentsOf: stdin)
        try? writer.close()
    }
    p.waitUntilExit()
    return p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus
}

/// Exit codes: 0 ok, 1 app error / not running / timeout, 2 usage or missing --yes (the CLI's or the server's `bad-params` /
/// `confirm-required`).
func runCommand(_ args: [String]) -> Int32 {
    let stderr = FileHandle.standardError
    switch parseCLI(args, cwd: FileManager.default.currentDirectoryPath) {
    case let .usage(message):
        stderr.write(jsonRequested(args) ? errorJSON(ControlError(code: .badParams, message: message)) + Data("\n".utf8)
                                         : Data("hangar: \(message)\n\(cliUsage)\n".utf8))
        return 2
    case let .confirmRequired(message):
        stderr.write(jsonRequested(args) ? errorJSON(ControlError(code: .confirmRequired, message: message)) + Data("\n".utf8)
                                         : Data("hangar: \(message)\n".utf8))
        return 2
    case let .call(call, json):
        switch ControlClient.request(call, to: defaultSocketPath(), timeout: requestTimeout(call)) {
        case let .failure(e):
            stderr.write(json ? errorJSON(e) + Data("\n".utf8) : Data("hangar: \(e.message)\n".utf8))
            return [.badParams, .confirmRequired].contains(e.code) ? 2 : 1
        case let .success(result):
            var out: Data
            if json {
                let object = try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
                out = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) } ?? result
            } else {
                out = Data(formatHuman(call, result: result).utf8)
            }
            if !out.isEmpty && out.last != 0x0A { out.append(0x0A) }
            FileHandle.standardOutput.write(out)
            return 0
        }
    }
}

/// The app's part over the socket plus the CLI's own lines (socket, versions); exit 1 when a check fails.
func collectDoctorReport() -> DoctorReport {
    let app = ControlClient.request(.doctor, to: defaultSocketPath(), timeout: requestTimeout(.doctor))
        .flatMap { data in
            (try? JSONDecoder().decode(DoctorResult.self, from: data)).map { .success($0) }
                ?? .failure(ControlError(code: .failed, message: "unreadable doctor answer from the app"))
        }
    return doctorReport(app: app, cliVersion: Bundle.main.executableURL.map(MCPSession.appVersion) ?? "dev")
}

func runDoctor(_ args: [String]) -> Int32 {
    guard case let .call(_, json) = parseDoctorArgs(args) else {
        FileHandle.standardError.write(Data("hangar: usage: hangar doctor [--json]\n".utf8))
        return 2
    }
    let report = collectDoctorReport()
    FileHandle.standardOutput.write((json ? doctorJSON(report) : Data(formatDoctor(report).utf8)) + Data("\n".utf8))
    return report.exitCode
}

/// MCP over stdio: one JSON-RPC message per line until EOF, answered in order; stdout carries only replies.
func runMCP(readOnly: Bool) -> Int32 {
    var session = MCPSession(readOnly: readOnly) { call in
        // `doctor` answers even when the app is down: the report says so.
        if call == .doctor { return .success(doctorJSON(collectDoctorReport())) }
        return ControlClient.request(call, to: defaultSocketPath(), timeout: requestTimeout(call))
    }
    let out = FileHandle.standardOutput
    // An oversize line keeps only maxMCPLine + 1 bytes, enough for `handle` to answer -32600.
    var pending = Data()
    func answer(_ line: Data) -> Bool {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }), var reply = session.handle(line) else { return true }
        reply.append(0x0A)
        return (try? out.write(contentsOf: reply)) != nil  // FileHandle writes unbuffered: each reply is flushed
    }
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(0, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 {
            _ = answer(pending)  // a last line without a newline
            return 0
        }
        var rest = chunk[..<n]
        while let nl = rest.firstIndex(of: 0x0A) {
            pending.append(contentsOf: rest[..<nl].prefix(maxMCPLine + 1 - pending.count))
            guard answer(pending) else { return 0 }  // stdout closed: the client is gone
            pending.removeAll(keepingCapacity: true)
            rest = rest[(nl + 1)...]
        }
        pending.append(contentsOf: rest.prefix(maxMCPLine + 1 - pending.count))
    }
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "event": exit(runEvent(Array(argv.dropFirst())))
case "statusline": exit(runStatusline(Array(argv.dropFirst())))
case "projects", "tasks", "tabs": exit(runCommand(argv))
case "doctor": exit(runDoctor(argv))
case "mcp" where argv.count == 1: exit(runMCP(readOnly: false))
case "mcp" where argv == ["mcp", "--read-only"]: exit(runMCP(readOnly: true))
default:  // hooks always call `event`/`statusline`, so no hook sees this exit code
    FileHandle.standardError.write(Data((cliUsage + "\n").utf8))
    exit(2)
}
