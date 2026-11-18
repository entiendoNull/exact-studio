// @ref LLP 0002#what-may-overlap
#if os(macOS)
import Foundation

struct ItemRef: Hashable {
    var kind: String
    var id: String
    var image: String? = nil

    var key: String { [kind, image ?? "", id].joined(separator: "/") }
    static func of(_ s: Segment) -> ItemRef { ItemRef(kind: s.kind, id: s.id) }
    static func move(_ m: Move, image: String? = nil) -> ItemRef { ItemRef(kind: image == nil ? "move" : "image-move", id: m.id, image: image) }
    static func sound(_ s: Sound) -> ItemRef { ItemRef(kind: "sound", id: s.id) }
    static func effect(_ e: Segment, image: String) -> ItemRef { ItemRef(kind: "image-effect", id: e.id, image: image) }
}

struct Conflict: Equatable {
    var rule: String
    var item: ItemRef?
    var other: ItemRef?
    var line1: String
    var line2: String

    init(rule: String, item: ItemRef?, other: ItemRef? = nil, _ line1: String, _ line2: String = "") {
        self.rule = rule; self.item = item; self.other = other; self.line1 = line1; self.line2 = line2
    }

    static func plain(_ why: String) -> Conflict { Conflict(rule: "", item: nil, why) }

    var text: String { line2.isEmpty ? line1 : line1 + " " + line2 }
    var menuText: String { line2.isEmpty ? line1 : line1 + "\n" + line2 }
    var key: String { rule + "|" + [item, other].compactMap { $0?.key }.sorted().joined(separator: "|") }
    func involves(_ ref: ItemRef) -> Bool { item == ref || other == ref }
}

enum Rules {
    static let all: [(id: String, line1: String)] = [
        ("one-zoom", "One zoom at a time."), ("one-speed", "One speed at a time."), ("one-3d", "One 3D turn at once."),
        ("one-spotlight", "One spotlight at a time."), ("one-highlight", "One highlight at a time."),
        ("one-blur", "One blur at a time."), ("one-mono", "One black & white at once."),
        ("no-zoom-in-orbit", "No zoom during an orbit."), ("move-after-move", "One move at a time."),
        ("lane-taken", "That lane is taken."), ("image-one-each", "One of each per image."),
        ("image-inside", "Keep it inside the image."), ("image-effect-kind", "No such image effect."),
        ("text-one-each", "One of each per text."), ("text-inside", "Keep it inside the text."), ("text-effect-kind", "No such text effect."),
        ("room-at-playhead", "No room at the playhead."), ("min-length", "Too short."), ("keep-a-part", "Keep one clip part."),
    ]
    static func line1(_ id: String) -> String { all.first { $0.id == id }?.line1 ?? "" }

    static func group(_ kind: String) -> String {
        ["zoom": "one-zoom", "speed": "one-speed", "3d": "one-3d", "spotlight": "one-spotlight", "highlight": "one-highlight",
         "blur": "one-blur", "mono": "one-mono"][kind] ?? "one-\(kind)"
    }

    static func clock(_ t: Double, up: Bool) -> String {
        let tenths = up ? (max(t, 0) * 10 - 0.0005).rounded(.up) : (max(t, 0) * 10 + 0.0005).rounded(.down)
        let whole = Int(tenths)
        return String(format: "%d:%02d.%d", whole / 600, (whole / 10) % 60, whole % 10)
    }

    static func around(_ name: String, _ start: Double, _ other: (start: Double, end: Double)) -> String {
        if start >= other.start - 0.0001 {
            let t = clock(other.end, up: true)
            return "\(name) runs to \(t). Start it at \(t) or later."
        }
        let t = clock(other.start, up: false)
        return "\(name) starts at \(t). End it by \(t)."
    }

    static func overlap(_ rule: String, _ s: Segment, _ o: Segment) -> Conflict {
        Conflict(rule: rule, item: .of(s), other: .of(o), line1(rule), around(o.label, s.start, (o.start, o.end)))
    }

    static func laneTaken(item: ItemRef, other: ItemRef, name: String, row: Bool = false) -> Conflict {
        let what = row ? "row" : "lane"
        return Conflict(rule: "lane-taken", item: item, other: other, row ? "That row is taken." : line1("lane-taken"),
                        "\(name) is on this \(what) then. Put it on another \(what).")
    }

    // @ref LLP 0002#what-may-overlap — an earlier landing inside a later travel made the later move jump
    static func moves(_ m: Move, in all: [Move], image: String? = nil) -> [Conflict] {
        var out: [Conflict] = []
        let others = all.filter { $0.id != m.id }
        if let before = others.filter({ $0.t <= m.t + 0.0001 }).max(by: { $0.t < $1.t }), m.t - m.duration < before.t - 0.001 {
            out.append(Conflict(rule: "move-after-move", item: .move(m, image: image), other: .move(before, image: image), line1("move-after-move"),
                                "The move before lands at \(clock(before.t, up: true)). Land this one at \(clock(before.t + m.duration, up: true)) or later."))
        }
        if let after = others.filter({ $0.t > m.t + 0.0001 }).min(by: { $0.t < $1.t }), after.t - after.duration < m.t - 0.001 {
            let t = clock(after.t - after.duration, up: false)
            out.append(Conflict(rule: "move-after-move", item: .move(m, image: image), other: .move(after, image: image), line1("move-after-move"),
                                "The next move starts at \(t). Land this one by \(t)."))
        }
        return out
    }

    static func minLength(_ item: ItemRef?, duration: Double) -> Conflict {
        Conflict(rule: "min-length", item: item, line1("min-length"), "An item lasts at least 0.1 s, inside 0:00–\(clock(duration, up: false)).")
    }

    static let keepAPart = Conflict(rule: "keep-a-part", item: nil, line1("keep-a-part"), "The video needs at least one kept part.")

    static func noRoom(_ kind: String, at t: Double, _ o: Segment) -> Conflict {
        let line2 = o.start <= t + 0.0001
            ? "\(o.label) runs here until \(clock(o.end, up: true)). Move the playhead past it."
            : "\(o.label) starts at \(clock(o.start, up: false)). Move the playhead earlier."
        return Conflict(rule: "room-at-playhead", item: nil, other: .of(o), line1(group(kind)), line2)
    }
}

extension Segment {
    var label: String {
        func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        switch kind {
        case "zoom": let l = level ?? 2; return l < 1 ? "Zoom out \(trim(l))×" : "Zoom in \(trim(l))×"
        case "speed": let r = rate ?? 1; return r < 1 ? "Slow \(trim(r))×" : "Fast \(trim(r))×"
        case "spotlight": return "Spotlight"
        case "highlight": return "Cursor highlight"
        case "blur": return "Blur · " + Segment.reachWords(scope)
        case "mono": return "Black & white · " + Segment.reachWords(scope)
        case "3d": return style == "orbit" ? "3D orbit" : "3D turn"
        case "mask": return style == "pixels" ? "Mask · pixels" : style == "solid" ? "Mask · solid" : "Mask · blur"
        case "text": return "“\(text ?? "")”"
        case "image": return URL(fileURLWithPath: file ?? "").lastPathComponent
        default: return Segment.imageEffects.contains(kind) ? Segment.imageNoun(kind).capitalized : "Effect"
        }
    }

    static func reachWords(_ scope: String?) -> String {
        switch scope {
        case "background": return "background"
        case "scene": return "video, background"
        case "frame": return "whole frame"
        case "all": return "everything"
        default: return "video"
        }
    }

    static func imageNoun(_ kind: String) -> String { kind == "mono" ? "black & white" : kind }

    var isOrbit: Bool { kind == "3d" && style == "orbit" }
}

extension Edits {
    func conflicts(of s: Segment) -> [Conflict] {
        var out: [Conflict] = []
        for o in segments where o.id != s.id && o.overlaps(s) {
            if o.group == s.group { out.append(Rules.overlap(Rules.group(s.kind), s, o)) }
            // @ref LLP 0002#what-may-overlap — half way through an orbit the screen faces away
            else if (s.kind == "zoom" && o.isOrbit) || (s.isOrbit && o.kind == "zoom") { out.append(Rules.overlap("no-zoom-in-orbit", s, o)) }
            else if o.lane == s.lane, o.space == s.space { out.append(Rules.laneTaken(item: .of(s), other: .of(o), name: o.label)) }
        }
        if s.isOverlay { out += Edits.conflicts(in: s) }
        return out
    }

    func conflict(_ s: Segment) -> Conflict? { conflicts(of: s).first }

    func conflict(_ s: Sound, map: TimeMap) -> Conflict? {
        let a = s.playing(map)
        for o in sounds where o.id != s.id && o.lane == s.lane {
            let b = o.playing(map)
            if a.start < b.end - 0.0001 && b.start < a.end - 0.0001 {
                return Rules.laneTaken(item: .sound(s), other: .sound(o), name: URL(fileURLWithPath: o.file).lastPathComponent)
            }
        }
        return nil
    }

    static func conflicts(in image: Segment) -> [Conflict] {
        let fx = image.effects ?? [], name = image.label, noun = image.kind == "text" ? "text" : "image"
        let kinds = Segment.ownEffects(image.kind), oneEach = "\(noun)-one-each", inside = "\(noun)-inside", kindRule = "\(noun)-effect-kind"
        let takes = "A\(noun == "image" ? "n" : "") \(noun) takes \(kinds.dropLast().joined(separator: ", ")) or \(kinds.last ?? "")."
        let span = "\(name) shows \(Rules.clock(image.start, up: true))–\(Rules.clock(image.end, up: false))."
        var out: [Conflict] = [], seen = Set<String>()
        func add(_ c: Conflict) { if seen.insert(c.key).inserted { out.append(c) } }
        for e in fx.sorted(by: { $0.start > $1.start }) {
            let me = ItemRef.effect(e, image: image.id)
            if !kinds.contains(e.kind) {
                add(Conflict(rule: kindRule, item: me, Rules.line1(kindRule), takes))
                continue
            }
            if e.start < image.start - 0.001 || e.end > image.end + 0.001 {
                add(Conflict(rule: inside, item: me, Rules.line1(inside), "\(span) Start and end it there."))
            }
            for o in fx where o.id != e.id && o.overlaps(e) {
                if o.kind == e.kind {
                    add(Conflict(rule: oneEach, item: me, other: .effect(o, image: image.id), Rules.line1(oneEach),
                                 Rules.around("Its \(Segment.imageNoun(o.kind))", e.start, (o.start, o.end))))
                } else if o.lane == e.lane {
                    add(Rules.laneTaken(item: me, other: .effect(o, image: image.id), name: "Its \(Segment.imageNoun(o.kind))", row: true))
                }
            }
        }
        let moves = image.moves ?? []
        for m in moves.sorted(by: { $0.t > $1.t }) {
            if m.t < image.start - 0.001 || m.t > image.end + 0.001 {
                add(Conflict(rule: inside, item: .move(m, image: image.id), Rules.line1(inside), "\(span) Land the move there."))
            }
            Rules.moves(m, in: moves, image: image.id).forEach(add)
        }
        return out
    }

    static func conflict(in image: Segment) -> Conflict? { conflicts(in: image).first }

    func conflicts(ofMove m: Move) -> [Conflict] { Rules.moves(m, in: moves) }

    func conflicts(of ref: ItemRef, map: TimeMap) -> [Conflict] {
        switch ref.kind {
        case "move": return moves.first { $0.id == ref.id }.map(conflicts(ofMove:)) ?? []
        case "sound": return sounds.first { $0.id == ref.id }.flatMap { conflict($0, map: map) }.map { [$0] } ?? []
        case "image-move", "image-effect":
            return segments.first { $0.id == ref.image && $0.kind == "image" }.map { Edits.conflicts(in: $0).filter { $0.item == ref } } ?? []
        default: return segments.first { $0.id == ref.id }.map(conflicts(of:)) ?? []
        }
    }

    func conflicts(map: TimeMap) -> [Conflict] {
        var out: [Conflict] = [], seen = Set<String>()
        func add(_ c: Conflict) { if seen.insert(c.key).inserted { out.append(c) } }
        for s in segments.sorted(by: { $0.start > $1.start }) { conflicts(of: s).forEach(add) }
        for m in moves.sorted(by: { $0.t > $1.t }) { conflicts(ofMove: m).forEach(add) }
        for s in sounds.sorted(by: { $0.start > $1.start }) { conflict(s, map: map).map(add) }
        return out
    }
}
#endif
