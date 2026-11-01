import AppKit
import CoreGraphics
import Foundation
// over <pid> <window.png> <panel.png> <radius pt> <out.png>: SNAP mode's `comp`. The snapped panel (a menu or a sheet,
// drawn by the app with square corners) goes over the snapped window at the panel's on-screen place, its corners cut to
// `radius`, with a shadow. Only window bounds are read (no Screen Recording needed).
let a = CommandLine.arguments
let pid = Int(a[1])!, radius = CGFloat(Double(a[4])!)
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
func rect(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)! }
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int ?? 99) < 1000 }
guard let main = mine.first(where: { rect($0).width == 1440 && rect($0).height == 900 }) else { fatalError("no main window") }
let mr = rect(main)
guard let panel = mine.first(where: { rect($0) != mr && mr.intersects(rect($0)) && rect($0).height > 40 }) else { fatalError("no panel") }
let pr = rect(panel)
func load(_ p: String) -> CGImage { NSImage(contentsOfFile: p)!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
let base = load(a[2]), over = load(a[3])
let W = base.width, H = base.height, scale = CGFloat(W) / mr.width
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
let r = CGRect(x: (pr.minX - mr.minX) * scale, y: CGFloat(H) - (pr.minY - mr.minY + pr.height) * scale, width: pr.width * scale, height: pr.height * scale)
let path = CGPath(roundedRect: r, cornerWidth: radius * scale, cornerHeight: radius * scale, transform: nil)
// The panel clipped to its rounded shape, in a layer that casts the shadow `comp` draws under panels.
ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(path); ctx.clip()
ctx.draw(over, in: r)
ctx.endTransparencyLayer()
FileHandle.standardError.write("over \(pr) at \(r)\n".data(using: .utf8)!)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[5]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
