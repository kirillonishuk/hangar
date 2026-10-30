import Exec
import Foundation
import Integration

/// The bundled `Contents/Helpers/hangar` of `bundle`; nil outside a built .app (DEBUG `swift run`):
/// hooks must never point into `.build`.
public func hangarCLIPath(bundle: Bundle) -> String? {
    let path = bundle.bundleURL.appendingPathComponent("Contents/Helpers/hangar").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// A translocated (quarantined, not moved) or DMG-mounted app: hooks would point at a path that disappears.
func installBlocked(cli: String) -> Bool {
    cli.contains("/AppTranslocation/") || cli.hasPrefix("/Volumes/")
}

/// One file «Что изменится» shows: its path (`host:path` on a server) and the collapsed diff of what is written.
struct PlannedChange: Equatable, Identifiable {
    var path: String
    var diff: [DiffLine]
    var id: String { path }
}

@MainActor enum IntegrationModel {
    static func describe(_ error: Error) -> String {
        switch error as? IntegrationError {
        case .invalidJSON(let line)?: L10n.settingsInvalidJSON(line)
        case .notAnObject?: L10n.settingsUnsupported
        case .changedOnDisk?: L10n.fileChanged
        case .readOnly?: L10n.fileReadOnly
        case .otherCopy?: L10n.intOtherCopy
        case .unsupportedNotify?, .invalidTOML?: L10n.codexConfigUnsupported
        case nil: L10n.integrationWriteFailed(error.localizedDescription)
        }
    }
}

func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
