import Foundation

/// Something a CLI/MCP reference can point at: a project (names: name, path) or a task (names: name).
public struct RefCandidate: Equatable, Sendable {
    public var id: UUID
    public var names: [String]

    public init(id: UUID, names: [String]) {
        self.id = id
        self.names = names
    }
}

public enum RefError: Error, Equatable, Sendable { case notFound, ambiguous([UUID]) }

/// Decision #45: full UUID → exact name → case-insensitive id prefix of ≥ 4 characters; more than one match at a step is ambiguous.
public func resolveRef(_ ref: String, in candidates: [RefCandidate]) -> Result<UUID, RefError> {
    let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ref.isEmpty else { return .failure(.notFound) }
    if let id = UUID(uuidString: ref), candidates.contains(where: { $0.id == id }) { return .success(id) }
    let byName = candidates.filter { $0.names.contains(ref) }.map(\.id)
    if !byName.isEmpty { return byName.count == 1 ? .success(byName[0]) : .failure(.ambiguous(byName)) }
    guard ref.count >= 4 else { return .failure(.notFound) }
    let prefix = ref.lowercased()
    let byPrefix = candidates.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }.map(\.id)
    switch byPrefix.count {
    case 0: return .failure(.notFound)
    case 1: return .success(byPrefix[0])
    default: return .failure(.ambiguous(byPrefix))
    }
}
