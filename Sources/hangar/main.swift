import Darwin
import Foundation
import AgentStatus
import ControlServer

// Hooks must never see output or a non-zero exit from `event`: stdout of some hooks goes into the
// agent's context and exit code 2 blocks the prompt. A closed pipe must not kill us either.
signal(SIGPIPE, SIG_IGN)

/// stdin up to 1 MiB; the rest is drained so the writer does not get EPIPE. TTY → nil.
func readStdin() -> Data? {
    guard isatty(0) == 0 else { return nil }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(0, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        if data.count < maxStdin { data.append(chunk, count: min(n, maxStdin - data.count)) }
    }
    return data
}

func defaultSocketPath() -> String {
    ProcessInfo.processInfo.environment["HANGAR_SOCKET"]
        ?? NSHomeDirectory() + "/Library/Application Support/Hangar/hangar.sock"
}

func runEvent(_ rest: [String]) -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let args = Array(rest.dropFirst())
    let payloadIsArg = args.last?.hasPrefix("{") == true
    let stdin = payloadIsArg ? nil : readStdin()
    if let kind = rest.first, let message = eventMessage(kind: kind, args: args, env: env, stdin: stdin),
       let socket = env["HANGAR_SOCKET"] {
        _ = ControlClient.send(.event(message), to: socket)
    }
    // The original notify command still runs outside Hangar or without the app.
    if rest.first == "codex-notify", let argv = chainedArgv(args) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv + (payloadIsArg ? [args[args.count - 1]] : [])
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

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "event": exit(runEvent(Array(argv.dropFirst())))
case "statusline": exit(runStatusline(Array(argv.dropFirst())))
default:
    FileHandle.standardError.write(Data("usage: hangar event <kind> [--session ID] | hangar statusline [--then <command>]\n".utf8))
    exit(1)
}
