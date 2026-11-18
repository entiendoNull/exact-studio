// @ref LLP 0002#split
import Foundation

struct SplitRefused: Error { let why: String }

extension Segment {
    func joins(_ next: Segment) -> Bool {
        joinEnd == true && next.joinStart == true && id != next.id && kind == next.kind && space == next.space && lane == next.lane
            && Edits.same(end, next.start)
    }
}

extension Sound {
    func joins(_ next: Sound, map: TimeMap) -> Bool {
        joinEnd == true && next.joinStart == true && id != next.id && file == next.file && lane == next.lane
            && Edits.same(playing(map).end, next.playing(map).start)
    }

    static func fades(from a: Double, to b: Double, fadeIn: Double, fadeOut: Double) -> (fadeIn: Double, fadeOut: Double) {
        let d = max(0, b - a), fin = min(max(fadeIn, 0), d)
        return (fin, min(max(fadeOut, 0), d - fin))
    }

    static func ramps(_ ha: Double, _ hb: Double, run a: Double, _ b: Double, fadeIn: Double, fadeOut: Double)
        -> [(start: Double, end: Double, from: Double, to: Double)] {
        let (fin, fout) = fades(from: a, to: b, fadeIn: fadeIn, fadeOut: fadeOut)
        let knots = ([ha, hb] + [a + fin, b - fout].filter { $0 > ha + 0.0005 && $0 < hb - 0.0005 }).sorted()
        return zip(knots, knots.dropFirst()).filter { $1 - $0 > 0.0005 }.map {
            ($0, $1, level(at: $0, from: a, to: b, fadeIn: fadeIn, fadeOut: fadeOut), level(at: $1, from: a, to: b, fadeIn: fadeIn, fadeOut: fadeOut))
        }
    }

    static func level(at x: Double, from a: Double, to b: Double, fadeIn: Double, fadeOut: Double) -> Double {
        let (fin, fout) = fades(from: a, to: b, fadeIn: fadeIn, fadeOut: fadeOut)
        if fin > 0.001, x < a + fin { return Ease.clamp((x - a) / fin) }
        if fout > 0.001, x > b - fout { return Ease.clamp((b - x) / fout) }
        return 1
    }
}

enum Joins {
    static func run<T>(_ s: T, in all: [T], id: (T) -> String, joins: (T, T) -> Bool) -> [T] {
        var out = [s]
        while let p = all.first(where: { joins($0, out[0]) }), !out.contains(where: { id($0) == id(p) }) { out.insert(p, at: 0) }
        while let n = all.first(where: { joins(out[out.count - 1], $0) }), !out.contains(where: { id($0) == id(n) }) { out.append(n) }
        return out
    }

    static func run(_ s: Segment, in all: [Segment]) -> [Segment] { run(s, in: all, id: \.id) { $0.joins($1) } }

    static func run(_ s: Sound, in all: [Sound], map: TimeMap) -> [Sound] { run(s, in: all, id: \.id) { $0.joins($1, map: map) } }

    static func runs(_ all: [Segment]) -> [String: [Segment]] {
        var out: [String: [Segment]] = [:]
        for s in all where s.joinStart == true || s.joinEnd == true {
            let r = run(s, in: all)
            if r.count > 1 { out[s.id] = r }
        }
        return out
    }

    static func whole(_ s: Segment, run: [Segment]) -> Segment {
        guard run.count > 1, let first = run.first, let last = run.last else { return s }
        var w = s
        w.start = first.id == s.id ? s.start : first.start
        w.end = last.id == s.id ? s.end : last.end
        if s.isOverlay {
            let members = run.map { $0.id == s.id ? s : $0 }
            let moves = members.flatMap { $0.moves ?? [] }, effects = members.flatMap { $0.effects ?? [] }
            w.moves = moves.isEmpty ? nil : moves
            w.effects = effects.isEmpty ? nil : effects
        }
        return w
    }

    static func presence(_ s: Segment, whole w: Segment, at t: Double, ramp: Double) -> Double {
        guard t >= s.start, t < s.end else { return 0 }
        return spanPresence(w, at: t, ramp: ramp)
    }
}

private func spanPresence(_ s: Segment, at t: Double, ramp: Double) -> Double { presence(s, at: t, ramp: ramp) }

extension Edits {
    static let shortest = 0.1

    private var takenIDs: Set<String> {
        Set(segments.map(\.id) + segments.flatMap { ($0.effects ?? []).map(\.id) + ($0.moves ?? []).map(\.id) } + sounds.map(\.id))
    }

    private static func fresh(_ base: String, taken: inout Set<String>) -> String {
        let stem = base.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        taken.insert("\(stem)-\(n)")
        return "\(stem)-\(n)"
    }

    private static func fits(_ t: Double, in s: Segment) -> Bool { t - s.start >= shortest && s.end - t >= shortest }

    private static let inside = "Put the playhead inside it, at least 0.1 s from each end."

    mutating func splitClip(at t: Double, duration: Double) throws {
        guard t > 0.05, t < duration - 0.05 else { throw SplitRefused(why: "Move the playhead into the clip to split it.") }
        guard !splits.contains(where: { abs($0 - t) < 0.05 }) else { throw SplitRefused(why: "The clip is already split there.") }
        if let p = pieces(duration).first(where: { t > $0.start && t < $0.end }), p.removed { removed.append(t) }
        splits = (splits + [t]).sorted()
    }

    @discardableResult
    mutating func splitSegment(_ id: String, at t: Double) throws -> String {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { throw SplitRefused(why: "There is no segment \(id).") }
        let s = segments[i]
        guard Edits.fits(t, in: s) else { throw SplitRefused(why: Edits.inside) }
        var taken = takenIDs
        var left = s, right = s
        right.id = Edits.fresh(s.id, taken: &taken)
        left.end = t
        left.joinEnd = true
        right.start = t
        right.joinStart = true
        if s.isOverlay {
            let moves = s.moves ?? []
            left.moves = moves.filter { $0.t <= t }.nilIfEmpty
            right.moves = moves.filter { $0.t > t }.nilIfEmpty
            var l: [Segment] = [], r: [Segment] = []
            for fx in s.effects ?? [] {
                if fx.end <= t + 0.0005 { l.append(fx); continue }
                if fx.start >= t - 0.0005 { r.append(fx); continue }
                guard Edits.fits(t, in: fx) else {
                    throw SplitRefused(why: "Its \(fx.kind) effect would leave a piece shorter than 0.1 s. Move the playhead.")
                }
                var a = fx, b = fx
                b.id = Edits.fresh(fx.id, taken: &taken)
                a.end = t
                a.joinEnd = true
                b.start = t
                b.joinStart = true
                l.append(a)
                r.append(b)
            }
            left.effects = l.nilIfEmpty
            right.effects = r.nilIfEmpty
        }
        segments[i] = left
        segments.insert(right, at: i + 1)
        return right.id
    }

    @discardableResult
    mutating func splitImageEffect(image: String, effect: String, at t: Double) throws -> String {
        guard let i = segments.firstIndex(where: { $0.id == image && $0.isOverlay }),
              let j = segments[i].effects?.firstIndex(where: { $0.id == effect }) else { throw SplitRefused(why: "There is no effect \(effect) on an image or a text \(image).") }
        let fx = segments[i].effects![j]
        guard Edits.fits(t, in: fx) else { throw SplitRefused(why: Edits.inside) }
        var taken = takenIDs
        var left = fx, right = fx
        right.id = Edits.fresh(fx.id, taken: &taken)
        left.end = t
        left.joinEnd = true
        right.start = t
        right.joinStart = true
        segments[i].effects![j] = left
        segments[i].effects!.insert(right, at: j + 1)
        return right.id
    }

    @discardableResult
    mutating func splitSound(_ id: String, at t: Double, map: TimeMap) throws -> String {
        guard let i = sounds.firstIndex(where: { $0.id == id }) else { throw SplitRefused(why: "There is no sound \(id).") }
        let s = sounds[i]
        let (a, b) = s.playing(map), x = map.output(t)
        guard x - a >= Edits.shortest, b - x >= Edits.shortest else { throw SplitRefused(why: Edits.inside) }
        var taken = takenIDs
        var left = s, right = s
        right.id = Edits.fresh(s.id, taken: &taken)
        let played = ((x - a) * 1e6).rounded() / 1e6
        left.length = played
        left.joinEnd = true
        right.start = t
        right.offset = ((s.offset + played) * 1e6).rounded() / 1e6
        right.length = ((s.length - played) * 1e6).rounded() / 1e6
        right.joinStart = true
        sounds[i] = left
        sounds.insert(right, at: i + 1)
        return right.id
    }

    @discardableResult
    mutating func splitAll(at t: Double, duration: Double, map: TimeMap) throws -> [String] {
        var next = self, cut: [String] = []
        if (try? next.splitClip(at: t, duration: duration)) != nil { cut.append("clip") }
        for s in segments where Edits.fits(t, in: s) {
            if let made = try? next.splitSegment(s.id, at: t) { cut.append("\(s.kind) \(s.id) → \(made)") }
        }
        for s in sounds {
            if let made = try? next.splitSound(s.id, at: t, map: map) { cut.append("sound \(s.id) → \(made)") }
        }
        guard !cut.isEmpty else { throw SplitRefused(why: "Nothing under the playhead can be split there.") }
        self = next
        return cut
    }

    mutating func dropLooseJoins(map: TimeMap) {
        let all = segments
        func tidy(_ s: Segment, among pool: [Segment]) -> Segment {
            var m = s
            if s.joinStart != nil, !pool.contains(where: { $0.joins(s) }) { m.joinStart = nil }
            if s.joinEnd != nil, !pool.contains(where: { s.joins($0) }) { m.joinEnd = nil }
            return m
        }
        segments = all.map { s in
            var m = tidy(s, among: all)
            if s.isOverlay, let fx = s.effects {
                let pool = Joins.whole(s, run: Joins.run(s, in: all)).effects ?? fx
                m.effects = fx.map { tidy($0, among: pool) }
            }
            return m
        }
        let heard = sounds
        sounds = heard.map { s in
            var m = s
            if s.joinStart != nil, !heard.contains(where: { $0.joins(s, map: map) }) { m.joinStart = nil }
            if s.joinEnd != nil, !heard.contains(where: { s.joins($0, map: map) }) { m.joinEnd = nil }
            return m
        }
    }

    func looseJoins(map: TimeMap) -> [String] {
        var copy = self
        copy.dropLooseJoins(map: map)
        var out: [String] = []
        func edges(_ a: Segment, _ b: Segment) -> [String] {
            (a.joinStart != b.joinStart ? ["joinStart"] : []) + (a.joinEnd != b.joinEnd ? ["joinEnd"] : [])
        }
        for (a, b) in zip(segments, copy.segments) {
            for e in edges(a, b) { out.append("\(a.kind) \(a.id): \(e), but no \(a.kind) on its lane \(e == "joinEnd" ? "starts where it ends" : "ends where it starts") with \(e == "joinEnd" ? "joinStart" : "joinEnd")") }
            for (x, y) in zip(a.effects ?? [], b.effects ?? []) {
                for e in edges(x, y) { out.append("\(a.kind) \(a.id): its \(x.kind) effect \(x.id): \(e), but no \(x.kind) effect on its row \(e == "joinEnd" ? "starts where it ends" : "ends where it starts") with \(e == "joinEnd" ? "joinStart" : "joinEnd") (in this \(a.kind) or one joined to it)") }
            }
        }
        for (a, b) in zip(sounds, copy.sounds) {
            if a.joinStart != b.joinStart { out.append("sound \(a.id): joinStart, but no sound of \(a.file) on its lane ends where it starts with joinEnd") }
            if a.joinEnd != b.joinEnd { out.append("sound \(a.id): joinEnd, but no sound of \(a.file) on its lane starts where it ends with joinStart") }
        }
        return out
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
