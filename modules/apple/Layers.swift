// @ref LLP 0005#layers — the text and image rows are the front-to-back stack, with the video among them
#if os(macOS)
import Foundation

/// One row of the stack: a text lane, an image lane, or the video.
struct LayerRow: Hashable {
    var kind: String
    var lane: Int

    static let video = LayerRow(kind: "video", lane: 0)
    var key: String { kind == "video" ? "video" : "\(kind):\(lane)" }
    var isVideo: Bool { kind == "video" }

    init(kind: String, lane: Int) { self.kind = kind; self.lane = lane }

    init?(key: String) {
        if key == "video" { self = .video; return }
        let parts = key.split(separator: ":")
        guard parts.count == 2, ["text", "image"].contains(String(parts[0])), let lane = Int(parts[1]), lane >= 0 else { return nil }
        self.init(kind: String(parts[0]), lane: lane)
    }
}

extension Segment {
    var row: LayerRow { LayerRow(kind: kind, lane: lane) }
}

extension Edits {
    /// The rows front to back, every lane in use placed: the file's `layers` when it has them, with any lane it
    /// lacks put where a new one goes; else the order the items drew in before rows were the stack.
    /// `adding` places more rows as new ones go, in front of the video: a target that is shown, not stored.
    func stack(adding extra: [LayerRow] = []) -> [LayerRow] {
        let used = overlayRows
        var out: [LayerRow]
        if (layers ?? []).isEmpty {
            out = Edits.derivedStack(segments.filter(\.isOverlay)).rows
        } else {
            var seen = Set<LayerRow>()
            out = (layers ?? []).compactMap(LayerRow.init(key:)).filter { ($0.isVideo || used.contains($0)) && seen.insert($0).inserted }
            if !out.contains(.video) { out.append(.video) }
            for row in used.sorted(by: { ($0.kind, $0.lane) < ($1.kind, $1.lane) }) where !out.contains(row) {
                let behind = segments.contains { $0.isOverlay && $0.row == row && $0.isBehind }
                Edits.place(row, behind: behind, in: &out)
            }
        }
        for row in extra where !out.contains(row) { Edits.place(row, behind: false, in: &out) }
        return out
    }

    private var overlayRows: Set<LayerRow> { Set(segments.filter(\.isOverlay).map(\.row)) }

    /// Where a new row goes: a text at the very front; an image behind the images in front, else just over the
    /// video; anything behind the video just under it.
    static func place(_ row: LayerRow, behind: Bool, in stack: inout [LayerRow]) {
        let video = stack.firstIndex(of: .video) ?? stack.count
        if behind { stack.insert(row, at: min(video + 1, stack.count)); return }
        if row.kind == "text" { stack.insert(row, at: 0); return }
        let lastImage = stack[..<video].lastIndex { $0.kind == "image" }
        stack.insert(row, at: lastImage.map { $0 + 1 } ?? video)
    }

    /// The rows the items drew in before rows were the stack (by `order`, image lanes, the list), each item on a
    /// row in front of every row it drew over, so the picture stays the same.
    static func derivedStack(_ overlays: [Segment]) -> (rows: [LayerRow], lanes: [String: Int]) {
        var front: [LayerRow] = [], lanes: [String: Int] = [:], next = ["text": 0, "image": 0]
        var stacks: [[LayerRow]] = []
        for behind in [false, true] {
            var rows: [(kind: String, items: [Segment])] = []
            for item in depth(overlays.filter { $0.isBehind == behind }) {
                let over = rows.indices.last { rows[$0].items.contains { $0.overlaps(item) } } ?? -1
                if let r = rows.indices.first(where: { $0 > over && rows[$0].kind == item.kind }) { rows[r].items.append(item) }
                else { rows.append((item.kind, [item])) }
            }
            var named: [LayerRow] = []
            for r in rows.reversed() {
                let row = LayerRow(kind: r.kind, lane: next[r.kind, default: 0])
                next[r.kind, default: 0] += 1
                r.items.forEach { lanes[$0.id] = row.lane }
                named.append(row)
            }
            stacks.append(named)
        }
        front = stacks[0] + [.video] + stacks[1]
        return (front, lanes)
    }

    /// The stack made true: `layers` written front to back, each lane numbered by its place (0 the front-most of its
    /// kind), every item's `layer` the side of the video its row is on. `itemWins` moves an item whose `layer` says
    /// the other side to a row there (a file an agent wrote); else the row wins (a row dragged past the video).
    mutating func settleLayers(itemWins: Bool = false) {
        if (layers ?? []).isEmpty {
            let derived = Edits.derivedStack(segments.filter(\.isOverlay))
            segments = segments.map { s in
                guard s.isOverlay, let lane = derived.lanes[s.id] else { return s }
                var m = s; m.lane = lane; return m
            }
            layers = derived.rows.map(\.key)
        } else if itemWins {
            var rows = stack()
            for i in segments.indices where segments[i].isOverlay {
                let video = rows.firstIndex(of: .video)!
                let at = rows.firstIndex(of: segments[i].row)!
                guard let said = segments[i].layer, Segment.layers.contains(said), (at > video) != (said == "behind") else { continue }
                relocate(i, behind: said == "behind", in: &rows)
            }
            layers = rows.map(\.key)
        }
        var rows = stack()
        let video = rows.firstIndex(of: .video)!
        var number: [LayerRow: Int] = [:], count = ["text": 0, "image": 0]
        for row in rows where !row.isVideo {
            number[row] = count[row.kind, default: 0]
            count[row.kind, default: 0] += 1
        }
        segments = segments.map { s in
            guard s.isOverlay else { return s }
            var m = s
            let side = rows.firstIndex(of: s.row).map { $0 > video } ?? s.isBehind
            m.layer = side ? "behind" : s.layer.flatMap { Segment.layers.contains($0) ? nil : $0 }
            m.lane = number[s.row] ?? s.lane
            m.order = nil
            return m
        }
        rows = rows.map { $0.isVideo ? $0 : LayerRow(kind: $0.kind, lane: number[$0]!) }
        layers = rows.count > 1 ? rows.map(\.key) : nil
        textLanes = count["text"] ?? 0
        imageLanes = count["image"] ?? 0
    }

    /// Put item `i` on its kind's row next to the video on that side when it has room there, else on a new row there.
    fileprivate mutating func relocate(_ i: Int, behind: Bool, in rows: inout [LayerRow]) {
        let video = rows.firstIndex(of: .video)!
        let next = behind ? video + 1 : video - 1
        var item = segments[i]
        item.layer = behind ? "behind" : nil
        if rows.indices.contains(next), rows[next].kind == item.kind,
           !segments.contains(where: { $0.id != item.id && $0.isOverlay && $0.row == rows[next] && $0.overlaps(item) }) {
            item.lane = rows[next].lane
        } else {
            item.lane = (segments.filter { $0.kind == item.kind }.map(\.lane).max() ?? -1) + 1
            rows.insert(item.row, at: behind ? video + 1 : video)
        }
        segments[i] = item
    }

    /// The texts and images showing at `t`, back to front: by their rows, the back row first.
    // @ref LLP 0005#layers — the rows are the draw order
    func overlays(at t: Double, behind: Bool = false) -> [Segment] {
        let showing = segments.filter { $0.isOverlay && $0.isBehind == behind && t >= $0.start && t < $0.end }
        guard !showing.isEmpty else { return [] }
        if (layers ?? []).isEmpty { return Edits.depth(showing) }
        let rank = Dictionary(uniqueKeysWithValues: stack().enumerated().map { ($1, $0) })
        return showing.enumerated().sorted { (-(rank[$0.element.row] ?? 0), $0.offset) < (-(rank[$1.element.row] ?? 0), $1.offset) }.map(\.element)
    }

    /// The old draw order, before rows were the stack: images by `order` then lane (0 in front), the texts over
    /// them by `order` then their place in the list. Old files are read through it once.
    static func depth(_ items: [Segment]) -> [Segment] {
        let all = Array(items.enumerated())
        let images = all.filter { $0.element.kind == "image" }
            .sorted { ($0.element.order ?? 0, -$0.element.lane, $0.offset) < ($1.element.order ?? 0, -$1.element.lane, $1.offset) }
        let texts = all.filter { $0.element.kind == "text" }
            .sorted { ($0.element.order ?? 0, $0.offset) < ($1.element.order ?? 0, $1.offset) }
        return (images + texts).map(\.element)
    }

    // MARK: Moving rows

    /// The stack with `row` moved to `index` (counted before it is taken out). Past the video, its items change side.
    func movingRow(_ row: LayerRow, to index: Int) -> Edits? {
        let base = settled
        var rows = base.stack()
        guard !row.isVideo, let from = rows.firstIndex(of: row) else { return nil }
        let to = index > from ? index - 1 : index
        guard to != from, to >= 0, to < rows.count else { return nil }
        rows.remove(at: from)
        rows.insert(row, at: to)
        var next = base
        next.layers = rows.map(\.key)
        next.settleLayers()
        return next == self ? nil : next
    }

    /// The row one step up (-1) or down (1) the stack: past the video too.
    func steppingRow(_ row: LayerRow, by step: Int) -> Edits? {
        guard let from = settled.stack().firstIndex(of: row) else { return nil }
        return movingRow(row, to: step < 0 ? from - 1 : from + 2)
    }
}

extension Edits {
    /// The same edit with its stack written out, so rows and lanes agree.
    var settled: Edits {
        guard (layers ?? []).isEmpty, segments.contains(where: \.isOverlay) else { return self }
        var e = self
        e.settleLayers()
        return e
    }
}

// MARK: Arranging one item
// @ref LLP 0002#depth — arranging moves the item among the rows that show at its time; the rows are the stack

extension Edits {
    static let arrangeSteps: [(step: String, name: String)] = [
        ("forward", "Bring Forward"), ("backward", "Send Backward"), ("front", "Bring to Front"), ("back", "Send to Back"),
        ("behind", "Send Behind Video"), ("in-front", "Bring In Front of Video"),
    ]

    static func arrangeName(_ step: String) -> String? { arrangeSteps.first { $0.step == step }?.name }

    /// The rows on the item's side of the video that hold something showing with it, front to back, and its own.
    fileprivate func meeting(_ s: Segment) -> (rows: [LayerRow], side: Range<Int>, own: Int, met: [Int]) {
        let rows = stack(), video = rows.firstIndex(of: .video)!
        let side = s.isBehind ? (video + 1)..<rows.count : 0..<video
        let own = rows.firstIndex(of: s.row) ?? video
        let met = side.filter { i in i != own && segments.contains { $0.id != s.id && $0.isOverlay && $0.row == rows[i] && $0.overlaps(s) } }
        return (rows, side, own, met)
    }

    func arrangeProblem(_ id: String, _ step: String) -> String? {
        let segments = settled.segments
        guard let s = segments.first(where: { $0.id == id }), s.isOverlay else { return "Only a text or an image has a depth." }
        guard Edits.arrangeName(step) != nil else { return "No arrange step \(step)." }
        let place = s.isBehind ? "behind the video" : "in front of the video"
        switch step {
        case "behind": return s.isBehind ? "It is already behind the video." : nil
        case "in-front": return s.isBehind ? nil : "It is already in front of the video."
        default:
            let m = settled.meeting(s)
            if m.met.isEmpty { return "No other text or image \(place) shows at the same time." }
            let up = step == "forward" || step == "front"
            if up, !m.met.contains(where: { $0 < m.own }) { return "It is already in front of the others \(place)." }
            if !up, !m.met.contains(where: { $0 > m.own }) { return "It is already behind the others \(place)." }
            return nil
        }
    }

    func arranged(_ id: String, _ step: String) -> Edits? {
        let base = settled
        guard let s = base.segments.first(where: { $0.id == id }), arrangeProblem(id, step) == nil else { return nil }
        var next = base
        let run = Joins.run(s, in: base.segments).map(\.id)
        switch step {
        case "behind", "in-front":
            var rows = next.stack()
            for i in next.segments.indices where run.contains(next.segments[i].id) {
                next.relocate(i, behind: step == "behind", in: &rows)
            }
            next.layers = rows.map(\.key)
        default:
            let m = base.meeting(s)
            let target: Int
            switch step {
            case "forward": target = m.met.filter { $0 < m.own }.max()!
            case "backward": target = m.met.filter { $0 > m.own }.min()! + 1
            case "front": target = m.side.lowerBound
            default: target = m.side.upperBound
            }
            var rows = m.rows
            let lane = (next.segments.filter { $0.kind == s.kind }.map(\.lane).max() ?? -1) + 1
            let row = LayerRow(kind: s.kind, lane: lane)
            rows.insert(row, at: target)
            for i in next.segments.indices where run.contains(next.segments[i].id) { next.segments[i].lane = lane }
            next.layers = rows.map(\.key)
        }
        next.settleLayers()
        return next == self ? nil : next
    }
}
#endif
