import Foundation
import Testing
@testable import Integration

private func tmpDir() throws -> URL {
    let d = URL(fileURLWithPath: "/tmp/hg-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func perms(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}
private let now = Date(timeIntervalSince1970: 1_760_000_000)

@Test func writeKeepsSymlinkPermsAndBacksUp() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let real = d.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let target = real.appendingPathComponent("settings.json")
    try "{\"old\": 1}\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    let link = d.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real/settings.json")

    #expect(try readUserFile(link) == "{\"old\": 1}\n")
    let backup = try writeUserFile(link, text: "{}\n", expected: "{\"old\": 1}\n", now: now)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real/settings.json")
    #expect(try String(contentsOf: target, encoding: .utf8) == "{}\n")
    #expect(try perms(target) == 0o600)
    let b = try #require(backup)
    #expect(b.deletingLastPathComponent().standardizedFileURL.path == real.resolvingSymlinksInPath().path)
    #expect(b.lastPathComponent.wholeMatch(of: /settings\.json\.hangar-backup-\d{8}-\d{6}/) != nil)
    #expect(try String(contentsOf: b, encoding: .utf8) == "{\"old\": 1}\n")
    #expect(try perms(b) == 0o600)

    // A second write in the same second must not clobber the first backup.
    let b2 = try #require(try writeUserFile(link, text: "{\"x\": 2}\n", expected: "{}\n", now: now))
    #expect(b2 != b)
    #expect(try String(contentsOf: b, encoding: .utf8) == "{\"old\": 1}\n")
    #expect(try String(contentsOf: b2, encoding: .utf8) == "{}\n")
}

@Test func writeRefusesWhenChangedOnDisk() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let f = d.appendingPathComponent("settings.json")
    try "{\"a\": 1}\n".write(to: f, atomically: true, encoding: .utf8)
    #expect(throws: IntegrationError.changedOnDisk) {
        try writeUserFile(f, text: "{}\n", expected: "{\"a\": 0}\n", now: now)
    }
    #expect(throws: IntegrationError.changedOnDisk) {
        try writeUserFile(f, text: "{}\n", expected: nil, now: now)
    }
    #expect(try String(contentsOf: f, encoding: .utf8) == "{\"a\": 1}\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: d.path) == ["settings.json"])
}

@Test func newFileWithoutBackup() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let f = d.appendingPathComponent("sub/dir/settings.json")
    #expect(try readUserFile(f) == nil)
    #expect(try writeUserFile(f, text: "{}\n", expected: nil, now: now) == nil)
    #expect(try String(contentsOf: f, encoding: .utf8) == "{}\n")
    #expect(try perms(f) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.deletingLastPathComponent().path) == ["settings.json"])
}

@Test func writeAbortsWhenChangedBeforeRename() throws {
    let d = try tmpDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let f = d.appendingPathComponent("settings.json")
    try "{\"a\": 1}\n".write(to: f, atomically: true, encoding: .utf8)
    #expect(throws: IntegrationError.changedOnDisk) {
        try writeUserFile(f, text: "{}\n", expected: "{\"a\": 1}\n", now: now) {
            try? "{\"a\": 9}\n".write(to: f, atomically: true, encoding: .utf8)
        }
    }
    #expect(try String(contentsOf: f, encoding: .utf8) == "{\"a\": 9}\n")
    let names = try FileManager.default.contentsOfDirectory(atPath: d.path).sorted()
    #expect(names.count == 2 && names[0] == "settings.json" && names[1].hasPrefix("settings.json.hangar-backup-"))
}
