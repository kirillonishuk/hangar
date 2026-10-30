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
// screencapture -l on a child window (a sheet) returns the whole window group: that capture becomes the base. Other panels
// (popovers, the palette) are captured on their own and drawn over it at their place.
let shots = overlays.map { ($0, shot($0)) }
func isGroup(_ img: NSImage?) -> Bool { img.map { abs($0.size.width - mr.width) < 2 && abs($0.size.height - mr.height) < 2 } ?? false }
guard let base = shots.last(where: { isGroup($0.1) })?.1 ?? shot(main) else { FileHandle.standardError.write("capture failed\n".data(using: .utf8)!); exit(1) }
let rep = base.representations[0]
let scale = CGFloat(rep.pixelsWide) / mr.width
let W = rep.pixelsWide, H = rep.pixelsHigh
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(base.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: CGRect(x: 0, y: 0, width: W, height: H))
for (w, image) in shots where !isGroup(image) {
    guard let img = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let r = rect(w)
    let x = (r.minX - mr.minX) * scale, yTop = (r.minY - mr.minY) * scale
    // -o drops the window's own shadow (it would change the capture's bounds): a similar one is drawn under the panel.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.45))
    ctx.draw(img, in: CGRect(x: x, y: CGFloat(H) - yTop - r.height * scale, width: r.width * scale, height: r.height * scale))
    ctx.restoreGState()
    FileHandle.standardError.write("overlay \(w[kCGWindowNumber as String]!) \(r)\n".data(using: .utf8)!)
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
