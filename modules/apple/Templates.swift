// Ready-made edits: texts, effects, zooms and moves for a whole recording,
// laid out for the frame's shape. Times follow the recording's length; the
// clip's parts, its transitions and the 3D settings are the person's own.
#if os(macOS)
import Foundation

enum Templates {
    struct Made { var segments: [Segment]; var moves: [Move]; var base: Placement }

    /// Where things go on a frame of this shape.
    private struct Layout {
        /// The video's place while a text stands beside it, and where that text stands.
        var device: Placement, other: Placement
        var text: (x: Double, y: Double), textOther: (x: Double, y: Double)
        /// A title over the top, a caption under the bottom.
        var top: (x: Double, y: Double), bottom: (x: Double, y: Double)
        var wide: Bool

        static func of(_ aspect: String) -> Layout {
            switch aspect {
            case "16:9", "4:3":
                return Layout(device: Placement(x: 0.66, y: 0.5, scale: 0.82), other: Placement(x: 0.34, y: 0.5, scale: 0.82),
                              text: (0.3, 0.46), textOther: (0.7, 0.46), top: (0.5, 0.1), bottom: (0.5, 0.92), wide: true)
            case "9:16":
                return Layout(device: Placement(x: 0.5, y: 0.57, scale: 0.78), other: Placement(x: 0.5, y: 0.57, scale: 0.78),
                              text: (0.5, 0.1), textOther: (0.5, 0.1), top: (0.5, 0.1), bottom: (0.5, 0.94), wide: false)
            default: // 1:1 and Fit
                return Layout(device: Placement(x: 0.5, y: 0.58, scale: 0.74), other: Placement(x: 0.5, y: 0.58, scale: 0.74),
                              text: (0.5, 0.12), textOther: (0.5, 0.12), top: (0.5, 0.12), bottom: (0.5, 0.92), wide: false)
            }
        }
    }

    static let names = ["launch", "hero", "tour", "teaser"]

    /// `d` is the video's length as it plays; `source` maps a time of it to the recording's,
    /// so a template lines up with what plays whatever parts are cut.
    static func make(_ name: String, duration d: Double, source: @escaping (Double) -> Double, aspect: String, clicks: [Point], three: ThreeD) -> Made? {
        guard d > 1.5 else { return nil }
        let L = Layout.of(aspect)
        var n = 0
        func id(_ p: String) -> String { n += 1; return "\(p)\(n)-\(Int(Date().timeIntervalSince1970) % 100000)" }
        /// A time: a share of the recording, kept inside it.
        func at(_ f: Double) -> Double { source(min(max(f * d, 0), d)) }
        /// Seconds into the video as it plays, in the recording's time.
        func sec(_ t: Double) -> Double { source(min(max(t, 0), d)) }
        let end = sec(d)
        func text(_ s: Double, _ e: Double, _ words: String, _ pos: (x: Double, y: Double), size: Double, lane: Int = 0,
                  style: String = "shadow", animIn: String = "letters", animOut: String = "fade", loop: String = "none",
                  weight: String = "heavy") -> Segment {
            Segment(id: id("t"), kind: "text", start: s, end: max(e, s + 0.4), lane: lane, text: words, x: pos.x, y: pos.y, size: size,
                    color: "white", weight: weight, style: style, animIn: animIn, animOut: animOut, loop: loop, rotation: 0)
        }
        func effect(_ kind: String, _ s: Double, _ e: Double, lane: Int, scope: String? = nil) -> Segment {
            Segment(id: id("e"), kind: kind, start: s, end: max(e, s + 0.3), lane: lane, scope: scope)
        }
        func zoom(_ s: Double, _ e: Double, _ level: Double, lane: Int) -> Segment {
            Segment(id: id("z"), kind: "zoom", start: s, end: max(e, s + 0.4), lane: lane, level: level)
        }
        func turn(_ s: Double, _ e: Double, _ pose: Angles, orbit: Bool = false, lane: Int) -> Segment {
            Segment(id: id("d"), kind: "3d", start: s, end: max(e, s + 0.6), lane: lane, style: orbit ? "orbit" : "hold",
                    tilt: pose.tilt, turn: pose.turn, roll: pose.roll)
        }
        func move(_ t: Double, _ to: Placement, _ style: String, _ dur: Double) -> Move {
            Move(id: id("m"), t: t, to: to, style: style, duration: min(dur, max(0.2, t)))
        }
        let titleSize = L.wide ? 0.1 : 0.075, captionSize = L.wide ? 0.05 : 0.045
        let centre = Placement()

        switch name {
        case "launch":
            // A blurred title card, then the video; zooms where the clicks are; an end line.
            var segs = [
                effect("blur", sec(0), at(0.16), lane: 1, scope: "frame"),
                text(sec(0.1), at(0.15), "Your App", (0.5, 0.44), size: titleSize * 1.2, animIn: "letters", animOut: "blur"),
                text(sec(0.4), at(0.15), "The one-line pitch goes here", (0.5, 0.57), size: captionSize * 0.8, animIn: "rise", animOut: "blur", weight: "bold"),
                text(at(0.86), end, "Try it today", L.bottom, size: captionSize, style: "pill", animIn: "letters-pop", animOut: "none"),
            ]
            var zooms = Edits.autoZooms(clicks, duration: end, level: 1.6).filter { $0.start > at(0.17) && $0.end < at(0.85) }
            if zooms.isEmpty { zooms = [zoom(at(0.35), at(0.58), 1.5, lane: 2)] }
            segs += zooms.map { var z = $0; z.lane = 2; return z }
            return Made(segments: segs, moves: [], base: centre)

        case "hero":
            // Turned into a hero angle beside the title; a feature line; an orbit; to the centre at the end.
            let segs = [
                turn(sec(0), at(0.42), Angles(tilt: 10, turn: L.wide ? -26 : -18, roll: 0), lane: 1),
                text(at(0.04), at(0.3), "Meet Your App", L.text, size: titleSize, animIn: "spin", animOut: "blur", loop: "float"),
                text(at(0.32), at(0.58), "Built for speed", L.text, size: captionSize, style: "pill", animIn: "letters-pop", animOut: "fade"),
                turn(at(0.6), at(0.8), Angles(tilt: 8, turn: 0, roll: 0), orbit: true, lane: 1),
                text(at(0.62), at(0.8), "Every angle", L.text, size: captionSize * 1.1, animIn: "drop", animOut: "pop"),
                text(at(0.88), end, "Available now", L.bottom, size: captionSize, style: "shadow", animIn: "typewriter", animOut: "none"),
            ]
            let moves = L.wide ? [move(at(0.86), Placement(x: 0.5, y: 0.46, scale: 0.8), "spring", 1.0)] : []
            return Made(segments: segs, moves: moves, base: L.device)

        case "tour":
            // Three features, the video swapping sides between them (zooming through, then swiping).
            var segs = [
                text(at(0.03), at(0.3), "1 · The first feature", L.text, size: captionSize * 1.1, style: "pill", animIn: "letters-pop", animOut: "blur"),
                text(at(0.38), at(0.63), "2 · The second feature", L.textOther, size: captionSize * 1.1, style: "pill", animIn: "slide", animOut: "blur"),
                effect("spotlight", at(0.4), at(0.62), lane: 3),
                text(at(0.71), at(0.96), "3 · The third feature", L.text, size: captionSize * 1.1, style: "pill", animIn: "drop", animOut: "fade"),
            ]
            var moves: [Move] = []
            if L.wide {
                moves = [move(at(0.36), L.other, "zoom", 1.2), move(at(0.69), L.device, "swipe", 1.0)]
            } else {
                segs.append(effect("mono", at(0.33), at(0.37), lane: 1))
            }
            return Made(segments: segs, moves: moves, base: L.device)

        case "teaser":
            // Punchy: a blurred hook, pops, a zoom out, a wave, a 3D tumble, a call to action.
            let segs = [
                effect("blur", sec(0), at(0.14), lane: 1, scope: "frame"),
                text(sec(0.1), at(0.13), "Wait for it…", (0.5, 0.48), size: titleSize, animIn: "typewriter", animOut: "pop"),
                zoom(at(0.36), at(0.5), 0.85, lane: 2),
                text(at(0.36), at(0.52), "So smooth", L.top, size: captionSize * 1.3, animIn: "letters", animOut: "fall", loop: "wave"),
                turn(at(0.56), at(0.76), Angles(tilt: 22, turn: 32, roll: -12), orbit: true, lane: 3),
                text(at(0.84), end, "Link in bio", L.bottom, size: captionSize * 1.2, style: "pill", animIn: "letters-pop", animOut: "none", loop: "pulse"),
            ]
            let moves = [move(at(0.2), L.wide ? L.other : Placement(x: 0.5, y: L.device.y, scale: L.device.scale * 1.08), "pop", 0.7),
                         move(at(0.32), L.wide ? L.device : L.device, "pop", 0.7),
                         move(at(0.82), Placement(x: 0.5, y: L.wide ? 0.46 : L.device.y, scale: L.device.scale), "spring", 0.9)]
            return Made(segments: segs, moves: moves, base: centre)

        default:
            return nil
        }
    }
}
#endif
