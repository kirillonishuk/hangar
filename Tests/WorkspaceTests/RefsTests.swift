import Foundation
import Testing
import Workspace

@Suite struct RefsTests {
    @Test func resolveRefRules() {
        let a = UUID(uuidString: "AB12C3D4-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "AB12C3D4-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "ABCD0000-0000-0000-0000-000000000003")!
        let d = UUID(uuidString: "11110000-0000-0000-0000-000000000004")!
        let items = [RefCandidate(id: a, names: ["alpha"]), RefCandidate(id: b, names: ["beta", "/p/beta"]),
                     RefCandidate(id: c, names: ["gamma"]), RefCandidate(id: d, names: ["abcd"])]

        #expect(resolveRef(a.uuidString, in: items) == .success(a))
        #expect(resolveRef(a.uuidString.lowercased(), in: items) == .success(a))
        #expect(resolveRef(UUID().uuidString, in: items) == .failure(.notFound))
        #expect(resolveRef("ab12c3d4-0000-0000-0000-000000000001".uppercased(), in: items) == .success(a))
        // Prefix: case-insensitive, at least 4 characters.
        #expect(resolveRef("AB12C3D4-0000-0000-0000-00000000000", in: items) == .failure(.ambiguous([a, b])))
        #expect(resolveRef("ab12", in: items) == .failure(.ambiguous([a, b])))
        #expect(resolveRef("1111", in: items) == .success(d))
        #expect(resolveRef("111", in: items) == .failure(.notFound))
        // Names (any of a candidate's names, e.g. a project's path).
        #expect(resolveRef("beta", in: items) == .success(b))
        #expect(resolveRef("/p/beta", in: items) == .success(b))
        let twins = items + [RefCandidate(id: UUID(), names: ["alpha"])]
        #expect(resolveRef("alpha", in: twins) == .failure(.ambiguous([a, twins[4].id])))
        // A name wins over an id prefix.
        #expect(resolveRef("abcd", in: items) == .success(d))
        #expect(resolveRef("", in: items) == .failure(.notFound))
        #expect(resolveRef("  ", in: items) == .failure(.notFound))
    }
}
