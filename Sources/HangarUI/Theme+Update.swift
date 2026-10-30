import SwiftUI

/// In-app update tokens (#86): the release-notes box of the update sheet and its progress line.
extension Theme {
    public static let updateNotesHeight: CGFloat = 240
    public static let updateNotesPadding: CGFloat = Space.s3
    public static let updateNotesLineGap: CGFloat = 3
    public static let updateProgressHeight: CGFloat = 4
    /// The status line under the notes keeps its height when empty: nothing below it jumps.
    public static let updateStatusHeight: CGFloat = 18
}
