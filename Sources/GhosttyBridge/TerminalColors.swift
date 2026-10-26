/// The Hangar theme's terminal colours ("rrggbb"). Background and the 16 ANSI colours load before the user's Ghostty
/// config, so the user's own (or their Ghostty theme's) win; `forceBackground` («Фон терминала: как тема») puts the
/// background after it instead, so it wins over theirs (decision #36).
public struct TerminalColors: Equatable, Sendable {
    public var background: String
    public var palette: [String]
    public var cursor: String
    public var forceBackground: Bool

    public init(background: String, palette: [String], cursor: String, forceBackground: Bool) {
        self.background = background
        self.palette = palette
        self.cursor = cursor
        self.forceBackground = forceBackground
    }
}
