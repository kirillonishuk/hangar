/// The Hangar theme's terminal colours ("rrggbb"). The 16 ANSI colours load before the user's Ghostty config, so
/// theirs (or their Ghostty theme's) win; background, text and cursor always load after it: they are the app theme's
/// (#109), so a light Ghostty theme's dark text can't land on a dark background.
public struct TerminalColors: Equatable, Sendable {
    public var background: String
    public var foreground: String
    public var palette: [String]
    public var cursor: String

    public init(background: String, foreground: String, palette: [String], cursor: String) {
        self.background = background
        self.foreground = foreground
        self.palette = palette
        self.cursor = cursor
    }
}
