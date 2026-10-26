import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
// mkvideo <frames dir with index.txt> <out.mp4> <out.gif> <gifWidth>
let a = CommandLine.arguments
let dir = a[1], mp4 = URL(fileURLWithPath: a[2]), gif = URL(fileURLWithPath: a[3]), gifW = Int(a[4])!
let lines = try! String(contentsOfFile: dir + "/index.txt", encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ") }
let t0 = Double(lines[0][0])!
let frames: [(Double, String)] = lines.map { (Double($0[0])! - t0, dir + "/" + $0[1]) }
let hold = 2.0
func cg(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }

// MP4: real capture timestamps as presentation times.
let W = 1440, H = 900
try? FileManager.default.removeItem(at: mp4)
let writer = try! AVAssetWriter(outputURL: mp4, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoMaxKeyFrameIntervalKey: 60]])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
func buffer(_ img: CGImage) -> CVPixelBuffer {
    var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let b = pb!; CVPixelBufferLockBaseAddress(b, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b),
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(b, []); return b
}
var last: CVPixelBuffer?
for (t, p) in frames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    let b = buffer(cg(p)); last = b
    adaptor.append(b, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
}
while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
adaptor.append(last!, withPresentationTime: CMTime(seconds: frames.last!.0 + hold, preferredTimescale: 600))
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }; done.wait()
print("mp4", writer.status.rawValue, writer.error as Any)

// GIF: same timing, scaled down; identical consecutive frames merged.
let gh = gifW * H / W
let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (i, (t, p)) in frames.enumerated() {
    let next = i + 1 < frames.count ? frames[i + 1].0 : t + hold
    let ctx = CGContext(data: nil, width: gifW, height: gh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cg(p), in: CGRect(x: 0, y: 0, width: gifW, height: gh))
    let delay = max(0.02, (next - t * 1).rounded(toPlaces: 2))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: next - t,
                                                                                         kCGImagePropertyGIFUnclampedDelayTime: next - t]] as CFDictionary)
    _ = delay
}
print("gif", CGImageDestinationFinalize(dest))
extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m } }
