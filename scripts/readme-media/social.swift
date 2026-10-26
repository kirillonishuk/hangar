import AppKit
// social <icon.png> <screenshot.png> <out.png>: 1280×640 GitHub social preview.
let a = CommandLine.arguments
let W: CGFloat = 1280, H: CGFloat = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1), ending: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1))!  // Dark+ greys
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
// Screenshot, tilted off the right edge.
let shot = NSImage(contentsOfFile: a[2])!
let sw: CGFloat = 760, sh = sw * shot.size.height / shot.size.width
let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState(); shadow.set()
let r = NSRect(x: 560, y: (H - sh) / 2 - 10, width: sw, height: sh)
let clip = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
NSColor.black.setFill(); clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState(); clip.addClip(); shot.draw(in: r); NSGraphicsContext.restoreGraphicsState()
// Icon + text.
NSImage(contentsOfFile: a[1])!.draw(in: NSRect(x: 70, y: 410, width: 140, height: 140))
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = 4
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p])
        .draw(at: NSPoint(x: 76, y: y))
}
text("Hangar", 72, .bold, .white, 305)
text("A native macOS workspace\nfor AI coding agents", 30, .regular, NSColor(srgbRed: 0.8, green: 0.8, blue: 0.82, alpha: 1), 200)
text("Claude Code · Codex · Ghostty terminals", 20, .medium, NSColor(srgbRed: 0.22, green: 0.58, blue: 1, alpha: 1), 150)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
