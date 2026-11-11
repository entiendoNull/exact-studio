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

    /// A device's exact silhouette: bezel, screen and side buttons, without the
    /// window panel around it. `mask` is white where the device is, sized to
    /// `rect` (the silhouette's bounding box, unit coordinates of the frame).
    struct Silhouette { var rect: UnitRect; var mask: CGImage }

    /// Starting from the frame's edges, everything the panel's colour (or
    /// transparency) reaches is background. Of what remains, the largest
    /// piece is the device: the bezel ring encloses the screen, so the screen
    /// belongs to it however light it is, and the side buttons touch it. The
    /// title and the toolbar's icons are smaller pieces and are dropped. The
    /// edge is pulled in by a pixel so no panel colour fringes it.
    static func silhouette(_ image: CGImage) -> Silhouette? {
        let w = image.width, h = image.height
        guard w > 40, h > 40,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        let n = w * h

        // The panel's colour: the median of the opaque pixels a few pixels in from the edges.
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        let inset = 4
        func sample(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            if px[i + 3] > 200 { rs.append(px[i]); gs.append(px[i + 1]); bs.append(px[i + 2]) }
        }
        for x in stride(from: 0, to: w, by: 2) { sample(x, inset); sample(x, h - 1 - inset) }
        for y in stride(from: 0, to: h, by: 2) { sample(inset, y); sample(w - 1 - inset, y) }
        guard rs.count > 20 else { return nil }
        let med = { (v: [UInt8]) -> Int in Int(v.sorted()[v.count / 2]) }
        let br = med(rs), bg = med(gs), bb = med(bs)
        func background(_ i: Int) -> Bool {
            let a = px[i * 4 + 3]
            if a < 128 { return true }
            return abs(Int(px[i * 4]) - br) < 34 && abs(Int(px[i * 4 + 1]) - bg) < 34 && abs(Int(px[i * 4 + 2]) - bb) < 34
        }

        // Flood the background in from the edges.
        var state = [UInt8](repeating: 0, count: n) // 0 unknown, 1 outside, 2 device candidate, 3 kept
        var stack: [Int] = []
        stack.reserveCapacity(n / 4)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard state[i] == 0, background(i) else { continue }
            state[i] = 1
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }

        // The largest piece of what is left.
        var best: [Int] = []
        for start in 0..<n where state[start] == 0 {
            var piece: [Int] = []
            stack.append(start)
            state[start] = 2
            while let i = stack.popLast() {
                piece.append(i)
                let x = i % w, y = i / w
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1] where j >= 0 && state[j] == 0 {
                    state[j] = 2
                    stack.append(j)
                }
            }
            if piece.count > best.count { best = piece }
        }
        guard best.count > n / 10 else { return nil }
        var minX = w, maxX = 0, minY = h, maxY = 0
        for i in best {
            state[i] = 3
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        // Nearly the whole frame: there was no panel around a device to take away.
        guard Double(maxX - minX) < Double(w) * 0.985 || Double(maxY - minY) < Double(h) * 0.985 else { return nil }

        // The mask over the bounding box, pulled in by one pixel.
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        var mask = [UInt8](repeating: 0, count: bw * bh)
        for y in minY...maxY {
            for x in minX...maxX {
                let i = y * w + x
                guard state[i] == 3 else { continue }
                let inside = x > 0 && x < w - 1 && y > 0 && y < h - 1
                    && state[i - 1] == 3 && state[i + 1] == 3 && state[i - w] == 3 && state[i + w] == 3
                if inside { mask[(y - minY) * bw + (x - minX)] = 255 }
            }
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let cg = CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bw,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Silhouette(rect: UnitRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                                         w: Double(bw) / Double(w), h: Double(bh) / Double(h)), mask: cg)
    }

    /// A device's body read from its silhouette: the main block (the side buttons
    /// left out), its corner radius as a share of its width, and each button that
    /// stands out from its sides. Rectangles are unit coordinates of the mask, origin top-left.
    struct Body: Equatable { var rect: UnitRect; var radius: Double; var buttons: [UnitRect] }

    static func body(_ mask: CGImage) -> Body? {
        let w = mask.width, h = mask.height
        guard w > 20, h > 20,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        // Each row's outermost device pixels (the bitmap's first row is the image's top).
        var lefts = [Int?](repeating: nil, count: h), rights = [Int?](repeating: nil, count: h)
        for y in 0..<h {
            var lo = -1, hi = -1
            for x in 0..<w where px[y * w + x] > 127 { if lo < 0 { lo = x }; hi = x }
            if lo >= 0 { lefts[y] = lo; rights[y] = hi }
        }
        guard let top = lefts.firstIndex(where: { $0 != nil }), let bottom = lefts.lastIndex(where: { $0 != nil }), bottom - top > h / 3 else { return nil }
        // The body's sides: the median edge of the middle rows, which the buttons don't move.
        let middle = (top + (bottom - top) / 5)...(bottom - (bottom - top) / 5)
        let ls = middle.compactMap { lefts[$0] }.sorted(), rs = middle.compactMap { rights[$0] }.sorted()
        guard !ls.isEmpty else { return nil }
        let left = ls[ls.count * 7 / 10], right = rs[rs.count * 3 / 10]
        guard right - left > w / 3 else { return nil }
        // The corner: how far down from the top the outline takes to reach the side.
        var corner = 0
        for y in top...bottom { if let l = lefts[y], l <= left + 1 { corner = y - top; break } }
        // The buttons: runs of rows with device pixels beyond the body's sides.
        func runs(_ beyond: (Int) -> Int?) -> [UnitRect] {
            var out: [UnitRect] = [], start = -1, edge = 0, gap = 0
            let minimum = max(4, (bottom - top) / 80)
            for y in top...bottom + 1 {
                let b = y <= bottom ? beyond(y) : nil
                if let b {
                    if start < 0 { start = y; edge = b }
                    edge = b < 0 ? min(edge, b) : max(edge, b)
                    gap = 0
                } else if start >= 0 {
                    gap += 1
                    if gap > 2 || y > bottom {
                        let end = y - gap
                        if end - start + 1 >= minimum {
                            let x0 = edge < 0 ? left + edge : right, x1 = edge < 0 ? left : right + edge
                            out.append(UnitRect(x: Double(x0) / Double(w), y: Double(start) / Double(h),
                                                w: Double(max(1, x1 - x0)) / Double(w), h: Double(end - start + 1) / Double(h)))
                        }
                        start = -1; gap = 0
                    }
                }
            }
            return out
        }
        let leftButtons = runs { y in guard let l = lefts[y], l < left - 2 else { return nil }; return l - left }
        let rightButtons = runs { y in guard let r = rights[y], r > right + 2 else { return nil }; return r - right }
        let bw = Double(right - left + 1)
        return Body(rect: UnitRect(x: Double(left) / Double(w), y: Double(top) / Double(h), w: bw / Double(w), h: Double(bottom - top + 1) / Double(h)),
                    radius: min(0.3, Double(corner) / bw), buttons: leftButtons + rightButtons)
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
