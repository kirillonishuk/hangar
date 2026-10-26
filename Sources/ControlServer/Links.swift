import Foundation

/// `sessions` is the «Сессии» view of a project (#88), not a session (that one is `task`, #73).
public enum LinkKind: String, CaseIterable, Codable, Sendable { case task, tab, project, host, sessions }

/// `hangar://task|tab|project|sessions/<uuid>`, `hangar://host/<ssh host>` (#66, #88): opening one only selects/shows,
/// never runs, creates or connects anything.
public struct HangarLink: Equatable, Sendable {
    public static let scheme = "hangar"
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")

    public var kind: LinkKind
    /// A lowercased full UUID; for `host`, the sidebar's host name as is.
    public var ref: String

    public init(kind: LinkKind, ref: String) {
        self.kind = kind
        self.ref = kind == .host ? ref : ref.lowercased()
    }

    /// Trust boundary: any app or web page can open a `hangar://` URL. Only the exact shape is accepted.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased(), let kind = LinkKind(rawValue: host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        // Still percent-encoded: `%` fails both checks below, so nothing is ever decoded into the ref.
        var path = Substring(url.path(percentEncoded: true))
        guard path.hasPrefix("/") else { return nil }
        path = path.dropFirst()
        if path.hasSuffix("/") { path = path.dropLast() }
        let ref = String(path)
        if kind == .host {
            guard Self.isLinkableHost(ref) else { return nil }
        } else {
            guard ref.count == 36, UUID(uuidString: ref) != nil else { return nil }
        }
        self.init(kind: kind, ref: ref)
    }

    /// An ssh config name or `user@host` of plain ASCII: nothing in it needs encoding or could pass for a flag.
    // shortcut: hosts with other characters (IPv6 literals, `%`) get no link, widen if someone needs one
    public static func isLinkableHost(_ s: String) -> Bool {
        (1...255).contains(s.utf8.count) && !s.hasPrefix("-") && !s.contains("@-")
            && s.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    public var url: URL {
        let path = ref.addingPercentEncoding(withAllowedCharacters: Self.hostCharacters) ?? ""
        return URL(string: "\(Self.scheme)://\(kind.rawValue)/\(path)")!
    }
}

public struct LinkResult: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}
