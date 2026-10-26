import Foundation
// hgcmd <cmd>...: posts each argument as a debug command to channel "media", 0.15 s apart.
for (i, c) in CommandLine.arguments.dropFirst().enumerated() {
    if i > 0 { Thread.sleep(forTimeInterval: 0.15) }
    DistributedNotificationCenter.default().postNotificationName(.init("dev.hangar.debug.media"), object: c, userInfo: nil, deliverImmediately: true)
}
Thread.sleep(forTimeInterval: 0.05)
