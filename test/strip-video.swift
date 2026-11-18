import AVFoundation
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 640, height = 360, fps: Int32 = 10, seconds = 10
try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
writer.add(input)
guard writer.startWriting() else { exit(1) }
writer.startSession(atSourceTime: .zero)

func fill(_ c: CGContext, _ r: CGRect, _ rgb: (CGFloat, CGFloat, CGFloat), radius: CGFloat = 0) {
    c.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
}

for i in 0...(seconds * Int(fps)) {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let b = buffer else { exit(1) }
    CVPixelBufferLockBaseAddress(b, [])
    let c = CGContext(data: CVPixelBufferGetBaseAddress(b), width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    let H = CGFloat(height)
    fill(c, CGRect(x: 0, y: 0, width: width, height: height), (0.97, 0.97, 0.98))
    fill(c, CGRect(x: 0, y: 0, width: CGFloat(width), height: 34), (0.88, 0.89, 0.91))
    for (k, rgb) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
        fill(c, CGRect(x: 14 + CGFloat(k) * 20, y: 11, width: 12, height: 12), (rgb.0, rgb.1, rgb.2), radius: 6)
    }
    fill(c, CGRect(x: 0, y: 34, width: 150, height: H - 34), (0.92, 0.93, 0.95))
    for k in 0..<6 {
        let active = k == (i / 17) % 6
        if active { fill(c, CGRect(x: 10, y: 50 + CGFloat(k) * 36, width: 130, height: 26), (0.25, 0.47, 0.96), radius: 6) }
        let g: CGFloat = active ? 1 : 0.55
        fill(c, CGRect(x: 22, y: 59 + CGFloat(k) * 36, width: 70 + CGFloat((k * 23) % 40), height: 8), (g, g, g), radius: 4)
    }
    fill(c, CGRect(x: 180, y: 56, width: 240, height: 18), (0.15, 0.16, 0.2), radius: 5)
    for k in 0..<4 {
        fill(c, CGRect(x: 180, y: 96 + CGFloat(k) * 22, width: 400 - CGFloat((k * 57) % 140), height: 9), (0.62, 0.64, 0.68), radius: 4)
    }
    let p = CGFloat(i) / CGFloat(seconds * Int(fps))
    fill(c, CGRect(x: 180, y: 200, width: 420, height: 110), (1, 1, 1), radius: 10)
    fill(c, CGRect(x: 196, y: 216, width: 120, height: 78), (0.98, 0.55, 0.24), radius: 8)
    fill(c, CGRect(x: 332, y: 228, width: 250 * p, height: 14), (0.25, 0.47, 0.96), radius: 7)
    fill(c, CGRect(x: 332, y: 262, width: 120, height: 26), (0.16, 0.66, 0.42), radius: 8)
    CVPixelBufferUnlockBaseAddress(b, [])
    adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
exit(writer.status == .completed ? 0 : 1)
