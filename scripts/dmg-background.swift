// Renders the DMG window background (Hangar navy palette, see Sources/HangarUI/Theme.swift).
//   swift scripts/dmg-background.swift out@1x.png out@2x.png
// Layout matches scripts/make-dmg.sh: 640×400 points, Hangar.app at (160,190), Applications at (480,190).
import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let appX: CGFloat = 160, appsX: CGFloat = 480, iconY: CGFloat = 190  // Finder coords: from top-left

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}
let bgTop = hex(0x20293a), bgBottom = hex(0x121826)   // Theme.sidebar → Theme.bg
let arrowColor = hex(0x5f687a)                        // Theme.text3
let plateColor = hex(0xc4cad6)                       // light plate under Finder's black labels
let labelY: CGFloat = 273                             // centre of Finder's 13 pt label under a 128 pt icon
let captionColor = hex(0x8a93a6)                      // Theme.text2

func render(scale: CGFloat, to path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)  // 72 dpi @1x, 144 dpi @2x (needed by tiffutil -cathidpicheck)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext  // already scaled to points by rep.size
    // Flip to Finder-style coordinates (origin top-left).
    cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // Subtle vertical gradient.
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    // Thin arrow between the two icon slots (icons are 128 pt wide).
    let x0 = appX + 64 + 30, x1 = appsX - 64 - 30
    cg.setStrokeColor(arrowColor.cgColor)
    cg.setLineWidth(1.5)
    cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.move(to: CGPoint(x: x0, y: iconY)); cg.addLine(to: CGPoint(x: x1, y: iconY))
    cg.move(to: CGPoint(x: x1 - 9, y: iconY - 7)); cg.addLine(to: CGPoint(x: x1, y: iconY))
    cg.addLine(to: CGPoint(x: x1 - 9, y: iconY + 7))
    cg.strokePath()

    // Finder draws icon labels in black on picture backgrounds (no API to change it),
    // so each label sits on a soft light plate to stay readable on navy.
    let labelFont = NSFont.systemFont(ofSize: 13)
    for (name, x) in [("Hangar", appX), ("Applications", appsX)] {
        let w = (name as NSString).size(withAttributes: [.font: labelFont]).width + 18
        let r = NSRect(x: x - w / 2, y: labelY - 10, width: w, height: 20)
        plateColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
    }

    // Caption, centred below the icon labels.
    func line(_ s: String, size: CGFloat, color: NSColor, y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: color, .paragraphStyle: p])
        a.draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.6))
    }
    line("Drag Hangar to Applications", size: 14, color: captionColor, y: 312)

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: dmg-background.swift out@1x.png out@2x.png\n".data(using: .utf8)!)
    exit(1)
}
try render(scale: 1, to: args[1])
try render(scale: 2, to: args[2])
