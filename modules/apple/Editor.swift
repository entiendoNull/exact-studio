// One open recording: its edits (edits.json beside the capture), the player
// the preview shows, and the selection the timeline and the inspector share.
// The module keeps one Editor per recording; the preview and the timeline
// views attach to it and are told when it changes.
#if os(macOS)
import AppKit
import AVFoundation

final class Editor {
    let id: String
    private(set) var meta: RecordingMeta
    let cursor: [Point]
    let asset: AVURLAsset
    let player = AVPlayer()
    private(set) var edits: Edits
    private(set) var look = Look()
    private(set) var map: TimeMap
    /// The selected segment's id; empty for none.
    private(set) var selected = ""
    /// Why the last edit was refused; cleared by the next one that lands.
    private(set) var problem = ""
    private var listeners: [ObjectIdentifier: () -> Void] = [:]
    /// Said when the selection or a segment changes: the module turns it into a watched topic.
    var onChange: () -> Void = {}

    var folder: URL { Library.recordings.appendingPathComponent(id) }
    var duration: Double { min(meta.duration, asset.duration.seconds.isFinite ? asset.duration.seconds : meta.duration) }

    init?(id: String) {
        guard let meta = Library.meta(id) else { return nil }
        self.id = id
        self.meta = meta
        cursor = Library.cursor(id)
        asset = AVURLAsset(url: Library.recordings.appendingPathComponent(id).appendingPathComponent("capture.mov"))
        let file = Library.recordings.appendingPathComponent(id).appendingPathComponent("edits.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Edits.self, from: data) {
            edits = saved
        } else {
            // A first open: the clicks become zooms, ready to adjust.
            edits = Edits(segments: Edits.autoZooms(meta.clicks, duration: meta.duration))
        }
        map = TimeMap(duration: meta.duration, edits: edits)
        player.actionAtItemEnd = .pause
        rebuild(keepTime: false)
    }

    func listen(_ owner: AnyObject, _ body: @escaping () -> Void) { listeners[ObjectIdentifier(owner)] = body }
    func unlisten(_ owner: AnyObject) { listeners[ObjectIdentifier(owner)] = nil }
    private func notify() { listeners.values.forEach { $0() }; onChange() }

    // MARK: Time

    /// The playhead in source seconds.
    var playhead: Double { map.source(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }

    func seek(source t: Double) {
        let out = map.output(min(max(t, 0), duration))
        player.seek(to: CMTime(seconds: out, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); return }
        if let item = player.currentItem, item.currentTime().seconds >= map.outputDuration - 0.05 { player.seek(to: .zero) }
        player.play()
    }

    // MARK: Building

    func setLook(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        rebuild(keepTime: true)
    }

    func setCrop(_ crop: UnitRect) {
        meta.crop = crop
        rebuild(keepTime: true)
    }

    private func rebuild(keepTime: Bool) {
        let at = keepTime ? playhead : 0
        let playing = player.rate != 0
        guard let (mix, composition, map) = try? Composition.make(asset: asset, meta: meta, cursor: cursor, look: look, edits: edits) else { return }
        self.map = map
        let item = AVPlayerItem(asset: mix)
        item.videoComposition = composition
        player.replaceCurrentItem(with: item)
        seek(source: at)
        if playing { player.play() }
    }

    /// The composition for export, at this editor's edits and the look asked for.
    func exportable(look: Look) throws -> (AVAsset, AVMutableVideoComposition) {
        let (mix, composition, _) = try Composition.make(asset: asset, meta: meta, cursor: cursor, look: look, edits: edits)
        return (mix, composition)
    }

    // MARK: Editing

    private func save() {
        try? JSONEncoder().encode(edits).write(to: folder.appendingPathComponent("edits.json"))
    }

    /// Land `next` if every segment in it may sit where it is; else keep the
    /// edits as they were and say why.
    @discardableResult
    private func apply(_ next: Edits) -> Bool {
        if let why = next.segments.lazy.compactMap({ next.conflict($0) }).first {
            problem = why
            listeners.values.forEach { $0() }
            onChange()
            return false
        }
        problem = ""
        guard next != edits else { notify(); return true }
        edits = next
        save()
        rebuild(keepTime: true)
        notify()
        return true
    }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        problem = ""
        notify()
    }

    var selectedSegment: Segment? { edits.segments.first { $0.id == selected } }

    /// A new segment of `choice` at the playhead, on the first lane with room, selected.
    /// `choice` is a kind, or "zoom-in", "zoom-out", "slow" or "fast".
    func add(_ choice: String) {
        var s = Segment(id: "s\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)", kind: choice, start: 0, end: 0)
        switch choice {
        case "zoom-in": s.kind = "zoom"; s.level = 2
        case "zoom-out": s.kind = "zoom"; s.level = 0.7
        case "slow": s.kind = "speed"; s.rate = 0.5
        case "fast": s.kind = "speed"; s.rate = 2
        default: break
        }
        guard Segment.kinds.contains(s.kind) else { return }
        let length: Double = s.kind == "cut" ? 1 : s.kind == "zoom" ? 3 : 2
        let t = min(playhead, max(0, duration - 0.3))
        // Same-group segments bound it: it fills the room between them, up to its length.
        let before = edits.segments.filter { $0.group == s.group && $0.end <= t + 0.0001 }.map(\.end).max() ?? 0
        let after = edits.segments.filter { $0.group == s.group && $0.start >= t - 0.0001 }.map(\.start).min() ?? duration
        if edits.segments.contains(where: { $0.group == s.group && $0.start < t && $0.end > t }) || after - max(before, t) < 0.3 {
            problem = "There’s already \(Segment.article(s.kind)) at the playhead. Move the playhead to a free spot."
            notify()
            return
        }
        s.start = max(before, t)
        s.end = min(after, s.start + length)
        if s.kind != "cut" {
            var lane = 0
            while edits.segments.contains(where: { $0.kind != "cut" && $0.lane == lane && $0.overlaps(s) }) { lane += 1 }
            s.lane = lane
        }
        var next = edits
        next.segments.append(s)
        if apply(next) { select(s.id) }
    }

    /// Set the selected segment's value: a zoom's level, a speed's rate, or (for
    /// a visual effect) another visual kind.
    func setValue(number: Double?, kind: String?) {
        guard var s = selectedSegment else { return }
        if s.kind == "zoom", let n = number { s.level = n }
        if s.kind == "speed", let n = number { s.rate = n }
        if Segment.visual.contains(s.kind), let k = kind, Segment.visual.contains(k) { s.kind = k }
        replace(s)
    }

    private func replace(_ s: Segment) {
        var next = edits
        next.segments = next.segments.map { $0.id == s.id ? s : $0 }
        apply(next)
    }

    func deleteSelected() {
        guard !selected.isEmpty else { return }
        var next = edits
        next.segments.removeAll { $0.id == selected }
        apply(next)
        select("")
    }

    /// Split the selected segment in two at the playhead.
    func splitSelected() {
        let t = playhead
        guard let s = selectedSegment, t > s.start + 0.1, t < s.end - 0.1 else { return }
        var left = s, right = s
        left.end = t
        right.id = s.id + "b"
        right.start = t
        var next = edits
        next.segments = next.segments.map { $0.id == s.id ? left : $0 } + [right]
        apply(next)
    }

    func autoZoom() {
        var next = edits
        next.segments.removeAll { $0.kind == "zoom" }
        // The new zooms take the first lane where none of them collides.
        var zooms = Edits.autoZooms(meta.clicks, duration: meta.duration)
        var lane = 0
        while zooms.contains(where: { z in next.segments.contains { $0.kind != "cut" && $0.lane == lane && $0.overlaps(z) } }) { lane += 1 }
        zooms = zooms.map { var z = $0; z.lane = lane; return z }
        next.segments += zooms
        apply(next)
        select("")
    }

    func clearAll() {
        apply(Edits())
        select("")
    }

    // MARK: Dragging (the timeline's)

    private var dragOrigin: Edits?

    /// Move or resize a segment while dragging: drawn at once, checked on drop.
    func drag(_ id: String, start: Double, end: Double, lane: Int) {
        if dragOrigin == nil { dragOrigin = edits }
        let s = max(0, min(start, duration - 0.1)), e = min(duration, max(end, s + 0.1))
        edits.segments = edits.segments.map {
            guard $0.id == id else { return $0 }
            var m = $0
            m.start = s; m.end = e
            if m.kind != "cut" { m.lane = max(0, lane) }
            return m
        }
        listeners.values.forEach { $0() }
    }

    /// The drop: keep the move if it fits, else put the segment back.
    func endDrag() {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        let moved = edits
        edits = origin
        if !apply(compacted(moved)) { listeners.values.forEach { $0() } }
    }

    /// Lanes renumbered so none is left empty between others.
    private func compacted(_ e: Edits) -> Edits {
        let used = Set(e.segments.filter { $0.kind != "cut" }.map(\.lane)).sorted()
        var next = e
        next.segments = e.segments.map { var s = $0; if s.kind != "cut", let i = used.firstIndex(of: s.lane) { s.lane = i }; return s }
        return next
    }

    /// What the inspector shows.
    var selection: [String: Any] {
        guard let s = selectedSegment else {
            return ["id": "", "kind": "", "level": 0, "rate": 0, "start": 0, "end": 0, "problem": problem]
        }
        return ["id": s.id, "kind": s.kind, "level": s.level ?? 0, "rate": s.rate ?? 0, "start": s.start, "end": s.end, "problem": problem]
    }

    var summary: [String: Any] {
        ["cuts": edits.cuts.count, "effects": edits.segments.count - edits.cuts.count, "lanes": edits.lanes,
         "length": map.outputDuration, "source": duration]
    }
}

extension Segment {
    static func article(_ kind: String) -> String {
        ["cut": "a cut", "zoom": "a zoom", "speed": "a speed change", "spotlight": "a spotlight",
         "highlight": "a cursor highlight", "blur": "a blur", "mono": "a black-and-white effect"][kind] ?? "an effect"
    }
}
#endif
