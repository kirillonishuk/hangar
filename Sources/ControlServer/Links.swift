import Foundation

public enum LinkKind: String, CaseIterable, Codable, Sendable { case task, tab, project }

/// `hangar://task|tab|project/<id or id prefix>` (#NN-links): opening one only selects/focuses, never runs anything.
public struct HangarLink: Equatable, Sendable {
    public static let scheme = "hangar"

    public var kind: LinkKind
    /// Lowercased hex id or prefix (≥ 4 characters), as `resolveRef` takes it.
    public var ref: String

    public init(kind: LinkKind, ref: String) {
        self.kind = kind
        self.ref = ref.lowercased()
    }

    /// Trust boundary: any app or web page can open a `hangar://` URL. Only the exact shape is accepted.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased(), let kind = LinkKind(rawValue: host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        var path = Substring(url.path)
        guard path.hasPrefix("/") else { return nil }
        path = path.dropFirst()
        if path.hasSuffix("/") { path = path.dropLast() }
        guard (4...36).contains(path.count), path.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        self.init(kind: kind, ref: String(path))
    }

    public var url: URL {
        let path = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? ""
        return URL(string: "\(Self.scheme)://\(kind.rawValue)/\(path)")!
    }
}

public struct LinkResult: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}
