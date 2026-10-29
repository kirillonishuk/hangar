/// The Hangar theme's terminal colours ("rrggbb"). The 16 ANSI colours load before the user's Ghostty config, so
/// theirs (or their Ghostty theme's) win; the background always loads after it: it is the app theme's (#109).
public struct TerminalColors: Equatable, Sendable {
    public var background: String
    public var palette: [String]
    public var cursor: String

    public init(background: String, palette: [String], cursor: String) {
        self.background = background
        self.palette = palette
        self.cursor = cursor
    }
}
