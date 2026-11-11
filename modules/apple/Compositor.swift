// The editor's look and edits, rendered per frame: the captured source
// cropped to its subject (a device's bezel, an area, a window), framed on a
// background with padding, rounded corners and a shadow; zoomed in or out
// over the zoom track's segments, following the cursor; and touched by the
// effects track. Cuts and speed are the composition's (Editor.swift); every
// time here is the source recording's. The preview and the export share
// this one function, so what plays is what exports. No Exact types here: a
// test harness compiles it alone.
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

/// What the person chose for the frame.
struct Look: Codable, Equatable {
    var background = "ocean"
    /// Padding around the subject, a percentage of the canvas's shorter side.
    var padding = 8.0
    /// Corner radius in output pixels; devices keep their bezel's own shape.
    var radius = 14.0
    var shadow = true
    /// "auto" (the subject's own shape), "16:9", "9:16", "1:1" or "4:3".
    var aspect = "16:9"

    static func parse(_ json: String) -> Look {
        guard let data = json.data(using: .utf8), let look = try? JSONDecoder().decode(Look.self, from: data) else { return Look() }
        return look
    }
}

/// One span on the timeline. `kind` is "cut", "zoom", "speed", or a visual
/// effect ("spotlight", "highlight", "blur", "mono"); `level` is a zoom's
/// (below 1 zooms out), `rate` a speed's. Cuts sit on the clip; everything
/// else on a lane, any lane, as many lanes as the person makes.
struct Segment: Codable, Equatable {
    var id: String
    var kind: String
    var start: Double
    var end: Double
    var lane: Int = 0
    var level: Double?
    var rate: Double?

    static let visual = ["spotlight", "highlight", "blur", "mono"]
    static let kinds = ["cut", "zoom", "speed"] + visual

    /// Two segments may overlap in time unless they share a group: one zoom at
    /// a time, one speed at a time, one of each visual effect at a time.
    var group: String { kind }

    func overlaps(_ o: Segment) -> Bool { start < o.end - 0.0001 && o.start < end - 0.0001 }
}

/// A recording's edits, all in source seconds.
struct Edits: Codable, Equatable {
    var segments: [Segment] = []

    var cuts: [Segment] { segments.filter { $0.kind == "cut" } }
    var zooms: [Segment] { segments.filter { $0.kind == "zoom" } }
    var speeds: [Segment] { segments.filter { $0.kind == "speed" } }
    var effects: [Segment] { segments.filter { Segment.visual.contains($0.kind) } }
    /// The lanes in use, at least one.
    var lanes: Int { max(1, (segments.filter { $0.kind != "cut" }.map(\.lane).max() ?? -1) + 1) }

    /// Why `s` cannot sit where it is, or nil when it can: a same-group
    /// segment overlapping it anywhere, or any segment overlapping it on its lane.
    func conflict(_ s: Segment) -> String? {
        for o in segments where o.id != s.id && o.overlaps(s) {
            if o.group == s.group && s.kind != "cut" { return "Two \(Segment.noun(s.kind)) can’t overlap." }
            if s.kind != "cut" && o.kind != "cut" && o.lane == s.lane { return "That lane is taken there; drop it on another lane." }
        }
        return nil
    }

    /// Zooms where the clicks are: clicks less than 3 s apart share one,
    /// which holds for a beat after its last click.
    static func autoZooms(_ clicks: [Point], duration: Double, level: Double = 2) -> [Segment] {
        var out: [Segment] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            let s = max(0, c.t - 0.8), e = min(duration, c.t + 2.2)
            if let last = out.last, s - last.end < 1.0 {
                out[out.count - 1].end = e
            } else {
                out.append(Segment(id: "z\(out.count)-\(Int(c.t * 1000))", kind: "zoom", start: s, end: e, lane: 0, level: level))
            }
        }
        return out.filter { $0.end - $0.start > 0.3 }
    }
}

extension Segment {
    static func noun(_ kind: String) -> String {
        ["cut": "cuts", "zoom": "zooms", "speed": "speed changes", "spotlight": "spotlights",
         "highlight": "cursor highlights", "blur": "blurs", "mono": "black-and-white effects"][kind] ?? "effects"
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

/// How far into a segment's effect `t` is: 0 outside, easing to 1 over `ramp` seconds at each end.
func presence(_ s: Segment, at t: Double, ramp: Double) -> Double {
    let r = min(ramp, (s.end - s.start) / 2)
    guard t > s.start, t < s.end, r > 0 else { return 0 }
    let v = min((t - s.start) / r, (s.end - t) / r, 1)
    // A smootherstep: no visible jolt at either end.
    return v * v * v * (v * (v * 6 - 15) + 10)
}

/// The cursor in the subject's unit coordinates, looked up by time.
struct CursorPath {
    let samples: [Point]

    /// The cursor at `t`, averaged over a short window so the camera glides.
    func smoothed(at t: Double, window: Double = 0.35) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count
        while lo < hi { let mid = (lo + hi) / 2; if samples[mid].t < t - window { lo = mid + 1 } else { hi = mid } }
        var sx = 0.0, sy = 0.0, n = 0.0, i = lo
        while i < samples.count, samples[i].t <= t + window * 0.3 {
            let w = 1 - abs(samples[i].t - t) / window
            sx += samples[i].x * w; sy += samples[i].y * w; n += w
            i += 1
        }
        if n > 0 { return CGPoint(x: sx / n, y: sy / n) }
        let p = samples[min(lo, samples.count - 1)]
        return CGPoint(x: p.x, y: p.y)
    }

    /// The cursor at `t`, unsmoothed (an effect drawn under it).
    func at(_ t: Double) -> CGPoint? { smoothed(at: t, window: 0.05) }
}

/// One recording's framing: everything per frame except the frame itself.
struct Framing {
    let canvas: CGSize
    /// The subject's rectangle on the canvas, Core Image coordinates (origin bottom-left).
    let subject: CGRect
    let crop: UnitRect
    let rounded: Bool
    let look: Look
    let edits: Edits
    let cursor: CursorPath
    private let background: CIImage

    init(source: CGSize, crop: UnitRect, device: Bool, look: Look, edits: Edits, cursor: [Point]) {
        self.crop = crop
        self.look = look
        self.edits = edits
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
        self.cursor = CursorPath(samples: cursor.map(toCrop))
        background = Backgrounds.image(look.background, size: canvas)
    }

    /// A point in the subject's unit coordinates, on the canvas.
    private func onCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: subject.minX + min(max(p.x, 0), 1) * subject.width,
                y: subject.minY + (1 - min(max(p.y, 0), 1)) * subject.height)
    }

    func render(_ frame: CIImage, at t: Double) -> CIImage {
        let e = frame.extent
        let cropRect = CGRect(x: e.minX + crop.x * e.width, y: e.minY + (1 - crop.y - crop.h) * e.height,
                              width: crop.w * e.width, height: crop.h * e.height)
        var subjectImage = frame.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: subject.width / cropRect.width, y: subject.height / cropRect.height))
            .transformed(by: CGAffineTransform(translationX: subject.minX, y: subject.minY))

        // Effects on the subject's pixels, before its shape is cut.
        let minSide = min(canvas.width, canvas.height)
        var overlays: [CIImage] = []
        for fx in edits.effects {
            let a = presence(fx, at: t, ramp: 0.25)
            guard a > 0.001 else { continue }
            switch fx.kind {
            case "blur":
                subjectImage = subjectImage.clampedToExtent().applyingGaussianBlur(sigma: 24 * a).cropped(to: subject)
            case "mono":
                let c = CIFilter.colorControls()
                c.inputImage = subjectImage
                c.saturation = Float(1 - a)
                subjectImage = c.outputImage!.cropped(to: subject)
            case "spotlight":
                guard let p = cursor.smoothed(at: t, window: 0.2) else { continue }
                let g = CIFilter.radialGradient()
                g.center = onCanvas(p)
                g.radius0 = Float(minSide * 0.09)
                g.radius1 = Float(minSide * 0.16)
                g.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.62 * a)
                overlays.append(g.outputImage!.cropped(to: subject))
            case "highlight":
                guard let p = cursor.at(t) else { continue }
                let g = CIFilter.radialGradient()
                g.center = onCanvas(p)
                g.radius0 = Float(minSide * 0.022)
                g.radius1 = Float(minSide * 0.03)
                g.color0 = CIColor(red: 1, green: 0.84, blue: 0.2, alpha: 0.45 * a)
                g.color1 = CIColor(red: 1, green: 0.84, blue: 0.2, alpha: 0)
                overlays.append(g.outputImage!.cropped(to: subject))
            default:
                continue
            }
        }
        for o in overlays { subjectImage = o.composited(over: subjectImage) }

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
        } else if !rounded {
            // A device keeps its bezel's shape: the source's alpha. Effects drawn
            // over the whole subject rectangle are cut back to it.
            let source = frame.cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                .transformed(by: CGAffineTransform(scaleX: subject.width / cropRect.width, y: subject.height / cropRect.height))
                .transformed(by: CGAffineTransform(translationX: subject.minX, y: subject.minY))
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = subjectImage
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = source
            subjectImage = blend.outputImage!.cropped(to: subject)
        }

        // The subject and its shadow are one layer; the zoom moves that layer over a still background.
        var layer = subjectImage
        if look.shadow {
            let blur = minSide * 0.025
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
            layer = subjectImage.composited(over: shadow)
        }

        let canvasRect = CGRect(origin: .zero, size: canvas)
        let (s, c) = camera(at: t)
        if abs(s - 1) > 0.0005 {
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        }
        return layer.composited(over: background).cropped(to: canvasRect)
    }

    /// The zoom at `t`: its scale, and the canvas point it centres.
    func camera(at t: Double) -> (CGFloat, CGPoint) {
        let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var s = 1.0, amount = 0.0
        for z in edits.zooms {
            let a = presence(z, at: t, ramp: 0.7)
            if a > amount { amount = a; s = 1 + ((z.level ?? 2) - 1) * a }
        }
        guard amount > 0.0005 else { return (1, mid) }
        // In: toward the cursor (or the subject's centre). Out: about the centre.
        guard s > 1 else { return (CGFloat(s), mid) }
        let f = cursor.smoothed(at: t) ?? CGPoint(x: 0.5, y: 0.5)
        let target = onCanvas(f)
        var c = CGPoint(x: mid.x + (target.x - mid.x) * amount, y: mid.y + (target.y - mid.y) * amount)
        let half = CGSize(width: canvas.width / s / 2, height: canvas.height / s / 2)
        c.x = min(max(c.x, half.width), canvas.width - half.width)
        c.y = min(max(c.y, half.height), canvas.height - half.height)
        return (CGFloat(s), c)
    }
}

/// Source time to output time and back, across cuts and speed changes.
struct TimeMap {
    struct Piece { var src0: Double, src1: Double, out0: Double, rate: Double
        var out1: Double { out0 + (src1 - src0) / rate } }
    let pieces: [Piece]
    let duration: Double

    init(duration: Double, edits: Edits) {
        self.duration = duration
        var marks = Set([0.0, duration])
        for s in edits.cuts + edits.speeds { marks.insert(min(max(s.start, 0), duration)); marks.insert(min(max(s.end, 0), duration)) }
        let sorted = marks.sorted()
        var out: [Piece] = [], at = 0.0
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 0.001 {
            let m = (a + b) / 2
            if edits.cuts.contains(where: { m > $0.start && m < $0.end }) { continue }
            let rate = edits.speeds.last(where: { m > $0.start && m < $0.end })?.rate ?? 1
            if let last = out.last, last.rate == rate, abs(last.src1 - a) < 0.0005 {
                out[out.count - 1].src1 = b
            } else {
                out.append(Piece(src0: a, src1: b, out0: at, rate: rate))
            }
            at = out.last!.out1
        }
        pieces = out
    }

    var outputDuration: Double { pieces.last?.out1 ?? 0 }

    func source(_ out: Double) -> Double {
        guard let p = pieces.first(where: { out < $0.out1 }) ?? pieces.last else { return out }
        return min(p.src1, p.src0 + max(0, out - p.out0) * p.rate)
    }

    /// The output time of a source instant; one inside a cut lands where the cut ends.
    func output(_ src: Double) -> Double {
        for p in pieces {
            if src < p.src0 { return p.out0 }
            if src <= p.src1 { return p.out0 + (src - p.src0) / p.rate }
        }
        return outputDuration
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

    var isDevice: Bool { kind == "simulator" || kind == "emulator" }
}

enum Composition {
    /// The recording with its cuts and speed changes, and the video
    /// composition that draws `look` and the zooms and effects over it.
    static func make(asset: AVAsset, meta: RecordingMeta, cursor: [Point], look: Look, edits: Edits) throws -> (AVAsset, AVMutableVideoComposition, TimeMap) {
        guard let source = asset.tracks(withMediaType: .video).first else { throw CompositionError.noVideo }
        let duration = min(meta.duration, asset.duration.seconds)
        let map = TimeMap(duration: duration, edits: edits)
        let mix = AVMutableComposition()
        guard let track = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CompositionError.noVideo }
        let start = source.timeRange.start
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 6000) }
        for p in map.pieces {
            let range = CMTimeRange(start: start + time(p.src0), end: start + time(p.src1))
            let at = mix.duration
            try track.insertTimeRange(range, of: source, at: at)
            if p.rate != 1 {
                track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: time((p.src1 - p.src0) / p.rate))
            }
        }
        let framing = Framing(source: CGSize(width: meta.width, height: meta.height), crop: meta.crop,
                              device: meta.isDevice, look: look, edits: edits, cursor: cursor)
        let composition = AVMutableVideoComposition(asset: mix) { request in
            let t = map.source(request.compositionTime.seconds)
            request.finish(with: framing.render(request.sourceImage, at: t), context: nil)
        }
        composition.renderSize = framing.canvas
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return (mix, composition, map)
    }

    enum CompositionError: Error, CustomStringConvertible {
        case noVideo
        var description: String { "The recording has no video." }
    }
}
#endif
