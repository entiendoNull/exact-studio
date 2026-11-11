// Finds a device's bezel in a captured Simulator or Android emulator window.
// The window is captured on its own with its alpha, so the device is the
// opaque shape and the desktop around it is transparent. Window chrome
// (Simulator's title bar, the emulator's toolbar) is opaque too, so the
// device is taken as the tallest band of rows with opaque pixels, and a
// strip at its top whose opaque width differs from the bezel's is trimmed.
//
// A window drawn opaque around the device (Xcode 27's Device Hub draws the
// device on a white panel, title and toolbar included) has no alpha to go
// by: there the device is its bezel's dark outline, and its corner radius is
// measured from the outline's curve so the frame can be cut to it.
#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation

enum Bezel {
    /// The bezel's rectangle in unit coordinates, or nil when the frame has
    /// no transparency to go by (bezels hidden): then the caller keeps the window.
    static func detect(_ buffer: CVPixelBuffer) -> UnitRect? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        return detect(width: w, height: h) { x, y in p[y * stride + x * 4 + 3] }
    }

    /// A device found by its dark bezel: the rectangle in unit coordinates and
    /// the corner radius as a fraction of the rectangle's width.
    struct Outline { var rect: UnitRect; var radius: Double }

    static func outline(_ buffer: CVPixelBuffer) -> Outline? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        return outline(width: w, height: h) { x, y in
            let i = y * stride + x * 4
            return p[i + 3] > 200 && Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) < 3 * 34
        }
    }

    /// The same over an image (a frame taken from a finished recording).
    static func outline(_ image: CGImage) -> Outline? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)
        // The bitmap's first row is the image's top.
        return outline(width: w, height: h) { x, y in
            let i = (y * w + x) * 4
            return p[i + 3] > 200 && Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) < 3 * 34
        }
    }

    /// The same over any source: `dark(x, y)` says a pixel is bezel-dark, origin top-left.
    static func outline(width w: Int, height h: Int, dark: (Int, Int) -> Bool) -> Outline? {
        guard w > 40, h > 40 else { return nil }
        // Each row's outermost dark pixels; a device row is dark across most of the width.
        var lefts = [Int?](repeating: nil, count: h), rights = [Int?](repeating: nil, count: h)
        for y in 0..<h {
            var lo = -1, hi = -1
            for x in 0..<w where dark(x, y) { if lo < 0 { lo = x }; hi = x }
            if lo >= 0 && hi - lo > w / 2 { lefts[y] = lo; rights[y] = hi }
        }
        // The tallest run of such rows is the device.
        var best = (0, -1), start = -1
        for y in 0...h {
            let on = y < h && lefts[y] != nil
            if on && start < 0 { start = y }
            if !on && start >= 0 { if y - start > best.1 - best.0 + 1 { best = (start, y - 1) }; start = -1 }
        }
        let (top, bottom) = best
        guard bottom - top > h / 3 else { return nil }
        // The sides: the median of the rows' edges, so side buttons sticking out don't count.
        let ls = (top...bottom).compactMap { lefts[$0] }.sorted(), rs = (top...bottom).compactMap { rights[$0] }.sorted()
        let left = ls[ls.count / 2], right = rs[rs.count / 2]
        guard right - left > w / 3 else { return nil }
        // The corner: how far down from the top the outline takes to reach the side.
        var corner = 0
        for y in top...bottom { if let l = lefts[y], l <= left + 1 { corner = y - top; break } }
        let width = Double(right - left + 1)
        return Outline(rect: UnitRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                                      w: width / Double(w), h: Double(bottom - top + 1) / Double(h)),
                       radius: min(0.3, Double(corner) / width))
    }

    /// The same over any alpha source: `alpha(x, y)`, origin top-left.
    static func detect(width w: Int, height h: Int, alpha: (Int, Int) -> UInt8) -> UnitRect? {
        guard w > 8, h > 8 else { return nil }
        let threshold: UInt8 = 200
        var spans = [(Int, Int)?](repeating: nil, count: h)
        var transparent = 0
        for y in 0..<h {
            var lo = -1, hi = -1
            for x in 0..<w where alpha(x, y) >= threshold {
                if lo < 0 { lo = x }
                hi = x
            }
            if lo >= 0 { spans[y] = (lo, hi) }
            if lo != 0 || hi != w - 1 { transparent += 1 }
        }
        // Every row reaches both edges: an ordinary rectangular window.
        guard transparent > h / 20 else { return nil }

        // Bands of consecutive rows that hold opaque pixels; the device is the tallest.
        var best = (0, -1), start = -1
        for y in 0...h {
            let opaque = y < h && spans[y] != nil
            if opaque && start < 0 { start = y }
            if !opaque && start >= 0 {
                if y - start > best.1 - best.0 + 1 { best = (start, y - 1) }
                start = -1
            }
        }
        guard best.1 > best.0 else { return nil }
        var top = best.0, bottom = best.1

        // The bezel's width is the median opaque width of the band.
        let widths = (top...bottom).compactMap { spans[$0].map { $0.1 - $0.0 } }.sorted()
        let median = widths[widths.count / 2]
        // Chrome attached above the device: rows spanning clearly wider than the bezel.
        let wide = { (y: Int) -> Bool in guard let s = spans[y] else { return false }; return Double(s.1 - s.0) > Double(median) * 1.04 }
        // One more row past trimmed chrome: its edge blends into the bezel's first row.
        if wide(top) { while top < bottom, wide(top) { top += 1 }; top = min(top + 2, bottom) }
        if wide(bottom) { while bottom > top, wide(bottom) { bottom -= 1 }; bottom = max(bottom - 2, top) }

        var lo = w, hi = 0
        for y in top...bottom { if let s = spans[y], Double(s.1 - s.0) <= Double(median) * 1.04 { lo = min(lo, s.0); hi = max(hi, s.1) } }
        guard hi > lo else { return nil }
        return UnitRect(x: Double(lo) / Double(w), y: Double(top) / Double(h),
                        w: Double(hi - lo + 1) / Double(w), h: Double(bottom - top + 1) / Double(h))
    }
}
#endif
