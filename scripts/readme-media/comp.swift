import AppKit
import CoreGraphics
import Foundation
// comp <pid> <out.png>: the 1440×900 main window plus the app's on-screen panels/sheets over it, each captured
// by window id (never a screen region, so no other app can leak in).
let pid = Int(CommandLine.arguments[1])!, out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
func rect(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)! }
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int ?? 99) < 1000 }
FileHandle.standardError.write("mine=\(mine.count) \(mine.map { rect($0) })\n".data(using: .utf8)!)
guard let main = mine.first(where: { rect($0).width == 1440 && rect($0).height == 900 }) ?? mine.max(by: { rect($0).width < rect($1).width }) else { fatalError("no main window") }
let mr = rect(main)
let overlays = mine.filter { rect($0) != mr && mr.intersects(rect($0)) && rect($0).height > 40 }.reversed()  // back to front
func shot(_ w: [String: Any]) -> NSImage? {
    let id = w[kCGWindowNumber as String] as! Int
    let p = NSTemporaryDirectory() + "w\(id).png"
    let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    t.arguments = ["-l", "\(id)", "-o", "-x", p]; try! t.run(); t.waitUntilExit()
    return NSImage(contentsOfFile: p)
}
// screencapture -l on a child window (palette, popover, sheet) returns the whole window group.
guard let base = overlays.last.flatMap(shot) ?? shot(main) else { FileHandle.standardError.write("capture failed\n".data(using: .utf8)!); exit(1) }
let rep = base.representations[0]
let scale = CGFloat(rep.pixelsWide) / mr.width
let W = rep.pixelsWide, H = rep.pixelsHigh
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(base.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: W, height: H))
for w in [[String: Any]]() {
    let r = rect(w), img = shot(w)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let x = (r.minX - mr.minX) * scale, yTop = (r.minY - mr.minY) * scale
    ctx.draw(img, in: CGRect(x: x, y: CGFloat(H) - yTop - r.height * scale, width: r.width * scale, height: r.height * scale))
    FileHandle.standardError.write("overlay \(w[kCGWindowNumber as String]!) \(r)\n".data(using: .utf8)!)
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
