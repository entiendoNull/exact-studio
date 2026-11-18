#if os(macOS)
import Foundation
import CoreImage

// @ref LLP 0003#templates
enum Templates {
    struct Made { var segments: [Segment]; var moves: [Move]; var base: Placement }

    struct Info {
        let name: String, title: String, line: String
        let placeholders: Bool
        let shortest: Double
    }

    static let all = [
        Info(name: "clean", title: "Clean Demo", line: "Zooms on your clicks, no text. For a demo the screen explains", placeholders: false, shortest: 3),
        Info(name: "hero", title: "Hero Angle", line: "Opens at a slight 3D angle, then zooms on clicks. For a page header", placeholders: false, shortest: 5),
        Info(name: "before-after", title: "Before / After", line: "Labels the screen before and after the change. For a fix or a redesign", placeholders: false, shortest: 6),
        Info(name: "spotlight", title: "Feature Spotlight", line: "Zooms on the key action, then one line names it. For one feature", placeholders: true, shortest: 5),
        Info(name: "social", title: "Social Hook", line: "A hook line for the first seconds, then zooms on clicks. For a feed", placeholders: true, shortest: 5),
        Info(name: "steps", title: "Tutorial Steps", line: "A numbered line for each step, as you click. For a how-to", placeholders: true, shortest: 5),
        Info(name: "launch", title: "Product Launch", line: "A title over a blurred opening, zooms, a closing line. For a launch", placeholders: true, shortest: 9.5),
    ]
    static var names: [String] { all.map(\.name) }

    static func refusal(_ info: Info, duration d: Double) -> String {
        d < info.shortest ? "\(info.title) needs a video at least \(Int(info.shortest.rounded(.up))) s long."
            : "\(info.title) zooms on clicks, and no click leaves room for a zoom here. Try Hero Angle, or add a zoom yourself."
    }
    static func info(_ name: String) -> Info? { all.first { $0.name == name } }

    // @ref LLP 0003#templates — the reading-speed rule: 1 s + 0.3 s a word, plus the animations in and out
    static let slotWords = 6
    static func onScreen(words: Int) -> Double { max(1.5, 1.0 + 0.3 * Double(words)) + 0.55 + 0.45 }
    static let slot = onScreen(words: slotWords)

    struct Stage {
        var ratio: Double
        var video: Placement
        var text: (x: Double, y: Double)
        var room: Double
        var beside: Bool
        var line: Double, title: Double
        var color: String, style: String

        static func of(meta: RecordingMeta, look: Look) -> Stage {
            let (canvas, subject) = Framing.layout(meta: meta, look: look)
            let r = Double(canvas.width / max(canvas.height, 1))
            let sw = Double(subject.width / max(canvas.width, 1)), sh = Double(subject.height / max(canvas.height, 1))
            let line = r >= 1 ? 0.05 : 0.042, title = r >= 1 ? 0.08 : 0.058
            let column = 0.34, gap = 0.03
            let sideScale = min(1, (0.9 - column - gap) / max(sw, 0.01), 0.86 / max(sh, 0.01))
            let band = line * 1.6, vgap = 0.035
            let topScale = min(1, 0.92 / max(sw, 0.01), (0.88 - band - vgap) / max(sh, 0.01))
            let (color, style) = Stage.ink(look)
            if r >= 1.2 && sideScale >= topScale {
                let vw = sw * sideScale, left = (1 - (column + gap + vw)) / 2
                return Stage(ratio: r, video: Placement(x: left + column + gap + vw / 2, y: 0.5, scale: sideScale),
                             text: (left + column / 2, 0.5), room: column, beside: true, line: line, title: title, color: color, style: style)
            }
            let vh = sh * topScale, top = (1 - (band + vgap + vh)) / 2
            return Stage(ratio: r, video: Placement(x: 0.5, y: top + band + vgap + vh / 2, scale: topScale),
                         text: (0.5, top + band / 2), room: 0.9, beside: false, line: line, title: title, color: color, style: style)
        }

        static func ink(_ look: Look) -> (String, String) {
            if look.background == "video" { return ("white", "pill") }
            let g = Backgrounds.gradient(look)
            func lum(_ c: CIColor) -> Double { 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue) }
            return (lum(g.a) + lum(g.b)) / 2 > 0.6 ? ("black", "plain") : ("white", "shadow")
        }
    }

    static func clicks(_ meta: RecordingMeta, map: TimeMap) -> [Double] {
        meta.clicks.map(\.t).filter { abs(map.source(map.output($0)) - $0) < 0.01 }.map { map.output($0) }.sorted()
    }

    // @ref LLP 0003#templates
    static func zooms(_ clicks: [Double], from lo: Double, to hi: Double, duration d: Double) -> [(start: Double, end: Double)] {
        var spans: [(start: Double, end: Double, clicks: Int)] = []
        for c in clicks {
            let s = c - 0.5, e = max(c + 2.0, s + 2.8)
            if let last = spans.last, s - last.end < 1.0 {
                if e - last.start <= 8 {
                    spans[spans.count - 1].end = max(last.end, e)
                    spans[spans.count - 1].clicks += 1
                } else if e - (last.end + 1.0) >= 2.5 {
                    spans.append((last.end + 1.0, e, 1))
                }
            } else {
                spans.append((s, e, 1))
            }
        }
        let inside = spans.map { (start: $0.start, end: min($0.end, hi), clicks: $0.clicks) }.filter { $0.start >= lo && $0.end - $0.start >= 2.5 }
        let most = max(1, Int(d / 8))
        let kept = inside.enumerated().sorted { ($0.element.clicks, -$0.offset) > ($1.element.clicks, -$1.offset) }.prefix(most).map(\.element)
        return kept.sorted { $0.start < $1.start }.map { ($0.start, $0.end) }
    }

    static func key(_ clicks: [Double], in lo: Double, _ hi: Double, duration d: Double) -> Double? {
        let inside = clicks.enumerated().filter { $0.element >= lo && $0.element <= hi }
        return inside.max { a, b in
            let ga = (a.offset + 1 < clicks.count ? clicks[a.offset + 1] : d) - a.element
            let gb = (b.offset + 1 < clicks.count ? clicks[b.offset + 1] : d) - b.element
            return ga < gb
        }?.element
    }

    static func make(_ name: String, map: TimeMap, meta: RecordingMeta, look: Look, keep: [Segment] = []) -> Made? {
        guard let info = info(name) else { return nil }
        let d = map.outputDuration
        guard d >= info.shortest else { return nil }
        let stage = Stage.of(meta: meta, look: look)
        let clicks = clicks(meta, map: map)
        let taken = Set(keep.map(\.id))
        var n = 0
        func id(_ p: String) -> String {
            n += 1
            var made = "\(name)-\(p)\(n)"
            while taken.contains(made) { made += "x" }
            return made
        }
        func src(_ t: Double) -> Double { map.source(min(max(t, 0), d)) }
        func text(_ s: Double, _ e: Double, _ words: String, at pos: (x: Double, y: Double), size: Double,
                  animIn: String = "rise", animOut: String = "fade", overVideo: Bool = false) -> Segment {
            let room = abs(pos.x - 0.5) < 0.01 ? 0.8 : stage.room
            let fitted = max(0.04, min(size, room * stage.ratio / (Double(words.count) * 0.5)))
            return Segment(id: id("t"), kind: "text", start: src(s), end: src(e), lane: 0, text: words, x: pos.x, y: pos.y, size: fitted,
                    color: overVideo ? "white" : stage.color, weight: "bold", style: overVideo ? "pill" : stage.style, animIn: animIn, animOut: animOut, loop: "none", rotation: 0)
        }
        func zoom(_ z: (start: Double, end: Double)) -> Segment {
            Segment(id: id("z"), kind: "zoom", start: src(z.start), end: src(z.end), lane: 0, level: 1.6)
        }
        let centre = Placement()
        let rest = d - 1.2

        switch name {
        case "clean":
            let segs = zooms(clicks, from: 0, to: rest, duration: d).map(zoom)
            return segs.isEmpty ? nil : Made(segments: segs, moves: [], base: centre)

        case "hero":
            let open = min(3.2, max(2.4, (clicks.first ?? 3.7) - 0.5))
            let turn = Segment(id: id("d"), kind: "3d", start: src(0), end: src(open), lane: 0, style: "hold",
                               tilt: 8, turn: stage.ratio >= 1 ? -16 : -12, roll: 0)
            return Made(segments: [turn] + zooms(clicks, from: open + 0.5, to: rest, duration: d).map(zoom), moves: [], base: centre)

        case "social":
            let hook = text(0.2, 0.2 + slot, "[Hook line]", at: stage.text, size: stage.line)
            return Made(segments: [hook] + zooms(clicks, from: 0.2 + slot + 0.4, to: rest, duration: d).map(zoom), moves: [], base: stage.video)

        case "spotlight":
            let words = "[Name the feature]"
            if let k = key(clicks, in: 0.8, d - 2.6, duration: d) {
                let z = (start: k - 0.5, end: k + 2.3)
                if d - (z.end + 0.2) >= slot {
                    return Made(segments: [zoom(z), text(z.end + 0.2, d, words, at: stage.text, size: stage.line)], moves: [], base: stage.video)
                }
                if z.start >= 0.2 + slot + 0.4 {
                    return Made(segments: [text(0.2, 0.2 + slot, words, at: stage.text, size: stage.line), zoom(z)], moves: [], base: stage.video)
                }
            }
            return Made(segments: [text(0.2, d, words, at: stage.text, size: stage.line)], moves: [], base: stage.video)

        case "steps":
            var starts: [Double]
            if clicks.isEmpty {
                let count = max(1, min(3, Int(d / (slot + 0.5))))
                starts = (0..<count).map { Double($0) * d / Double(count) }
            } else {
                starts = clicks.map { $0 - 0.6 }
            }
            let spacing = max(slot + 0.35, d / 5)
            var picked = [0.2]
            for s in starts where s - picked.last! >= spacing { picked.append(s) }
            if picked.count > 1, d - picked.last! < slot { picked.removeLast() }
            let segs = picked.enumerated().map { i, s in
                text(s, i + 1 < picked.count ? picked[i + 1] - 0.35 : d, "\(i + 1). [What to do]", at: stage.text, size: stage.line)
            }
            return Made(segments: segs, moves: [], base: stage.video)

        case "before-after":
            let need = onScreen(words: 1)
            let joins = zip(map.pieces, map.pieces.dropFirst()).filter { abs($1.src0 - $0.src1) > 0.01 }.map(\.1.out0)
                .filter { $0 >= 0.2 + need + 0.15 && $0 <= d - 0.25 - need }
            let k = joins.min { abs($0 - d / 2) < abs($1 - d / 2) } ?? key(clicks, in: 0.2 + need + 0.15, d - 0.25 - need, duration: d) ?? d / 2
            return Made(segments: [text(0.2, k - 0.15, "Before", at: stage.text, size: stage.line),
                                   text(k + 0.25, d, "After", at: stage.text, size: stage.line)], moves: [], base: stage.video)

        case "launch":
            let pitch = d >= 14
            let titleEnd = (pitch ? 0.6 : 0.2) + slot
            let titleY = pitch ? 0.45 : 0.5
            var segs = [
                Segment(id: id("e"), kind: "blur", start: src(0), end: src(titleEnd + 0.15), lane: 0, scope: "frame"),
                text(0.2, titleEnd, "[Product name]", at: (0.5, titleY), size: stage.title, animIn: "blur", overVideo: true),
            ]
            if pitch { segs.append(text(0.6, titleEnd, "[One-line pitch]", at: (0.5, titleY + stage.title * 0.75 + stage.line * 1.2), size: stage.line, overVideo: true)) }
            let close = d - 4.0
            segs.append(text(close, d, "[Closing line]", at: stage.text, size: stage.line, animOut: "none"))
            let move = Move(id: id("m"), t: src(close - 0.1), to: stage.video, style: "smooth", duration: 0.9)
            segs += zooms(clicks, from: titleEnd + 0.5, to: close - 1.0 - 1.0, duration: d).map(zoom)
            return Made(segments: segs, moves: [move], base: centre)

        default:
            return nil
        }
    }

    static func kept(_ edits: Edits) -> [Segment] { edits.speeds + edits.images + edits.masks }

    static func apply(_ made: Made, to edits: Edits) -> Edits {
        var next = edits
        next.pack(made.segments + kept(edits))
        next.moves = made.moves
        next.base = made.base
        return next
    }
}

extension Segment {
    // @ref LLP 0003#templates
    var isPlaceholder: Bool { kind == "text" && (text ?? "").range(of: #"\[[^\]]*\]"#, options: .regularExpression) != nil }
}
#endif
