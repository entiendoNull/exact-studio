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
    /// The selected segment, by track and id; empty for none.
    private(set) var selected: (track: String, id: String) = ("", "")
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
            edits = Edits()
            edits.zooms = Edits.autoZooms(meta.clicks, duration: meta.duration)
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

    /// Apply a change to the edits; rebuild the playback only when cuts or speed moved,
    /// since zooms and effects are read per frame from the composition's captured edits.
    func change(_ body: (inout Edits) -> Void) {
        var next = edits
        body(&next)
        guard next != edits else { return }
        edits = next
        save()
        rebuild(keepTime: true)
        notify()
    }

    func select(_ track: String, _ id: String) {
        guard selected != (track, id) else { return }
        selected = (track, id)
        notify()
    }

    var selectedSegment: Segment? {
        guard !selected.track.isEmpty else { return nil }
        return edits[selected.track].first { $0.id == selected.id }
    }

    /// A new segment on `track` at the playhead, selected.
    func add(_ track: String) {
        let t = playhead
        let length: Double = track == "cut" ? 1 : track == "zoom" ? 3 : 2
        var start = min(t, max(0, duration - length))
        let end = min(duration, start + length)
        start = max(0, end - length)
        var s = Segment(id: "\(track.prefix(1))\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)", start: start, end: end)
        switch track {
        case "zoom": s.level = 2
        case "speed": s.rate = 2
        case "effect": s.kind = "spotlight"
        default: break
        }
        let new = s
        change { $0[track].append(new) }
        select(track, new.id)
    }

    /// Set the selected segment's value: a zoom's level, a speed's rate, an effect's kind.
    func setValue(number: Double?, kind: String?) {
        let (track, id) = selected
        change { e in
            e[track] = e[track].map { s in
                guard s.id == id else { return s }
                var s = s
                if track == "zoom", let n = number { s.level = n }
                if track == "speed", let n = number { s.rate = n }
                if track == "effect", let k = kind { s.kind = k }
                return s
            }
        }
    }

    func deleteSelected() {
        let (track, id) = selected
        guard !track.isEmpty else { return }
        change { $0[track].removeAll { $0.id == id } }
        select("", "")
    }

    /// Cut out what lies between the playhead and the nearest cut boundary is too fiddly;
    /// a split instead trims the selected segment at the playhead into two.
    func splitSelected() {
        let (track, id) = selected, t = playhead
        guard let s = selectedSegment, t > s.start + 0.1, t < s.end - 0.1 else { return }
        var right = s
        right.id = s.id + "b"
        right.start = t
        change { e in
            e[track] = e[track].map { $0.id == id ? Segment(id: s.id, start: s.start, end: t, level: s.level, rate: s.rate, kind: s.kind) : $0 } + [right]
        }
    }

    func autoZoom() {
        change { $0.zooms = Edits.autoZooms(meta.clicks, duration: meta.duration) }
        select("", "")
    }

    func clearAll() {
        change { $0 = Edits() }
        select("", "")
    }

    /// Move or resize a segment (the timeline's drag), kept inside the recording.
    func set(_ track: String, _ id: String, start: Double, end: Double, commit: Bool) {
        let s = max(0, min(start, duration - 0.1)), e = min(duration, max(end, s + 0.1))
        if commit {
            change { ed in ed[track] = ed[track].map { $0.id == id ? Segment(id: $0.id, start: s, end: e, level: $0.level, rate: $0.rate, kind: $0.kind) : $0 } }
        } else {
            // While dragging: the timeline draws it; the playback waits for the drop.
            edits[track] = edits[track].map { $0.id == id ? Segment(id: $0.id, start: s, end: e, level: $0.level, rate: $0.rate, kind: $0.kind) : $0 }
            listeners.values.forEach { $0() }
        }
    }

    /// The edits as dropped mid-drag need the playback rebuilt once: `set(commit: true)` with the same
    /// values would compare equal, so a drop forces it.
    func commitDrag() {
        save()
        rebuild(keepTime: true)
        notify()
    }

    /// What the inspector shows.
    var selection: [String: Any] {
        guard let s = selectedSegment else { return ["track": "", "id": "", "level": 0, "rate": 0, "kind": "", "start": 0, "end": 0] }
        return ["track": selected.track, "id": s.id, "level": s.level ?? 0, "rate": s.rate ?? 0, "kind": s.kind ?? "", "start": s.start, "end": s.end]
    }

    var summary: [String: Any] {
        ["cuts": edits.cuts.count, "zooms": edits.zooms.count, "speeds": edits.speeds.count, "effects": edits.effects.count,
         "length": map.outputDuration, "source": duration]
    }
}
#endif
