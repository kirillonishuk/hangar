import Foundation
import Testing
@testable import Integration

@Test func jsonRoundTripPreservesOrderAndNumbers() throws {
    let x = #"""
    {
      "zeta": {
        "b": 1.0,
        "a": 1e3,
        "m": -0
      },
      "alpha": [
        "é",
        "\"q\"",
        "back\\slash\ttab",
        [],
        {},
        true,
        false,
        null
      ],
      "empty": {}
    }

    """#
    #expect(printJSON(try parseJSON(x)) == x)
}

@Test func invalidJSONThrows() {
    #expect(throws: IntegrationError.invalidJSON(line: 1)) { try parseJSON(#"{"a": 1,}"#) }
    #expect(throws: IntegrationError.invalidJSON(line: 1)) { try parseJSON("// c\n{}") }
    #expect(throws: IntegrationError.invalidJSON(line: 3)) { try parseJSON("{\n  \"a\": 1,\n}") }
    #expect(throws: IntegrationError.invalidJSON(line: 2)) { try parseJSON("{}\nx") }
    #expect(throws: IntegrationError.notAnObject) { try claudeInstall("[1]", cli: "/A/hangar") }
}

@Test func jsonEscapesAndUnicode() throws {
    let v = try parseJSON(#"{"s": "é😀\n\u0001"}"#)
    #expect(v == .object([JSONMember(key: "s", value: .string("é😀\n\u{1}"))]))
    #expect(printJSON(v) == "{\n  \"s\": \"é😀\\n\\u0001\"\n}\n")
}

@Test func duplicateKeyIsInvalid() {
    #expect(throws: IntegrationError.invalidJSON(line: 2)) { try parseJSON("{\n\"a\": 1, \"a\": 2}") }
    #expect(throws: IntegrationError.invalidJSON(line: 1)) { try parseJSON(#"{"x": {"k": 1, "k": 1}}"#) }
    #expect((try? parseJSON(#"{"a": {"k": 1}, "b": {"k": 2}}"#)) != nil)
}
