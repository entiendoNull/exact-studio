// The editor's model and its rendering. Every edit lives here as data
// (Edits, Look, RecordingMeta); Framing renders one source frame with all of
// it applied; Composition builds the playable, exportable composition, and
// StudioCompositor is the AVVideoCompositing that draws it, two tracks at a
// time where a crossfade overlaps them. Times are the source recording's
// unless named `out`. No Exact types here: a test harness compiles it alone.
#if os(macOS)
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

// MARK: - Model

/// A rectangle in unit coordinates, origin top-left.
struct UnitRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
}

/// A cursor sample or a click: seconds from the recording's first frame,
/// and a position in the capture's unit coordinates (origin top-left).
struct Point: Codable { var t: Double, x: Double, y: Double }

/// What the person chose for the frame and the cursor.
struct Look: Codable, Equatable {
    /// A preset's name, "custom", or "video" (the recording itself, blurred).
    var background = "ocean"
    var customA = "#6A11CB"
    var customB = "#2575FC"
    var customAngle = 135.0
    var customRadial = false
    /// Padding around the subject, a percentage of the canvas's shorter side.
    var padding = 8.0
    /// Corner radius in output pixels; devices keep their bezel's own shape.
    var radius = 14.0
    var shadow = true
    /// "auto" (the subject's own shape), "16:9", "9:16", "1:1" or "4:3".
    var aspect = "16:9"
    /// The drawn cursor (recordings made without the system's in the picture).
    var cursor = true
    var cursorSize = 1.5
    var clickEffect = true
    var smoothCursor = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Look()
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        customA = try c.decodeIfPresent(String.self, forKey: .customA) ?? d.customA
        customB = try c.decodeIfPresent(String.self, forKey: .customB) ?? d.customB
        customAngle = try c.decodeIfPresent(Double.self, forKey: .customAngle) ?? d.customAngle
        customRadial = try c.decodeIfPresent(Bool.self, forKey: .customRadial) ?? d.customRadial
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? d.aspect
        cursor = try c.decodeIfPresent(Bool.self, forKey: .cursor) ?? d.cursor
        cursorSize = try c.decodeIfPresent(Double.self, forKey: .cursorSize) ?? d.cursorSize
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? d.clickEffect
        smoothCursor = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor) ?? d.smoothCursor
    }

    static func parse(_ json: String) -> Look {
        guard let data = json.data(using: .utf8), let look = try? JSONDecoder().decode(Look.self, from: data) else { return Look() }
        return look
    }
}

/// One span on an effect lane. `kind` is "zoom", "speed", a visual effect
/// ("spotlight", "highlight", "blur", "mono"), "text" or "image". `level` is a zoom's
/// (below 1 zooms out), `rate` a speed's; the rest are a text's or an image's.
struct Segment: Codable, Equatable {
    var id: String
    var kind: String
    var start: Double
    var end: Double
    var lane: Int = 0
    var level: Double?
    var rate: Double?
    // A text's.
    var text: String?
    /// Its centre on the canvas, unit coordinates, origin top-left.
    var x: Double?
    var y: Double?
    /// Its height as a share of the canvas's.
    var size: Double?
    var color: String?
    var weight: String?
    /// "plain", "pill", "box", "outline" or "shadow".
    var style: String?
    var animIn: String?
    var animOut: String?
    /// While shown: "none", "wave", "pulse", "float" or "wiggle".
    var loop: String?
    /// Degrees, clockwise.
    var rotation: Double?
    /// A blur's or black and white's reach: "video" (the default); "frame", the whole picture
    /// with its images, under the texts; or "all", the texts too.
    var scope: String?
    /// A 3D turn's pose, in degrees.
    var tilt: Double?
    var turn: Double?
    var roll: Double?
    // An image's. It shares a text's x, y, size, rotation, animIn and animOut.
    /// The picture's file, in the recording's folder.
    var file: String?
    var opacity: Double?
    /// Its corners' radius as a share of its shorter side, 0 to 0.5.
    var radius: Double?
    var shadow: Bool?
    /// Its own moves, as the video has: each lands at `t` at `to`, where `scale` multiplies its `size`.
    var moves: [Move]?
    /// Its own effects, each a span inside the image's: `kind` one of `Segment.imageEffects`,
    /// `lane` its row under the image, `level` a fade's opacity.
    var effects: [Segment]?

    static let visual = ["spotlight", "highlight", "blur", "mono"]
    static let kinds = ["zoom", "speed", "text", "image", "3d"] + visual
    /// What an image's own effect can be.
    static let imageEffects = ["blur", "mono", "fade", "pulse", "float", "wiggle"]

    /// Two segments may overlap in time unless they share a group: one zoom at
    /// a time, one speed at a time, one of each visual effect at a time.
    /// Texts and images never clash.
    var group: String { isOverlay ? kind + ":" + id : coversFrame ? kind + ":frame" : kind }
    /// A blur or black and white over the whole picture, not only the video.
    var coversFrame: Bool { (kind == "blur" || kind == "mono") && (scope == "frame" || scope == "all") }
    /// Drawn over the finished picture: a text or an image.
    var isOverlay: Bool { kind == "text" || kind == "image" }
    /// Which rows its `lane` counts: 0 the video's effect lanes, 1 the text lanes, 2 the images
    /// (each its own row), 3 the whole-frame effect lanes.
    var space: Int { kind == "text" ? 1 : kind == "image" ? 2 : coversFrame ? 3 : 0 }

    func overlaps(_ o: Segment) -> Bool { start < o.end - 0.0001 && o.start < end - 0.0001 }
}

/// Where the subject sits on the canvas: its centre (unit, origin top-left) and scale.
struct Placement: Codable, Equatable {
    var x = 0.5, y = 0.5, scale = 1.0
}

/// A move: at `t` the subject has arrived at `to`, having moved there over
/// the `duration` before `t` in `style`.
struct Move: Codable, Equatable {
    var id: String
    var t: Double
    var to: Placement
    /// "smooth", "linear", "spring", "zoom", "swipe", "fade", "spin" or "pop".
    var style = "smooth"
    var duration = 0.8
    /// The 3D angle it lands at; none keeps the angle it had.
    var angles: Angles?
}

/// A 3D angle in degrees: `tilt` leans the top away, `turn` swings the right side away, `roll` turns it flat.
struct Angles: Codable, Equatable {
    var tilt = 0.0, turn = 0.0, roll = 0.0
}

/// A sound you add: music or an effect, from a file in the recording's `sounds/` folder.
/// Only its start is in recording time; from there it plays straight through for `length`
/// seconds, whatever the video's cuts and speed changes do.
// @ref LLP 0002#sound — an added sound is not cut or sped up with the clip; the recorded sound is
struct Sound: Codable, Equatable {
    var id: String
    /// The file, a path inside the recording's folder.
    var file: String
    var lane = 0
    /// When it begins, in seconds of the recording.
    var start: Double
    /// How many seconds of the file play.
    var length: Double
    /// Where in the file it starts.
    var offset = 0.0
    var volume = 1.0
    var fadeIn = 0.0
    var fadeOut = 0.0

    init(id: String, file: String, lane: Int = 0, start: Double, length: Double, offset: Double = 0, volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.file = file; self.lane = lane; self.start = start; self.length = length
        self.offset = offset; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        start = try c.decode(Double.self, forKey: .start)
        length = try c.decode(Double.self, forKey: .length)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    }

    /// When it plays, in seconds of the video: from where its start lands (the next kept moment,
    /// when it starts in a removed part) for its length, or until the video ends.
    func playing(_ map: TimeMap) -> (start: Double, end: Double) {
        let a = map.output(start)
        return (a, max(a, min(a + length, map.outputDuration)))
    }

    /// Where it ends on the recording's time line, for drawing.
    func end(_ map: TimeMap) -> Double { map.source(playing(map).end) }
}

/// One part of the clip between two split points.
struct Piece: Equatable { var start: Double, end: Double, removed: Bool
    var id: String { "p:\(Int((start * 1000).rounded()))" } }

/// A recording's edits, all in source seconds.
struct Edits: Codable, Equatable {
    var segments: [Segment] = []
    /// Where the clip is split, sorted.
    var splits: [Double] = []
    /// The start of each removed part.
    var removed: [Double] = []
    /// How the video passes from a kept part into the next across removed
    /// ones, keyed by the kept part's end in milliseconds: "crossfade" or "fade".
    var transitions: [String: String] = [:]
    /// Effect lanes, at least one; a lane may stay empty. They hold what changes the video.
    var lanes: Int = 1
    /// Text lanes: they hold the texts drawn over the video. A text's `lane` counts these.
    /// An image has no lane to share: each is its own row, and its `lane` is its place among the images.
    // @ref LLP 0002#rows — effects change the video; texts and images sit on top of it
    var textLanes: Int = 0
    /// Whole-frame lanes: they hold the blurs and black-and-whites that cover the whole picture.
    var frameLanes: Int = 0
    /// Where the subject sits before any move.
    var base = Placement()
    var moves: [Move] = []
    /// The subject in 3D, when on.
    var three = ThreeD()
    /// The recorded sound's volume, 0 (muted) to 1.
    var volume: Double = 1
    /// The sounds added over the video: music and effects, on their own lanes.
    var sounds: [Sound] = []
    /// Sound lanes: a sound's `lane` counts these.
    var soundLanes: Int = 0

    init(segments: [Segment] = []) { self.segments = segments }

    enum CodingKeys: String, CodingKey { case segments, splits, removed, transitions, lanes, textLanes, frameLanes, base, moves, three, volume, sounds, soundLanes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        splits = try c.decodeIfPresent([Double].self, forKey: .splits) ?? []
        removed = try c.decodeIfPresent([Double].self, forKey: .removed) ?? []
        transitions = try c.decodeIfPresent([String: String].self, forKey: .transitions) ?? [:]
        lanes = try c.decodeIfPresent(Int.self, forKey: .lanes) ?? 1
        base = try c.decodeIfPresent(Placement.self, forKey: .base) ?? Placement()
        moves = try c.decodeIfPresent([Move].self, forKey: .moves) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        sounds = try c.decodeIfPresent([Sound].self, forKey: .sounds) ?? []
        soundLanes = try c.decodeIfPresent(Int.self, forKey: .soundLanes) ?? 0
        three = try c.decodeIfPresent(ThreeD.self, forKey: .three) ?? ThreeD()
        // Cuts were once segments: each becomes two splits and a removed part.
        for cut in segments where cut.kind == "cut" {
            splits += [cut.start, cut.end]
            removed.append(cut.start)
        }
        segments.removeAll { $0.kind == "cut" }
        splits = Array(Set(splits.filter { $0 > 0.001 })).sorted()
        frameLanes = try c.decodeIfPresent(Int.self, forKey: .frameLanes) ?? 0
        if let n = try c.decodeIfPresent(Int.self, forKey: .textLanes) {
            textLanes = n
        } else {
            // Texts and whole-frame effects once shared the effect lanes: each lane that held one
            // becomes a lane of its own kind, in the same order, and the effect lanes close up.
            for space in [1, 3, 0] {
                let used = Array(Set(segments.filter { $0.space == space }.map(\.lane))).sorted()
                segments = segments.map { s in
                    guard s.space == space, let i = used.firstIndex(of: s.lane) else { return s }
                    var m = s; m.lane = i; return m
                }
                if space == 0 { lanes = used.count }
            }
        }
        fitLanes()
    }

    /// How many rows there are in a space (`Segment.space`), or of sound lanes (`Edits.soundSpace`).
    func laneCount(space: Int) -> Int { space == 1 ? textLanes : space == 2 ? images.count : space == 3 ? frameLanes : space == Edits.soundSpace ? soundLanes : lanes }
    /// The sound lanes, counted as one more space after the segments' own.
    static let soundSpace = 4

    /// Enough lanes of each kind for the segments, at least one effect lane, and each image on its own row.
    mutating func fitLanes() {
        lanes = max(lanes, (segments.filter { $0.space == 0 }.map(\.lane).max() ?? -1) + 1, 1)
        textLanes = max(textLanes, (texts.map(\.lane).max() ?? -1) + 1, 0)
        frameLanes = max(frameLanes, (segments.filter { $0.space == 3 }.map(\.lane).max() ?? -1) + 1, 0)
        soundLanes = max(soundLanes, (sounds.map(\.lane).max() ?? -1) + 1, 0)
        let order = segments.enumerated().filter { $0.element.kind == "image" }.sorted { ($0.element.lane, $0.offset) < ($1.element.lane, $1.offset) }
        for (row, item) in order.enumerated() { segments[item.offset].lane = row }
    }

    /// The first lane of `s`'s kind where nothing overlaps it; one past the last when none has room.
    /// A new image goes on top of the others.
    func freeLane(for s: Segment) -> Int {
        if s.kind == "image" { return -1 }
        var lane = 0
        while lane < laneCount(space: s.space), segments.contains(where: { $0.id != s.id && $0.space == s.space && $0.lane == lane && $0.overlaps(s) }) { lane += 1 }
        return lane
    }

    /// Replace the segments with `made`, each on the first lane of its kind with room, and no lane more than they need.
    mutating func pack(_ made: [Segment]) {
        segments = []
        lanes = 0; textLanes = 0; frameLanes = 0
        for var seg in made.sorted(by: { $0.start < $1.start }) {
            var lane = 0
            while seg.kind != "image", segments.contains(where: { $0.space == seg.space && $0.lane == lane && $0.overlaps(seg) }) { lane += 1 }
            if seg.kind != "image" { seg.lane = lane }
            segments.append(seg)
        }
        fitLanes()
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0015 }
    static func key(_ t: Double) -> String { String(Int((t * 1000).rounded())) }

    /// The clip's parts, in order.
    func pieces(_ duration: Double) -> [Piece] {
        let points = [0] + splits.filter { $0 > 0.001 && $0 < duration - 0.001 } + [duration]
        return zip(points, points.dropFirst()).map { a, b in Piece(start: a, end: b, removed: removed.contains { Edits.same($0, a) }) }
    }

    /// The removed parts, as the time map takes them.
    func cuts(_ duration: Double) -> [Segment] {
        pieces(duration).filter(\.removed).map { Segment(id: $0.id, kind: "cut", start: $0.start, end: $0.end) }
    }
    var zooms: [Segment] { segments.filter { $0.kind == "zoom" } }
    var speeds: [Segment] { segments.filter { $0.kind == "speed" } }
    var effects: [Segment] { segments.filter { Segment.visual.contains($0.kind) } }
    var texts: [Segment] { segments.filter { $0.kind == "text" } }
    var images: [Segment] { segments.filter { $0.kind == "image" } }
    /// The texts and images showing at `t`, back to front: the images, the top row in front, then
    /// the texts over them, in the order they are listed, as they always were.
    // @ref LLP 0002#images — row order is the stacking order
    func overlays(at t: Double) -> [Segment] {
        let showing = segments.filter { $0.isOverlay && t >= $0.start && t < $0.end }
        return showing.filter { $0.kind == "image" }.sorted { $0.lane > $1.lane } + showing.filter { $0.kind == "text" }
    }
    var turns: [Segment] { segments.filter { $0.kind == "3d" } }

    /// Why `s` cannot sit where it is, or nil when it can.
    func conflict(_ s: Segment) -> String? {
        for o in segments where o.id != s.id && o.overlaps(s) {
            if o.group == s.group { return "Two \(Segment.noun(s.kind)) can’t overlap." }
            if o.lane == s.lane, o.space == s.space, s.kind != "image" { return "That lane is taken there; drop it on another lane." }
        }
        if s.kind == "image" { return Edits.conflict(in: s) }
        return nil
    }

    /// Why a sound cannot sit where it is, or nil when it can: two sounds on one lane never play at once.
    func conflict(_ s: Sound, map: TimeMap) -> String? {
        let a = s.playing(map)
        for o in sounds where o.id != s.id && o.lane == s.lane {
            let b = o.playing(map)
            if a.start < b.end - 0.0001 && b.start < a.end - 0.0001 { return "That sound lane is taken there; drop it on another lane." }
        }
        return nil
    }

    /// The first sound lane where `s` plays alone; one past the last when none has room.
    func freeLane(for s: Sound, map: TimeMap) -> Int {
        var probe = s
        probe.lane = 0
        while probe.lane < soundLanes, conflict(probe, map: map) != nil { probe.lane += 1 }
        return probe.lane
    }

    /// Why an image's own moves and effects cannot sit where they are, or nil when they can.
    static func conflict(in image: Segment) -> String? {
        let fx = image.effects ?? []
        for e in fx {
            if !Segment.imageEffects.contains(e.kind) { return "An image has no \(e.kind) effect." }
            if e.start < image.start - 0.001 || e.end > image.end + 0.001 { return "An image’s effect must stay inside the image’s time." }
            for o in fx where o.id != e.id && o.overlaps(e) {
                if o.kind == e.kind { return "Two of the same effect can’t overlap on one image." }
                if o.lane == e.lane { return "That row is taken there; drop it on another row." }
            }
        }
        for m in image.moves ?? [] where m.t < image.start - 0.001 || m.t > image.end + 0.001 { return "An image’s move must land inside the image’s time." }
        return nil
    }

    /// Zooms where the clicks are: clicks less than 3 s apart share one,
    /// which holds for a beat after its last click.
    // @ref LLP 0002#defaults — only on request (Zoom on Clicks), never on a new recording
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
        ["zoom": "zooms", "speed": "speed changes", "spotlight": "spotlights", "highlight": "cursor highlights",
         "blur": "blurs", "mono": "black-and-white effects", "text": "texts", "image": "images", "3d": "3D turns"][kind] ?? "effects"
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
    /// When the button was let go after each click, if recorded.
    var releases: [Point]?
    /// A device found in the picture: cut to a rounded rectangle of this
    /// radius (a share of the crop's width) rather than by alpha.
    var cornerRadius: Double?
    /// Set when a device was found in an area or window recording.
    var device: Bool?
    /// The device's silhouette beside the capture (a grey image over the crop): the shape the frame is cut to.
    var mask: String?
    /// Where the silhouette lies in the frame (unit), which a later trim of `crop` leaves alone.
    var maskRect: UnitRect?
    /// False when the system cursor was left out of the picture (so one is drawn).
    var cursorBaked: Bool?

    var isDevice: Bool { kind == "simulator" || kind == "emulator" || device == true }
    /// A window recording keeps the window's own shape: its alpha is the cut, its corner radius the 3D body's.
    var isWindow: Bool { kind == "window" && device != true }
    var drawsCursor: Bool { cursorBaked == false }
}

/// Silhouette masks, loaded once per file.
enum Masks {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()
    static func image(_ url: URL) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[url.path] { return hit }
        guard let img = CIImage(contentsOf: url) else { return nil }
        cache[url.path] = img
        return img
    }

    private static var bodies: [String: Bezel.Body] = [:]
    /// The device's body read from its silhouette, for the 3D slab.
    static func body(_ url: URL) -> Bezel.Body? {
        lock.lock(); defer { lock.unlock() }
        if let hit = bodies[url.path] { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let b = Bezel.body(cg) else { return nil }
        bodies[url.path] = b
        return b
    }
}

// MARK: - Easing

enum Ease {
    static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
    /// A smootherstep: no visible jolt at either end.
    static func smooth(_ x: Double) -> Double { let v = clamp(x); return v * v * v * (v * (v * 6 - 15) + 10) }
    static func inOut(_ x: Double) -> Double { let v = clamp(x); return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { let v = clamp(x); return 1 - pow(1 - v, 3) }
    /// A spring settling at 1 with a little overshoot.
    static func spring(_ x: Double, bounce: Double = 1) -> Double {
        let v = clamp(x)
        guard v < 1 else { return 1 }
        return 1 - exp(-6 * v) * cos(v * .pi * (2.5 + 2 * bounce))
    }
}

/// How far into a segment's effect `t` is: 0 outside, easing to 1 over `ramp` seconds at each end.
func presence(_ s: Segment, at t: Double, ramp: Double) -> Double {
    let r = min(ramp, (s.end - s.start) / 2)
    guard t > s.start, t < s.end, r > 0 else { return 0 }
    return Ease.smooth(min((t - s.start) / r, (s.end - t) / r, 1))
}

/// The cursor in the subject's unit coordinates, looked up by time.
struct CursorPath {
    let samples: [Point]

    /// The cursor at `t`, averaged over a short window so motion glides.
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

    /// The cursor at `t`, unsmoothed.
    func at(_ t: Double) -> CGPoint? { smoothed(at: t, window: 0.03) }
}

// MARK: - Art

/// The arrow cursor, as AppKit draws it, with its hot spot. Made on the main thread once.
enum CursorArt {
    private(set) static var image: CIImage?
    private(set) static var hotSpot = CGPoint(x: 4, y: 4)
    /// Its height in points.
    private(set) static var points: CGFloat = 24

    static func prepare() {
        guard image == nil else { return }
        let arrow = NSCursor.arrow
        let size = arrow.image.size
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * 4, height: size.height * 4))
        guard let cg = arrow.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        image = CIImage(cgImage: cg)
        hotSpot = arrow.hotSpot
        points = size.height
    }
}

/// Text set as one image per letter, with each letter's place in the line. Cached by everything that shapes it.
final class TextArt {
    struct Letter { let image: CIImage; let x: CGFloat; let width: CGFloat }
    struct Set { let letters: [Letter]; let width: CGFloat; let height: CGFloat; let ascent: CGFloat; let descent: CGFloat; let capHeight: CGFloat }

    private static var cache: [String: Set] = [:]
    private static let lock = NSLock()

    static func color(_ name: String?) -> NSColor {
        switch name ?? "white" {
        case "black": return .black
        case "yellow": return NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1)
        case "pink": return NSColor(srgbRed: 1, green: 0.27, blue: 0.55, alpha: 1)
        case "blue": return NSColor(srgbRed: 0.25, green: 0.55, blue: 1, alpha: 1)
        case "mint": return NSColor(srgbRed: 0.35, green: 0.92, blue: 0.7, alpha: 1)
        default: return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    static func isLight(_ name: String?) -> Bool { name != "black" }

    static func set(_ s: Segment, height: CGFloat) -> Set {
        let text = (s.text ?? "").isEmpty ? " " : s.text!
        let size = max(8, (s.size ?? 0.08) * height)
        let key = "\(text)|\(Int(size))|\(s.weight ?? "")|\(s.color ?? "")|\(s.style ?? "")"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let weight: NSFont.Weight = s.weight == "regular" ? .regular : s.weight == "heavy" ? .heavy : .bold
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if s.weight == "rounded", let rounded = NSFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: size) ?? font
        }
        let ink = color(s.color)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        if s.style == "outline" {
            attrs[.strokeColor] = isLight(s.color) ? NSColor.black : NSColor.white
            attrs[.strokeWidth] = -4
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        var letters: [Letter] = []
        let ns = text as NSString
        var i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let x0 = CTLineGetOffsetForStringIndex(line, r.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, r.location + r.length, nil)
            let piece = ns.substring(with: r)
            let pad = size * 0.25
            let w = max(1, x1 - x0) + pad * 2, h = ascent + descent + pad * 2
            if let ctx = CGContext(data: nil, width: Int(ceil(w)), height: Int(ceil(h)), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                // CoreText puts the baseline exactly where it is told: `pad + descent` up from the image's bottom.
                var ct: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.cgColor]
                if s.style == "outline" {
                    ct[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = (isLight(s.color) ? NSColor.black : NSColor.white).cgColor
                    ct[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4
                }
                ctx.textPosition = CGPoint(x: pad, y: pad + descent)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: piece, attributes: ct)), ctx)
                if let cg = ctx.makeImage() {
                    // Origin at the letter's own left edge, on the line's descent.
                    let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: -pad, y: -pad))
                    letters.append(Letter(image: img, x: x0, width: x1 - x0))
                }
            }
            i = r.location + r.length
        }
        let made = Set(letters: letters, width: width, height: ascent + descent, ascent: ascent, descent: descent, capHeight: font.capHeight)
        if cache.count > 200 { cache.removeAll() }
        cache[key] = made
        return made
    }
}

/// The backgrounds: named gradients, a custom one, and the video itself blurred.
enum Backgrounds {
    struct Gradient { let a: CIColor; let b: CIColor; let angle: Double; let radial: Bool }

    private static func c(_ hex: Int) -> CIColor {
        CIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255)
    }
    private static func g(_ a: Int, _ b: Int, _ angle: Double = 135, radial: Bool = false) -> Gradient { Gradient(a: c(a), b: c(b), angle: angle, radial: radial) }

    /// In the order the inspector shows them.
    static let order = [
        "ocean", "sunset", "mint", "midnight", "graphite", "paper",
        "peach", "lagoon", "berry", "aurora", "ember", "lavender",
        "citrus", "forest", "sky", "rose", "dusk", "steel",
        "candy", "deepsea", "sand", "neon", "glow", "noir",
    ]
    static let presets: [String: Gradient] = [
        "ocean": g(0x215CD9, 0x33C7DB), "sunset": g(0xFA7359, 0x9E40CC), "mint": g(0x29A885, 0xBAED9E),
        "midnight": g(0x0F1229, 0x382E6B), "graphite": g(0x29292E, 0x5C5E66), "paper": g(0xF2F0EB, 0xDBD9D4),
        "peach": g(0xFFB88C, 0xDE6262), "lagoon": g(0x43CEA2, 0x185A9D), "berry": g(0x8E2DE2, 0xF00000, 160),
        "aurora": g(0x00C9A7, 0x4A00E0, 200), "ember": g(0xF12711, 0xF5AF19, 45), "lavender": g(0xC3B1E1, 0x7F7FD5),
        "citrus": g(0xF7FF00, 0xDB36A4, 160), "forest": g(0x134E5E, 0x71B280), "sky": g(0x89F7FE, 0x66A6FF, 180),
        "rose": g(0xFFDDE1, 0xEE9CA7), "dusk": g(0x2C3E50, 0xFD746C), "steel": g(0x8E9EAB, 0xEEF2F3, 180),
        "candy": g(0xFF5F6D, 0xFFC371, 90), "deepsea": g(0x000428, 0x004E92, 180), "sand": g(0xE6DADA, 0xC9A878),
        "neon": g(0x12C2E9, 0xF64F59, 120), "glow": g(0xFF9A8B, 0x4B0082, 0, radial: true), "noir": g(0x434343, 0x000000, 0, radial: true),
    ]

    static func hex(_ s: String?) -> CIColor? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = Int(t, radix: 16) else { return nil }
        return c(v)
    }

    /// The gradient `look` names: a preset, or (for "custom") its own colours and direction.
    static func gradient(_ look: Look) -> Gradient {
        if look.background == "custom" {
            return Gradient(a: hex(look.customA) ?? c(0x6A11CB), b: hex(look.customB) ?? c(0x2575FC),
                            angle: look.customAngle, radial: look.customRadial)
        }
        return presets[look.background] ?? presets["ocean"]!
    }

    static func image(_ gr: Gradient, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        if gr.radial {
            let r = CIFilter.radialGradient()
            r.center = mid
            r.radius0 = 0
            r.radius1 = Float(hypot(size.width, size.height) / 2)
            r.color0 = gr.a
            r.color1 = gr.b
            return r.outputImage!.cropped(to: rect)
        }
        // The angle as CSS's: 0 points up, 90 right; the line spans the canvas's diagonal reach.
        let rad = (gr.angle - 90) * .pi / 180
        let dx = cos(rad), dy = -sin(rad)
        let reach = (abs(dx) * size.width + abs(dy) * size.height) / 2
        let l = CIFilter.smoothLinearGradient()
        l.point0 = CGPoint(x: mid.x - dx * reach, y: mid.y - dy * reach)
        l.point1 = CGPoint(x: mid.x + dx * reach, y: mid.y + dy * reach)
        l.color0 = gr.a
        l.color1 = gr.b
        return l.outputImage!.cropped(to: rect)
    }

    static func image(_ name: String, size: CGSize) -> CIImage { image(presets[name] ?? presets["ocean"]!, size: size) }
}

extension CIImage {
    func opacity(_ a: Double) -> CIImage {
        guard a < 0.999 else { return self }
        let m = CIFilter.colorMatrix()
        m.inputImage = self
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, a)))
        return m.outputImage!
    }
}

// MARK: - Framing

/// Where the subject is at an instant: its placement, a turn, and an opacity.
struct Pose {
    var x: Double, y: Double, scale: Double, rotation: Double = 0, opacity: Double = 1
    /// The 3D angle, used only when the subject is drawn in 3D.
    var angles = Angles()
}

/// The device's body on the canvas, for the 3D slab: its block, corner radius and buttons.
struct BodyOnCanvas { let rect: CGRect; let radius: CGFloat; let buttons: [CGRect] }

/// One recording's framing: everything per frame except the frame itself.
struct Framing {
    let canvas: CGSize
    /// The subject's rectangle on the canvas at its base size and centred, Core Image coordinates.
    let subject: CGRect
    let meta: RecordingMeta
    let look: Look
    let edits: Edits
    let cursor: CursorPath
    let releases: [Double]
    private let background: CIImage
    private let moves: [Move]
    /// The recording's folder, where an image's file is.
    let folder: URL?

    var crop: UnitRect { meta.crop }

    /// The device's silhouette, when the recording has one, and the body read from it.
    private let silhouette: CIImage?
    private let deviceBody: Bezel.Body?

    init(meta: RecordingMeta, look: Look, edits: Edits, cursor: [Point], folder: URL? = nil) {
        self.meta = meta
        self.folder = folder
        silhouette = meta.mask.flatMap { name in folder.flatMap { Masks.image($0.appendingPathComponent(name)) } }
        deviceBody = meta.mask.flatMap { name in folder.flatMap { Masks.body($0.appendingPathComponent(name)) } }
        self.look = look
        self.edits = edits
        let crop = meta.crop
        let content = CGSize(width: meta.width * crop.w, height: meta.height * crop.h)
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
        let toCrop = { (p: Point) -> Point in Point(t: p.t, x: (p.x - crop.x) / crop.w, y: (p.y - crop.y) / crop.h) }
        self.cursor = CursorPath(samples: cursor.map(toCrop))
        releases = (meta.releases ?? []).map(\.t).sorted()
        background = Backgrounds.image(Backgrounds.gradient(look), size: canvas)
        moves = edits.moves.sorted { $0.t < $1.t }
    }

    /// A point in the subject's unit coordinates, on the canvas at the subject's base place.
    private func onSubject(_ p: CGPoint) -> CGPoint {
        CGPoint(x: subject.minX + min(max(p.x, 0), 1) * subject.width,
                y: subject.minY + (1 - min(max(p.y, 0), 1)) * subject.height)
    }

    // MARK: Placement

    /// The scale at which the subject covers the whole canvas.
    private var fill: Double { Double(max(canvas.width / subject.width, canvas.height / subject.height)) * 1.04 }

    func pose(at t: Double) -> Pose {
        var p = movedPose(at: t)
        // A 3D turn: the angle eases to the turn's pose and back over its span.
        for seg in edits.turns {
            let a = presence(seg, at: t, ramp: min(0.7, (seg.end - seg.start) / 3))
            guard a > 0.0005 else { continue }
            var target = Angles(tilt: seg.tilt ?? 10, turn: seg.turn ?? -24, roll: seg.roll ?? 0)
            if seg.style == "orbit" {
                // One full turn about the vertical across the span, the pose's tilt held.
                let u = Ease.inOut((t - seg.start) / max(seg.end - seg.start, 0.01))
                target.turn += 360 * u
                p.angles = Angles(tilt: p.angles.tilt + (target.tilt - p.angles.tilt) * a, turn: p.angles.turn + 360 * u, roll: p.angles.roll + (target.roll - p.angles.roll) * a)
                continue
            }
            p.angles = Angles(tilt: p.angles.tilt + (target.tilt - p.angles.tilt) * a,
                              turn: p.angles.turn + (target.turn - p.angles.turn) * a,
                              roll: p.angles.roll + (target.roll - p.angles.roll) * a)
        }
        return p
    }

    /// Whether the subject is drawn in 3D at `t`: 3D is on, or a 3D turn is under way.
    func inDepth(at t: Double) -> Bool {
        edits.three.on || edits.turns.contains { t > $0.start && t < $0.end }
    }

    /// The place and angle from the base and the moves alone.
    private func movedPose(at t: Double) -> Pose {
        let on = edits.three.on
        var from = edits.base
        // With 3D off, angles come only from 3D turns: everything else is face on.
        var angles = on ? Angles(tilt: edits.three.tilt, turn: edits.three.turn, roll: edits.three.roll) : Angles()
        for m in moves {
            let start = m.t - m.duration
            let next = on ? (m.angles ?? angles) : angles
            if t >= m.t { from = m.to; angles = next; continue }
            guard t > start, m.duration > 0 else { break }
            var p = Framing.blend(from, m.to, u: (t - start) / m.duration, style: m.style, fill: fill)
            p.angles = Framing.turn(angles, next, u: (t - start) / m.duration, style: m.style, inDepth: on)
            // In 3D a spin is a turn about the vertical, not a turn in the picture's plane.
            if on && m.style == "spin" { p.rotation = 0 }
            return p
        }
        var p = Pose(x: from.x, y: from.y, scale: from.scale)
        p.angles = angles
        return p
    }

    /// The 3D angle on the way from `a` to `b`, eased as the move's style eases its place.
    static func turn(_ a: Angles, _ b: Angles, u: Double, style: String, inDepth: Bool) -> Angles {
        func mix(_ e: Double) -> Angles { Angles(tilt: a.tilt + (b.tilt - a.tilt) * e, turn: a.turn + (b.turn - a.turn) * e, roll: a.roll + (b.roll - a.roll) * e) }
        switch style {
        case "linear": return mix(Ease.clamp(u))
        case "spring", "pop": return mix(Ease.spring(u))
        case "zoom":
            // Face on while it fills the frame.
            let flat = Angles()
            return u < 0.5 ? turn(a, flat, u: u * 2, style: "smooth", inDepth: inDepth) : turn(flat, b, u: u * 2 - 1, style: "smooth", inDepth: inDepth)
        case "swipe", "fade": return u < 0.5 ? a : b
        case "spin":
            var m = mix(Ease.inOut(u))
            if inDepth { m.turn += 360 * Ease.inOut(u) }
            return m
        default: return mix(Ease.inOut(u))
        }
    }

    static func blend(_ a: Placement, _ b: Placement, u: Double, style: String, fill: Double) -> Pose {
        func mix(_ e: Double) -> Pose {
            Pose(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e, scale: a.scale + (b.scale - a.scale) * e)
        }
        switch style {
        case "linear":
            return mix(Ease.clamp(u))
        case "spring":
            return mix(Ease.spring(u))
        case "zoom":
            // Grow to cover the canvas, then settle into the new place.
            let mid = Placement(x: 0.5, y: 0.5, scale: fill)
            return u < 0.5 ? blend(a, mid, u: u * 2, style: "smooth", fill: fill) : blend(mid, b, u: u * 2 - 1, style: "smooth", fill: fill)
        case "swipe":
            // Out past the edge in the direction of travel, back in from the other side.
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            let (ux, uy) = len < 0.01 ? (1.0, 0.0) : (dx / len, dy / len)
            if u < 0.5 {
                let e = Ease.inOut(u * 2) * 1.3
                return Pose(x: a.x + ux * e, y: a.y + uy * e, scale: a.scale)
            }
            let e = (1 - Ease.out(u * 2 - 1)) * 1.3
            return Pose(x: b.x - ux * e, y: b.y - uy * e, scale: b.scale)
        case "fade":
            if u < 0.5 { return Pose(x: a.x, y: a.y, scale: a.scale, opacity: 1 - Ease.smooth(u * 2)) }
            return Pose(x: b.x, y: b.y, scale: b.scale, opacity: Ease.smooth(u * 2 - 1))
        case "spin":
            var p = mix(Ease.inOut(u))
            p.rotation = 360 * Ease.inOut(u)
            p.scale *= 1 - 0.3 * sin(.pi * Ease.clamp(u))
            return p
        case "pop":
            // Shrink a little while travelling, spring back on arrival.
            var p = mix(Ease.inOut(u))
            let v = Ease.clamp(u)
            p.scale *= v < 0.6 ? 1 - 0.18 * Ease.smooth(v / 0.3) : 0.82 + 0.18 * Ease.spring((v - 0.6) / 0.4, bounce: 1.4)
            return p
        default:
            return mix(Ease.inOut(u))
        }
    }

    /// The transform that puts the subject, drawn at its base place, at `pose`.
    func placement(_ pose: Pose) -> CGAffineTransform {
        let c = CGPoint(x: subject.midX, y: subject.midY)
        let to = CGPoint(x: pose.x * canvas.width, y: (1 - pose.y) * canvas.height)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: -pose.rotation * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
            .concatenating(CGAffineTransform(translationX: to.x, y: to.y))
    }

    /// The subject's rectangle on the canvas at `t` (no turn). Unit, origin top-left.
    func subjectFrame(at t: Double) -> UnitRect {
        let p = pose(at: t)
        let w = subject.width * p.scale / canvas.width, h = subject.height * p.scale / canvas.height
        return UnitRect(x: p.x - w / 2, y: p.y - h / 2, w: w, h: h)
    }

    // MARK: Rendering

    /// One frame: `frame` is the source at `t`; `opacity` fades the subject (a transition's).
    /// Texts are drawn over the finished frame by `overlay`, once, even where two frames blend.
    func render(_ frame: CIImage, at t: Double, opacity: Double = 1, texts: Bool = true) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let e = frame.extent
        let cropRect = CGRect(x: e.minX + crop.x * e.width, y: e.minY + (1 - crop.y - crop.h) * e.height,
                              width: crop.w * e.width, height: crop.h * e.height)
        let toSubject = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
            .concatenating(CGAffineTransform(scaleX: subject.width / cropRect.width, y: subject.height / cropRect.height))
            .concatenating(CGAffineTransform(translationX: subject.minX, y: subject.minY))
        let source = frame.cropped(to: cropRect).transformed(by: toSubject)
        var subjectImage = source

        // Effects on the subject's pixels.
        let minSide = min(canvas.width, canvas.height)
        var overlays: [CIImage] = []
        for fx in edits.effects where !fx.coversFrame {
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
                g.center = onSubject(p)
                g.radius0 = Float(minSide * 0.09)
                g.radius1 = Float(minSide * 0.16)
                g.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.62 * a)
                overlays.append(g.outputImage!.cropped(to: subject))
            case "highlight":
                guard let p = cursor.at(t) else { continue }
                let g = CIFilter.radialGradient()
                g.center = onSubject(p)
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

        // The drawn cursor, over the picture and inside the subject.
        if look.cursor && meta.drawsCursor, let art = CursorArt.image, let p = (look.smoothCursor ? cursor.smoothed(at: t, window: 0.12) : cursor.at(t)) {
            let k = subject.width / (crop.w * meta.width)
            // The capture's backing scale is 2 on a Retina display: the cursor's points in source pixels, then on the canvas.
            let height = CursorArt.points * 2 * k * look.cursorSize * clickScale(at: t)
            let s = height / art.extent.height
            let hot = CGPoint(x: CursorArt.hotSpot.x / CursorArt.points * height, y: CursorArt.hotSpot.y / CursorArt.points * height)
            let at = onSubject(p)
            let drawn = art.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: at.x - hot.x, y: at.y - (height - hot.y)))
            subjectImage = drawn.composited(over: subjectImage)
        }

        // The subject's shape.
        if meta.isDevice, let shape = silhouette {
            // The silhouette lies where it was found; a trim of the crop only cuts into it.
            let r = meta.maskRect ?? crop
            let at = CGRect(x: e.minX + r.x * e.width, y: e.minY + (1 - r.y - r.h) * e.height, width: r.w * e.width, height: r.h * e.height)
            let m = shape.transformed(by: CGAffineTransform(scaleX: at.width / shape.extent.width, y: at.height / shape.extent.height)
                .concatenating(CGAffineTransform(translationX: at.minX, y: at.minY)))
                .transformed(by: toSubject)
            let cut = CIFilter.blendWithMask()
            cut.inputImage = subjectImage
            cut.backgroundImage = CIImage.empty()
            cut.maskImage = m
            subjectImage = cut.outputImage!.cropped(to: subject)
            // The body and buttons from the silhouette's own coordinates onto the canvas.
            var body: BodyOnCanvas?
            if inDepth(at: t), let d = deviceBody {
                let onCanvas = { (u: UnitRect) -> CGRect in
                    CGRect(x: at.minX + u.x * at.width, y: at.maxY - (u.y + u.h) * at.height, width: u.w * at.width, height: u.h * at.height).applying(toSubject)
                }
                let r = onCanvas(d.rect).intersection(subject)
                if !r.isNull, r.width > 4, r.height > 4 {
                    body = BodyOnCanvas(rect: r, radius: CGFloat(d.radius) * r.width, buttons: d.buttons.map(onCanvas))
                }
            }
            return finish(subjectImage, at: t, opacity: opacity, texts: texts, source: source, body: body)
        } else {
            subjectImage = shaped(subjectImage, source: source)
        }
        return finish(subjectImage, at: t, opacity: opacity, texts: texts, source: source)
    }

    /// The recording itself, stretched to cover the canvas, blurred deep and dimmed.
    private func blurred(_ source: CIImage) -> CIImage {
        let k = max(canvas.width / subject.width, canvas.height / subject.height) * 1.15
        let cover = source.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -subject.midX, y: -subject.midY)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2)))
            .applyingGaussianBlur(sigma: min(canvas.width, canvas.height) * 0.06)
        let dim = CIFilter.colorControls()
        dim.inputImage = cover
        dim.brightness = -0.12
        dim.saturation = 1.25
        return dim.outputImage!.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// The subject cut to a rounded rectangle, or (a window, or a device without a silhouette) to its own alpha.
    private func shaped(_ subjectImage: CIImage, source: CIImage) -> CIImage {
        let mask: CIImage
        if meta.isDevice, let r = meta.cornerRadius {
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = subject
            g.radius = Float(r * subject.width)
            g.color = .white
            mask = g.outputImage!
        } else if meta.isDevice || meta.isWindow {
            mask = source
        } else if look.radius > 0 {
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = subject
            g.radius = Float(look.radius)
            g.color = .white
            mask = g.outputImage!
        } else {
            mask = CIImage(color: .white).cropped(to: subject)
        }
        let cut = CIFilter.blendWithAlphaMask()
        cut.inputImage = subjectImage
        cut.backgroundImage = CIImage.empty()
        cut.maskImage = mask
        return cut.outputImage!.cropped(to: subject)
    }

    /// The cut subject placed, zoomed and shadowed over the background, with the texts.
    private func finish(_ subjectImage: CIImage, at t: Double, opacity: Double, texts: Bool, source: CIImage, body: BodyOnCanvas? = nil) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let minSide = min(canvas.width, canvas.height)
        // In 3D the subject is a slab drawn by SceneKit, at the pose's angle; the rest is the flat path's.
        if inDepth(at: t) {
            var three = edits.three
            let a = pose(at: t).angles
            three.tilt = a.tilt; three.turn = a.turn; three.roll = a.roll
            let rect = body?.rect ?? subject
            let path = body.map { b in
                CGPath(roundedRect: b.rect, cornerWidth: max(0.5, min(b.radius, b.rect.width / 2 - 0.5)), cornerHeight: max(0.5, min(b.radius, b.rect.width / 2 - 0.5)), transform: nil)
            } ?? outline
            if let drawn = Stage3D.shared.render(face: subjectImage, rect: rect, outline: path, buttons: body?.buttons ?? [], canvas: canvas, three: three) {
                let lift = min(1.5, (abs(a.tilt) + abs(a.turn.truncatingRemainder(dividingBy: 180))) / 90)
                return place(drawn, shadowFrom: drawn, lift: lift, at: t, opacity: opacity, texts: texts, source: source)
            }
        }
        // The subject and its shadow are one layer; placement and zoom move it over a still background.
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
        let pose = pose(at: t)
        let place = placement(pose)
        layer = layer.transformed(by: place).opacity(pose.opacity * opacity)

        let (s, c) = camera(at: t, place: place)
        if abs(s - 1) > 0.0005 {
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        }
        let ground = look.background == "video" ? blurred(source) : background
        let scene = layer.composited(over: ground).cropped(to: canvasRect)
        return texts ? overlay(scene, at: t) : scene
    }

    /// The slab's outline on the canvas: the device's rounded body, or the frame's rounded rectangle.
    private var outline: CGPath {
        let r: CGFloat
        if meta.isDevice { r = CGFloat(meta.cornerRadius ?? 0.16) * subject.width }
        else if meta.isWindow, let w = meta.cornerRadius { r = CGFloat(w) * subject.width }
        else { r = CGFloat(look.radius) }
        let radius = min(r, min(subject.width, subject.height) / 2 - 0.5)
        return CGPath(roundedRect: subject, cornerWidth: max(0.5, radius), cornerHeight: max(0.5, radius), transform: nil)
    }

    /// A drawn subject (the 3D slab, transparent around it, the canvas's size) with a shadow
    /// from its own shape, placed and zoomed over the background, with the texts.
    private func place(_ body: CIImage, shadowFrom shape: CIImage, lift: Double, at t: Double, opacity: Double, texts: Bool, source: CIImage) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let minSide = min(canvas.width, canvas.height)
        var layer = body
        if look.shadow {
            // A turned subject throws its shadow further and softer.
            let blur = minSide * (0.025 + 0.02 * lift)
            let silhouette = CIFilter.colorMatrix()
            silhouette.inputImage = shape
            silhouette.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            silhouette.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.45)
            let shadow = silhouette.outputImage!
                .applyingGaussianBlur(sigma: blur)
                .transformed(by: CGAffineTransform(translationX: 0, y: -blur * (0.5 + lift)))
            layer = body.composited(over: shadow)
        }
        let pose = pose(at: t)
        let placed = placement(pose)
        layer = layer.transformed(by: placed).opacity(pose.opacity * opacity)
        let (s, c) = camera(at: t, place: placed)
        if abs(s - 1) > 0.0005 {
            let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        }
        let ground = look.background == "video" ? blurred(source) : background
        let scene = layer.composited(over: ground).cropped(to: canvasRect)
        return texts ? overlay(scene, at: t) : scene
    }

    /// The texts and images showing at `t`, over `scene`.
    func overlay(_ scene: CIImage, at t: Double) -> CIImage {
        var out = scene
        let rect = CGRect(origin: .zero, size: canvas)
        // Whole-frame effects: over the picture and its images and under the texts, or over the texts too.
        func cover(_ scope: String) {
            for fx in edits.effects where fx.scope == scope {
                let a = presence(fx, at: t, ramp: 0.3)
                guard a > 0.001 else { continue }
                if fx.kind == "blur" {
                    out = out.clampedToExtent().applyingGaussianBlur(sigma: Double(min(canvas.width, canvas.height)) * 0.03 * a).cropped(to: rect)
                } else if fx.kind == "mono" {
                    let c = CIFilter.colorControls()
                    c.inputImage = out
                    c.saturation = Float(1 - a)
                    out = c.outputImage!.cropped(to: rect)
                }
            }
        }
        // @ref LLP 0002#rows — a whole-frame effect covers the images; the words stay readable unless it covers everything
        let over = edits.overlays(at: t)
        for s in over where s.kind == "image" { out = renderImage(s, at: t).composited(over: out) }
        cover("frame")
        for s in over where s.kind == "text" { out = renderText(s, at: t).composited(over: out) }
        cover("all")
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// The cursor's size at `t`: a little smaller while the button is down, springing back on release.
    func clickScale(at t: Double) -> Double {
        guard look.clickEffect else { return 1 }
        var scale = 1.0
        for c in meta.clicks where t >= c.t && t < c.t + 2 {
            let up = min(releases.first { $0 > c.t } ?? c.t + 0.12, c.t + 1.5)
            if t < up {
                scale = min(scale, 1 - 0.22 * Ease.out((t - c.t) / 0.07))
            } else {
                let q = (t - up) / 0.45
                guard q < 1 else { continue }
                scale = min(scale, 1 - 0.22 * exp(-6 * q) * cos(q * .pi * 3))
            }
        }
        return scale
    }

    /// The zoom at `t`: its scale, and the canvas point it centres.
    func camera(at t: Double, place: CGAffineTransform) -> (CGFloat, CGPoint) {
        let mid = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var s = 1.0, amount = 0.0
        for z in edits.zooms {
            let a = presence(z, at: t, ramp: 0.7)
            if a > amount { amount = a; s = 1 + ((z.level ?? 2) - 1) * a }
        }
        guard amount > 0.0005 else { return (1, mid) }
        guard s > 1 else { return (CGFloat(s), mid) }
        let f = cursor.smoothed(at: t) ?? CGPoint(x: 0.5, y: 0.5)
        let target = onSubject(f).applying(place)
        var c = CGPoint(x: mid.x + (target.x - mid.x) * amount, y: mid.y + (target.y - mid.y) * amount)
        let half = CGSize(width: canvas.width / s / 2, height: canvas.height / s / 2)
        c.x = min(max(c.x, half.width), canvas.width - half.width)
        c.y = min(max(c.y, half.height), canvas.height - half.height)
        return (CGFloat(s), c)
    }

    // MARK: Text

    func renderText(_ s: Segment, at t: Double) -> CIImage {
        let art = TextArt.set(s, height: canvas.height)
        guard !art.letters.isEmpty else { return .empty() }
        let fs = art.height
        let n = art.letters.count
        let center = CGPoint(x: (s.x ?? 0.5) * canvas.width, y: (1 - (s.y ?? 0.5)) * canvas.height)
        let since = t - s.start, until = s.end - t
        let inDur = 0.55, outDur = 0.45
        let stagger = min(0.045, 0.6 / Double(max(n, 1)))
        let animIn = s.animIn ?? "pop", animOut = s.animOut ?? "fade"

        // The text as a whole.
        var whole = CGAffineTransform.identity, wholeAlpha = 1.0, wholeBlur = 0.0
        func scaleWhole(_ k: Double) { whole = whole.scaledBy(x: k, y: k) }
        let ein = since / inDur, eout = until / outDur
        switch animIn {
        case "fade": wholeAlpha *= Ease.smooth(ein)
        case "pop": scaleWhole(max(0.001, Ease.spring(ein, bounce: 1.2))); wholeAlpha *= Ease.smooth(ein * 3)
        case "rise": whole = whole.translatedBy(x: 0, y: -(1 - Ease.out(ein)) * fs * 0.6); wholeAlpha *= Ease.smooth(ein)
        case "blur": wholeBlur = (1 - Ease.out(ein)) * fs * 0.35; wholeAlpha *= Ease.smooth(ein)
        case "spin": whole = whole.rotated(by: -(1 - Ease.spring(ein)) * .pi / 2); scaleWhole(max(0.001, Ease.spring(ein))); wholeAlpha *= Ease.smooth(ein * 2)
        case "slide": whole = whole.translatedBy(x: -(1 - Ease.spring(ein, bounce: 0.6)) * canvas.width * 0.4, y: 0); wholeAlpha *= Ease.smooth(ein * 2)
        default: break
        }
        switch animOut {
        case "fade": wholeAlpha *= Ease.smooth(eout)
        case "pop": scaleWhole(max(0.001, Ease.inOut(eout))); wholeAlpha *= Ease.smooth(eout * 2)
        case "sink": whole = whole.translatedBy(x: 0, y: -(1 - Ease.out(eout)) * fs * 0.6); wholeAlpha *= Ease.smooth(eout)
        case "blur": wholeBlur = max(wholeBlur, (1 - Ease.out(eout)) * fs * 0.35); wholeAlpha *= Ease.smooth(eout)
        default: break
        }
        switch s.loop ?? "none" {
        case "pulse": scaleWhole(1 + 0.045 * sin(since * 2 * .pi / 1.4))
        case "float": whole = whole.translatedBy(x: 0, y: sin(since * 2 * .pi / 2.4) * fs * 0.08)
        case "wiggle": whole = whole.rotated(by: sin(since * 2 * .pi / 1.1) * 0.05)
        default: break
        }
        whole = whole.rotated(by: -(s.rotation ?? 0) * .pi / 180)

        // Each letter.
        var line = CIImage.empty()
        // Each letter's image has its baseline `descent` up from its bottom; set the baseline so the
        // capitals' height is centred on the text's middle, as a pill or a box centres its label.
        let left = -art.width / 2, base = -art.capHeight / 2 - art.descent
        for (i, letter) in art.letters.enumerated() {
            let li = since - Double(i) * stagger
            let lo = until - Double(n - 1 - i) * stagger * 0.6
            var m = CGAffineTransform.identity, alpha = 1.0
            let mid = CGPoint(x: letter.width / 2, y: art.height / 2)
            func aboutMid(_ x: CGAffineTransform) {
                m = m.concatenating(CGAffineTransform(translationX: -mid.x, y: -mid.y)).concatenating(x).concatenating(CGAffineTransform(translationX: mid.x, y: mid.y))
            }
            switch animIn {
            case "letters":
                let e = li / 0.5
                m = m.concatenating(CGAffineTransform(translationX: 0, y: -(1 - Ease.spring(e, bounce: 1.1)) * fs * 0.7))
                alpha *= Ease.smooth(e * 2.5)
            case "letters-pop":
                let e = li / 0.45
                let k = max(0.001, Ease.spring(e, bounce: 1.3))
                aboutMid(CGAffineTransform(scaleX: k, y: k))
                alpha *= Ease.smooth(e * 3)
            case "drop":
                let e = li / 0.6
                m = m.concatenating(CGAffineTransform(translationX: 0, y: (1 - Ease.spring(e, bounce: 0.8)) * fs * 1.6))
                alpha *= Ease.smooth(e * 3)
            case "typewriter":
                alpha *= since >= Double(i) * 0.06 ? 1 : 0
            default: break
            }
            switch animOut {
            case "fall":
                let e = 1 - lo / 0.5
                if e > 0 {
                    aboutMid(CGAffineTransform(rotationAngle: CGFloat(Ease.inOut(e)) * (i % 2 == 0 ? 0.6 : -0.6)))
                    m = m.concatenating(CGAffineTransform(translationX: 0, y: -Ease.inOut(e) * fs * 1.4))
                    alpha *= 1 - Ease.smooth(e)
                }
            case "letters":
                alpha *= Ease.smooth(lo / 0.3)
            default: break
            }
            if s.loop == "wave" {
                m = m.concatenating(CGAffineTransform(translationX: 0, y: sin(since * 2 * .pi / 1.2 - Double(i) * 0.5) * fs * 0.08))
            }
            guard alpha > 0.001 else { continue }
            let placed = letter.image
                .transformed(by: m)
                .transformed(by: CGAffineTransform(translationX: left + letter.x, y: base))
                .opacity(alpha)
            line = placed.composited(over: line)
        }

        // The shape behind it.
        let padX = fs * 0.45, padY = fs * 0.22
        let box = CGRect(x: -art.width / 2 - padX, y: -art.height / 2 - padY, width: art.width + padX * 2, height: art.height + padY * 2)
        var group = line
        let light = TextArt.isLight(s.color)
        switch s.style ?? "plain" {
        case "pill", "box":
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = box
            g.radius = Float(s.style == "pill" ? box.height / 2 : fs * 0.18)
            g.color = light ? CIColor(red: 0, green: 0, blue: 0, alpha: 0.62) : CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)
            // Behind letters that arrive or leave one by one, the shape comes with the first and goes with the last.
            let byLetter = ["letters", "letters-pop", "drop", "typewriter"].contains(animIn)
            let byLetterOut = ["fall", "letters"].contains(animOut)
            let shown = min(byLetter ? Ease.smooth(since / 0.3) : 1, byLetterOut ? Ease.smooth((until - 0.15) / 0.3) : 1)
            group = line.composited(over: g.outputImage!.opacity(shown))
        case "shadow":
            let sh = CIFilter.colorMatrix()
            sh.inputImage = line
            sh.rVector = CIVector(x: 0, y: 0, z: 0, w: 0); sh.gVector = CIVector(x: 0, y: 0, z: 0, w: 0); sh.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            sh.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.55)
            group = line.composited(over: sh.outputImage!.applyingGaussianBlur(sigma: fs * 0.08).transformed(by: CGAffineTransform(translationX: 0, y: -fs * 0.05)))
        default: break
        }
        if wholeBlur > 0.5 { group = group.clampedToExtent().applyingGaussianBlur(sigma: wholeBlur).cropped(to: box.insetBy(dx: -wholeBlur * 3, dy: -wholeBlur * 3)) }
        return group
            .transformed(by: whole)
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            .opacity(wholeAlpha)
    }

    /// A text's box on the canvas at rest. Unit, origin top-left.
    func textFrame(_ s: Segment) -> UnitRect {
        let art = TextArt.set(s, height: canvas.height)
        let w = (art.width + art.height * 0.9) / canvas.width, h = art.height * 1.44 / canvas.height
        return UnitRect(x: (s.x ?? 0.5) - w / 2, y: (s.y ?? 0.5) - h / 2, w: w, h: h)
    }
}

// MARK: - Time

/// Source time to output time and back, across removed parts, speed changes and crossfades.
// @ref LLP 0002#times — the model is in recording time; this converts to video time
struct TimeMap {
    struct Piece {
        var src0: Double, src1: Double, out0: Double, rate: Double
        /// How long this piece overlaps the one before (a crossfade), and fades in or out (through the background).
        var overlap = 0.0, fadeIn = 0.0, fadeOut = 0.0
        var out1: Double { out0 + (src1 - src0) / rate }
    }
    let pieces: [Piece]
    let duration: Double

    static let crossfade = 0.6, fade = 0.4

    init(duration: Double, edits: Edits) {
        self.duration = duration
        var marks = Set([0.0, duration])
        let cuts = edits.cuts(duration)
        for s in cuts + edits.speeds { marks.insert(min(max(s.start, 0), duration)); marks.insert(min(max(s.end, 0), duration)) }
        let sorted = marks.sorted()
        var out: [Piece] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 0.001 {
            let m = (a + b) / 2
            if cuts.contains(where: { m > $0.start && m < $0.end }) { continue }
            let rate = edits.speeds.last(where: { m > $0.start && m < $0.end })?.rate ?? 1
            if let last = out.last, last.rate == rate, abs(last.src1 - a) < 0.0005 {
                out[out.count - 1].src1 = b
                continue
            }
            var p = Piece(src0: a, src1: b, out0: out.last?.out1 ?? 0, rate: rate)
            // Across removed parts: the transition the kept part before chose.
            if let last = out.last, a - last.src1 > 0.0005, let kind = edits.transitions[Edits.key(last.src1)] {
                if kind == "crossfade" {
                    let d = min(TimeMap.crossfade, (last.out1 - last.out0) / 2, (b - a) / rate / 2)
                    p.overlap = d
                    p.out0 -= d
                } else if kind == "fade" {
                    out[out.count - 1].fadeOut = TimeMap.fade
                    p.fadeIn = TimeMap.fade
                }
            }
            out.append(p)
        }
        pieces = out
    }

    var outputDuration: Double { pieces.last?.out1 ?? 0 }

    func source(_ out: Double) -> Double {
        guard let p = pieces.last(where: { out >= $0.out0 }) ?? pieces.first else { return out }
        return min(p.src1, p.src0 + max(0, out - p.out0) * p.rate)
    }

    /// The output time of a source instant; one inside a removed part lands where the next part starts.
    func output(_ src: Double) -> Double {
        for p in pieces {
            if src < p.src0 { return p.out0 }
            if src <= p.src1 { return p.out0 + (src - p.src0) / p.rate }
        }
        return outputDuration
    }
}

// MARK: - Composition

/// The framing the compositor draws with: swapped whole when a look, effect,
/// text or move changes, so the playback needn't be rebuilt.
// @ref LLP 0003#no-blinking — swap state and redraw in place, never rebuild for a look change
final class RenderState: @unchecked Sendable {
    private var framing: Framing
    private let lock = NSLock()
    init(_ f: Framing) { framing = f }
    var current: Framing { lock.lock(); defer { lock.unlock() }; return framing }
    func update(_ f: Framing) { lock.lock(); framing = f; lock.unlock() }
}

/// One stretch of output time: one piece's frames, or two blending.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Layer { let track: CMPersistentTrackID; let piece: TimeMap.Piece }
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer]
    let state: RenderState

    init(_ range: CMTimeRange, _ layers: [Layer], _ state: RenderState) {
        timeRange = range
        self.layers = layers
        self.state = state
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.track) }
    }
}

// @ref LLP 0003#one-renderer-for-everything — preview, export and CLI all draw here
final class StudioCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? StudioInstruction, let out = request.renderContext.newPixelBuffer() else {
            return request.finish(with: NSError(domain: "ExactStudio", code: 1))
        }
        let framing = ins.state.current
        let now = request.compositionTime.seconds
        var frames: [CIImage] = []
        var last = 0.0
        for layer in ins.layers {
            guard let buffer = request.sourceFrame(byTrackID: layer.track) else { continue }
            let p = layer.piece
            let t = min(p.src1, p.src0 + max(0, now - p.out0) * p.rate)
            var fade = 1.0
            if p.fadeIn > 0 { fade = min(fade, Ease.smooth((now - p.out0) / p.fadeIn)) }
            if p.fadeOut > 0 { fade = min(fade, Ease.smooth((p.out1 - now) / p.fadeOut)) }
            frames.append(framing.render(CIImage(cvPixelBuffer: buffer), at: t, opacity: fade, texts: false))
            last = t
        }
        var image = frames.first ?? CIImage(color: .black)
        if frames.count == 2, let next = ins.layers.last?.piece {
            let u = Ease.inOut((now - next.out0) / max(next.overlap, 0.001))
            let d = CIFilter.dissolveTransition()
            d.inputImage = frames[0]
            d.targetImage = frames[1]
            d.time = Float(u)
            image = d.outputImage ?? frames[1]
        }
        image = framing.overlay(image, at: last)
        let size = request.renderContext.size
        // A smaller export: the frame is drawn at the canvas size, then scaled down.
        if abs(size.width - framing.canvas.width) > 0.5 || abs(size.height - framing.canvas.height) > 0.5 {
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / framing.canvas.width, y: size.height / framing.canvas.height))
        }
        StudioCompositor.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: StudioCompositor.space)
        request.finish(withComposedVideoFrame: out)
    }
}

/// Export qualities: how large the video is and how hard it is compressed. Only ever scales down.
// @ref LLP 0003#export — qualities only scale down; the same frame, drawn smaller
enum ExportQuality {
    static let names = ["best", "1080p", "720p", "small"]

    /// The longest side, in pixels; nil keeps the canvas size.
    static func longSide(_ name: String) -> CGFloat? {
        switch name { case "1080p": 1920; case "720p": 1280; case "small": 960; default: nil }
    }

    static func size(_ name: String, canvas: CGSize) -> CGSize {
        guard let cap = longSide(name), max(canvas.width, canvas.height) > cap else { return canvas }
        let k = cap / max(canvas.width, canvas.height)
        // Even sides: H.264 needs them.
        return CGSize(width: (canvas.width * k / 2).rounded() * 2, height: (canvas.height * k / 2).rounded() * 2)
    }

    static func preset(_ name: String) -> String {
        name == "small" ? AVAssetExportPreset960x540 : AVAssetExportPresetHighestQuality
    }

    /// One export session for a made composition, at `name`'s quality.
    static func session(_ asset: AVAsset, _ composition: AVMutableVideoComposition, audio: AVAudioMix?, quality name: String, to out: URL) -> AVAssetExportSession? {
        composition.renderSize = size(name, canvas: composition.renderSize)
        guard let s = AVAssetExportSession(asset: asset, presetName: preset(name)) else { return nil }
        s.outputURL = out
        s.outputFileType = .mp4
        s.videoComposition = composition
        s.audioMix = audio
        s.audioTimePitchAlgorithm = .spectral
        s.shouldOptimizeForNetworkUse = true
        return s
    }
}

enum Composition {
    /// The recording with its removed parts, speed changes and transitions,
    /// drawn by StudioCompositor with `state`'s framing, and the sounds added over it:
    /// `sounds` names the sound each added audio track plays, by track id.
    static func make(asset: AVAsset, meta: RecordingMeta, edits: Edits, state: RenderState) throws
        -> (asset: AVAsset, video: AVMutableVideoComposition, map: TimeMap, sounds: [CMPersistentTrackID: String]) {
        guard let source = asset.tracks(withMediaType: .video).first else { throw CompositionError.noVideo }
        let duration = min(meta.duration, asset.duration.seconds)
        let map = TimeMap(duration: duration, edits: edits)
        let mix = AVMutableComposition()
        // Two tracks, the pieces alternating between them, so a crossfade has both at once.
        guard let a = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let b = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CompositionError.noVideo }
        let tracks = [a, b]
        let start = source.timeRange.start
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 6000) }
        for (i, p) in map.pieces.enumerated() {
            let track = tracks[i % 2]
            let range = CMTimeRange(start: start + time(p.src0), end: start + time(p.src1))
            let at = time(p.out0)
            let end = track.timeRange.isEmpty ? CMTime.zero : track.timeRange.end
            if end < at { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            try track.insertTimeRange(range, of: source, at: at)
            if p.rate != 1 {
                track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: time(p.out1) - at)
            }
        }
        // @ref LLP 0002#sound — the sound is cut, sped up and crossfaded exactly like the picture
        if let sound = asset.tracks(withMediaType: .audio).first,
           let sa = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let sb = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let ears = [sa, sb]
            for (i, p) in map.pieces.enumerated() {
                let track = ears[i % 2]
                let range = CMTimeRange(start: start + time(p.src0), end: start + time(p.src1))
                // The sound may start a little after the picture or end before it.
                let r = range.intersection(sound.timeRange)
                guard r.duration.seconds > 0.001 else { continue }
                let at = time(p.out0 + (r.start - range.start).seconds / p.rate)
                let end = track.timeRange.isEmpty ? CMTime.zero : track.timeRange.end
                if end < at { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                try? track.insertTimeRange(r, of: sound, at: at)
                if p.rate != 1 {
                    track.scaleTimeRange(CMTimeRange(start: at, duration: r.duration), toDuration: time(r.duration.seconds / p.rate))
                }
            }
            // An empty track makes an export fail; one part uses only the first.
            for ear in ears where ear.segments.isEmpty { mix.removeTrack(ear) }
        }
        // @ref LLP 0002#sound — an added sound plays straight through from where its start lands
        let videoEnd = max(a.timeRange.end, b.timeRange.end)
        var added: [CMPersistentTrackID: String] = [:]
        for s in edits.sounds {
            // The file's asset must outlive this line, or its track reads as empty.
            guard let folder = state.current.folder else { continue }
            let held = AVURLAsset(url: folder.appendingPathComponent(s.file))
            guard let file = held.tracks(withMediaType: .audio).first else { continue }
            let at = time(map.output(s.start))
            let from = file.timeRange.start + time(max(0, s.offset))
            let length = min(time(max(0, s.length)), file.timeRange.end - from, videoEnd - at)
            guard length.seconds > 0.01, let track = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            if at > .zero { track.insertEmptyTimeRange(CMTimeRange(start: .zero, end: at)) }
            do { try track.insertTimeRange(CMTimeRange(start: from, duration: length), of: file, at: at) } catch { mix.removeTrack(track); continue }
            added[track.trackID] = s.id
        }
        // Instructions: a piece alone, then the stretch it shares with the next, end to end.
        var instructions: [StudioInstruction] = []
        let pieces = map.pieces
        var cursor = CMTime.zero
        for (i, p) in pieces.enumerated() {
            let layer = StudioInstruction.Layer(track: tracks[i % 2].trackID, piece: p)
            let hasNext = i + 1 < pieces.count
            let soloEnd = hasNext ? time(pieces[i + 1].out0) : mix.duration
            if soloEnd > cursor {
                instructions.append(StudioInstruction(CMTimeRange(start: cursor, end: soloEnd), [layer], state))
                cursor = soloEnd
            }
            if hasNext, pieces[i + 1].overlap > 0 {
                let next = StudioInstruction.Layer(track: tracks[(i + 1) % 2].trackID, piece: pieces[i + 1])
                let end = time(p.out1)
                if end > cursor {
                    instructions.append(StudioInstruction(CMTimeRange(start: cursor, end: end), [layer, next], state))
                    cursor = end
                }
            }
        }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = StudioCompositor.self
        composition.instructions = instructions
        composition.renderSize = state.current.canvas
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        return (mix, composition, map, added)
    }

    /// The recorded sound's volume over time: `edits.volume` throughout, ramping where the picture
    /// crossfades or fades. Each added sound (`sounds`, from `make`) at its own volume, fading in and out.
    static func audioMix(_ mix: AVAsset, map: TimeMap, edits: Edits, sounds: [CMPersistentTrackID: String]) -> AVAudioMix? {
        let all = mix.tracks(withMediaType: .audio)
        guard !all.isEmpty else { return nil }
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 6000) }
        var extra: [AVMutableAudioMixInputParameters] = []
        for track in all {
            guard let id = sounds[track.trackID], let s = edits.sounds.first(where: { $0.id == id }) else { continue }
            let ear = AVMutableAudioMixInputParameters(track: track)
            let v = Float(min(max(s.volume, 0), 1))
            // It plays where the track has sound; the fades stay inside that and apart.
            let span = track.segments.filter { !$0.isEmpty }.map(\.timeMapping.target)
            guard let first = span.first, let last = span.last else { continue }
            let a = first.start.seconds, b = last.end.seconds, d = b - a
            let fin = min(max(s.fadeIn, 0), d), fout = min(max(s.fadeOut, 0), d - fin)
            if fin > 0.001 {
                ear.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: time(a), duration: time(fin)))
            } else {
                ear.setVolume(v, at: time(a))
            }
            if fout > 0.001 {
                ear.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(b - fout), duration: time(fout)))
            }
            extra.append(ear)
        }
        let ears = all.filter { sounds[$0.trackID] == nil }
        let v = Float(min(max(edits.volume, 0), 1))
        let params = ears.map { AVMutableAudioMixInputParameters(track: $0) }
        let pieces = map.pieces
        for (i, p) in pieces.enumerated() where !params.isEmpty {
            let ear = params[i % params.count]
            let inLength = max(p.overlap, p.fadeIn)
            // Each track only plays inside its own pieces, so it needs no volume between them.
            if inLength > 0 {
                ear.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: time(p.out0), duration: time(inLength)))
            } else {
                ear.setVolume(v, at: time(p.out0))
            }
            let next = i + 1 < pieces.count ? pieces[i + 1] : nil
            let outLength = max(next?.overlap ?? 0, p.fadeOut)
            if outLength > 0 {
                ear.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(p.out1 - outLength), duration: time(outLength)))
            }
        }
        let audio = AVMutableAudioMix()
        audio.inputParameters = params + extra
        return audio
    }

    enum CompositionError: Error, CustomStringConvertible {
        case noVideo
        var description: String { "The recording has no video." }
    }
}
#endif
