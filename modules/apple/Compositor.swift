// The editor's look, applied per frame: the captured source cropped to its
// subject (a device's bezel, an area, a window), framed on a background with
// padding, rounded corners and a shadow, and zoomed toward the cursor around
// clicks. The preview and the export share this one function, so what plays
// is what exports. No Exact types here: a test harness compiles it alone.
#if os(macOS)
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A rectangle in unit coordinates, origin top-left.
struct UnitRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
}

/// A cursor sample or a click: seconds from the recording's first frame,
/// and a position in the capture's unit coordinates (origin top-left).
struct Point: Codable { var t: Double, x: Double, y: Double }

/// What the person chose in the editor.
struct Look: Codable, Equatable {
    var background = "ocean"
    /// Padding around the subject, a percentage of the canvas's shorter side.
    var padding = 8.0
    /// Corner radius in output pixels; devices keep their bezel's own shape.
    var radius = 14.0
    var shadow = true
    var zoom = true
    var zoomLevel = 2.0
    /// "auto" (the subject's own shape), "16:9", "9:16", "1:1" or "4:3".
    var aspect = "16:9"

    static func parse(_ json: String) -> Look {
        guard let data = json.data(using: .utf8), let look = try? JSONDecoder().decode(Look.self, from: data) else { return Look() }
        return look
    }
}

/// The background presets: two colours on a diagonal.
enum Backgrounds {
    static let presets: [String: (CIColor, CIColor)] = [
        "ocean": (CIColor(red: 0.13, green: 0.36, blue: 0.85), CIColor(red: 0.20, green: 0.78, blue: 0.86)),
        "sunset": (CIColor(red: 0.98, green: 0.45, blue: 0.35), CIColor(red: 0.62, green: 0.25, blue: 0.80)),
        "mint": (CIColor(red: 0.16, green: 0.66, blue: 0.52), CIColor(red: 0.73, green: 0.93, blue: 0.62)),
        "midnight": (CIColor(red: 0.06, green: 0.07, blue: 0.16), CIColor(red: 0.22, green: 0.18, blue: 0.42)),
        "graphite": (CIColor(red: 0.16, green: 0.16, blue: 0.18), CIColor(red: 0.36, green: 0.37, blue: 0.40)),
        "paper": (CIColor(red: 0.95, green: 0.94, blue: 0.92), CIColor(red: 0.86, green: 0.85, blue: 0.83)),
    ]

    static func image(_ name: String, size: CGSize) -> CIImage {
        let (a, b) = presets[name] ?? presets["ocean"]!
        let g = CIFilter.linearGradient()
        g.point0 = CGPoint(x: 0, y: size.height)
        g.point1 = CGPoint(x: size.width, y: 0)
        g.color0 = a
        g.color1 = b
        return g.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// Where the camera is at each instant: zoomed in around clicks, following
/// the cursor while in. Deterministic in `t`, so scrubbing and export agree.
struct ZoomPlan {
    struct Segment { var start: Double, end: Double }
    let segments: [Segment]
    let cursor: [Point]
    let level: Double

    static let easeIn = 0.7, easeOut = 0.9

    init(clicks: [Point], cursor: [Point], level: Double, enabled: Bool) {
        self.cursor = cursor
        self.level = max(1, level)
        guard enabled else { segments = []; return }
        // Clicks less than 3 s apart share one zoom; each zoom holds for a beat after its last click.
        var out: [Segment] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            let s = Segment(start: c.t - 0.25, end: c.t + 1.8)
            if let last = out.last, s.start - last.end < 1.2 {
                out[out.count - 1].end = s.end
            } else {
                out.append(s)
            }
        }
        segments = out
    }

    /// 0 when out, 1 when fully in.
    func amount(at t: Double) -> Double {
        var best = 0.0
        for s in segments {
            let rise = ease((t - (s.start - ZoomPlan.easeIn)) / ZoomPlan.easeIn)
            let fall = ease((s.end + ZoomPlan.easeOut - t) / ZoomPlan.easeOut)
            best = max(best, min(rise, fall))
        }
        return best
    }

    /// The cursor at `t`, averaged over a short window so the camera glides.
    func focus(at t: Double) -> CGPoint? {
        guard !cursor.isEmpty else { return nil }
        let window = 0.35
        var sx = 0.0, sy = 0.0, n = 0.0
        // The samples are in time order: find the window by binary search.
        var lo = 0, hi = cursor.count
        while lo < hi { let mid = (lo + hi) / 2; if cursor[mid].t < t - window { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < cursor.count, cursor[i].t <= t + window * 0.3 {
            let w = 1 - abs(cursor[i].t - t) / window
            sx += cursor[i].x * w; sy += cursor[i].y * w; n += w
            i += 1
        }
        if n > 0 { return CGPoint(x: sx / n, y: sy / n) }
        let nearest = cursor[min(lo, cursor.count - 1)]
        return CGPoint(x: nearest.x, y: nearest.y)
    }

    private func ease(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        // A smootherstep: no visible jolt at either end.
        return v * v * v * (v * (v * 6 - 15) + 10)
    }
}

/// One recording's framing: everything per frame except the frame itself.
struct Framing {
    let canvas: CGSize
    /// The subject's rectangle on the canvas, Core Image coordinates (origin bottom-left).
    let subject: CGRect
    let crop: UnitRect
    let rounded: Bool
    let look: Look
    let plan: ZoomPlan
    private let background: CIImage

    init(source: CGSize, crop: UnitRect, device: Bool, look: Look, clicks: [Point], cursor: [Point]) {
        self.crop = crop
        self.look = look
        rounded = !device
        let content = CGSize(width: source.width * crop.w, height: source.height * crop.h)
        let ratio: Double
        switch look.aspect {
        case "16:9": ratio = 16.0 / 9
        case "9:16": ratio = 9.0 / 16
        case "1:1": ratio = 1
        case "4:3": ratio = 4.0 / 3
        default: ratio = max(content.width, 1) / max(content.height, 1)
        }
        // The long side at 1920, or the source's own size when larger, rounded to even pixels.
        let long = max(1920, min(3840, max(content.width, content.height)))
        let w = ratio >= 1 ? long : long * ratio, h = ratio >= 1 ? long / ratio : long
        canvas = CGSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
        let pad = min(canvas.width, canvas.height) * look.padding / 100
        let room = CGSize(width: canvas.width - pad * 2, height: canvas.height - pad * 2)
        let k = min(room.width / max(content.width, 1), room.height / max(content.height, 1))
        let size = CGSize(width: content.width * k, height: content.height * k)
        subject = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        // Cursor positions arrive in the capture's coordinates: move them into the crop's.
        let toCrop = { (p: Point) -> Point in Point(t: p.t, x: (p.x - crop.x) / crop.w, y: (p.y - crop.y) / crop.h) }
        let inside = { (p: Point) -> Bool in p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1 }
        let local = cursor.map(toCrop)
        let localClicks = clicks.map(toCrop).filter(inside)
        plan = ZoomPlan(clicks: localClicks, cursor: local, level: look.zoomLevel, enabled: look.zoom)
        background = Backgrounds.image(look.background, size: canvas)
    }

    func render(_ frame: CIImage, at t: Double) -> CIImage {
        let e = frame.extent
        let cropRect = CGRect(x: e.minX + crop.x * e.width, y: e.minY + (1 - crop.y - crop.h) * e.height,
                              width: crop.w * e.width, height: crop.h * e.height)
        var subjectImage = frame.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: subject.width / cropRect.width, y: subject.height / cropRect.height))
            .transformed(by: CGAffineTransform(translationX: subject.minX, y: subject.minY))
        if rounded && look.radius > 0 {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = subject
            mask.radius = Float(look.radius)
            mask.color = .white
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = subjectImage
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask.outputImage
            subjectImage = blend.outputImage!.cropped(to: subject)
        }
        var scene = background
        if look.shadow {
            let blur = min(canvas.width, canvas.height) * 0.025
            let silhouette = CIFilter.colorMatrix()
            silhouette.inputImage = subjectImage
            silhouette.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.45)
            let shadow = silhouette.outputImage!
                .clampedToExtent().cropped(to: subject)
                .applyingGaussianBlur(sigma: blur)
                .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.5))
            scene = shadow.composited(over: scene)
        }
        scene = subjectImage.composited(over: scene)
        let canvasRect = CGRect(origin: .zero, size: canvas)

        let amount = plan.amount(at: t)
        guard amount > 0.001 else { return scene.cropped(to: canvasRect) }
        let s = 1 + (plan.level - 1) * amount
        // The point to zoom toward, on the canvas: the cursor, or the subject's centre.
        let f = plan.focus(at: t) ?? CGPoint(x: 0.5, y: 0.5)
        let target = CGPoint(x: subject.minX + min(max(f.x, 0), 1) * subject.width,
                             y: subject.minY + (1 - min(max(f.y, 0), 1)) * subject.height)
        let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var c = CGPoint(x: mid.x + (target.x - mid.x) * amount, y: mid.y + (target.y - mid.y) * amount)
        // Keep the view inside the canvas.
        let half = CGSize(width: canvas.width / s / 2, height: canvas.height / s / 2)
        c.x = min(max(c.x, half.width), canvas.width - half.width)
        c.y = min(max(c.y, half.height), canvas.height - half.height)
        let zoom = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y))
        return scene.transformed(by: zoom).cropped(to: canvasRect)
    }
}

/// A recording on disk, as the capture left it.
struct RecordingMeta: Codable {
    var id: String
    var name: String
    var kind: String
    var created: Double
    var duration: Double
    var width: Double
    var height: Double
    var crop: UnitRect
    var clicks: [Point]
}

enum Composition {
    /// The video composition that draws `look` over the recording at `folder`.
    static func make(asset: AVAsset, meta: RecordingMeta, cursor: [Point], look: Look) -> AVMutableVideoComposition {
        let framing = Framing(source: CGSize(width: meta.width, height: meta.height), crop: meta.crop,
                              device: meta.kind == "simulator" || meta.kind == "emulator",
                              look: look, clicks: meta.clicks, cursor: cursor)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let t = request.compositionTime.seconds
            request.finish(with: framing.render(request.sourceImage, at: t), context: nil)
        }
        composition.renderSize = framing.canvas
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return composition
    }
}
#endif
