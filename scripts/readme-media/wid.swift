import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, b["X"] ?? 0, b["Y"] ?? 0, w[kCGWindowLayer as String]!, b["Width"] ?? 0, b["Height"] ?? 0, w[kCGWindowName as String] ?? "", w[kCGWindowIsOnscreen as String] ?? false)
}
