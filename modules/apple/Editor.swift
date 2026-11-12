// One open recording: its edits (edits.json beside the capture), the player
// the preview shows, and the selection the timeline, the preview and the
// inspector share. The module keeps one Editor per recording; the views
// attach to it and are told when it changes.
//
// A change to what is drawn (the look, effects, texts, moves) swaps the
// compositor's framing and redraws; a change to timing (the clip's parts,
// speed, transitions) rebuilds the composition.
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
    let state: RenderState
    private var composition: AVMutableVideoComposition?
    /// The selected segment, clip part ("p:…") or move ("m:…"); empty for none.
    private(set) var selected = ""
    /// Why the last edit was refused; cleared by the next one that lands.
    private(set) var problem = ""
    private var listeners: [ObjectIdentifier: () -> Void] = [:]
    private var playing: NSKeyValueObservation?
    /// Said when the selection, an edit or the play state changes: the module turns it into a watched topic.
    var onChange: () -> Void = {}

    var folder: URL { Library.recordings.appendingPathComponent(id) }
    var duration: Double { min(meta.duration, asset.duration.seconds.isFinite ? asset.duration.seconds : meta.duration) }
    var isPlaying: Bool { player.timeControlStatus != .paused }
    var framing: Framing { state.current }

    init?(id: String) {
        guard let meta = Library.meta(id) else { return nil }
        CursorArt.prepare()
        self.id = id
        self.meta = meta
        cursor = Library.cursor(id)
        asset = AVURLAsset(url: Library.recordings.appendingPathComponent(id).appendingPathComponent("capture.mov"))
        let file = Library.recordings.appendingPathComponent(id).appendingPathComponent("edits.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Edits.self, from: data) {
            edits = saved
        } else {
            // A first open starts clean; Zoom on Clicks adds zooms where the clicks are.
            edits = Edits()
        }
        map = TimeMap(duration: meta.duration, edits: edits)
        let folder = Library.recordings.appendingPathComponent(id)
        // The recording's own look; a recording without one starts from the last look used.
        if let data = try? Data(contentsOf: folder.appendingPathComponent("look.json")), let saved = try? JSONDecoder().decode(Look.self, from: data) {
            look = saved
        } else if let last = UserDefaults.standard.data(forKey: "ExactStudio.lastLook"), let saved = try? JSONDecoder().decode(Look.self, from: last) {
            look = saved
        }
        state = RenderState(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        player.actionAtItemEnd = .pause
        rebuild(keepTime: false)
        // A device recording without its silhouette yet (made before there was one): find it now.
        if meta.isDevice && meta.mask == nil && meta.crop == .full { findDevice(quietly: true) }
        playing = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.notify() }
        }
        stamps = Editor.stamps(folder)
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkDisk() }
    }

    deinit { watcher?.invalidate() }

    // MARK: Edits made outside the app

    /// The files an agent or the CLI may change, and when each last changed.
    private static let watched = ["edits.json", "look.json", "meta.json"]
    private var stamps: [String: Date] = [:]
    private var watcher: Timer?

    private static func stamps(_ folder: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        for name in watched {
            if let d = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate] as? Date { out[name] = d }
        }
        return out
    }

    /// A file changed on disk: take what it now says, if it differs from what is open.
    /// The app's own saves read back equal and change nothing.
    // @ref LLP 0004#the-rule — files are the source of truth; agents edit them while the app runs
    private func checkDisk() {
        let now = Editor.stamps(folder)
        guard now != stamps else { return }
        stamps = now
        let read = { (name: String) in try? Data(contentsOf: self.folder.appendingPathComponent(name)) }
        var timing = false, drawn = false
        if let data = read("edits.json"), let disk = try? JSONDecoder().decode(Edits.self, from: data), disk != edits {
            timing = Editor.timing(disk) != Editor.timing(edits)
            edits = disk
            drawn = true
            if !selected.isEmpty, selectedSegment == nil, selectedMove == nil, selectedPiece == nil { selected = "" }
        }
        if let data = read("look.json"), let disk = try? JSONDecoder().decode(Look.self, from: data), disk != look {
            look = disk
            drawn = true
        }
        if let data = read("meta.json"), let disk = try? JSONDecoder().decode(RecordingMeta.self, from: data),
           (try? JSONEncoder().encode(disk)) != (try? JSONEncoder().encode(meta)) {
            meta = disk
            timing = true
        }
        guard timing || drawn else { return }
        problem = ""
        timing ? rebuild(keepTime: true) : refresh()
        notify()
    }

    // MARK: The look

    private func saveLook() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(look) else { return }
        try? data.write(to: folder.appendingPathComponent("look.json"))
        stamps = Editor.stamps(folder)
        UserDefaults.standard.set(data, forKey: "ExactStudio.lastLook")
    }

    /// Set one field of the look and save it beside the recording.
    func setLookField(_ field: String, _ value: String) {
        var l = look
        let n = Double(value), b = value == "true"
        switch field {
        case "background": l.background = value
        case "aspect": l.aspect = value
        case "padding": if let n { l.padding = min(max(n, 0), 40) }
        case "radius": if let n { l.radius = min(max(n, 0), 80) }
        case "shadow": l.shadow = b
        case "cursor": l.cursor = b
        case "cursorSize": if let n { l.cursorSize = min(max(n / 100, 0.3), 5) }
        case "clickEffect": l.clickEffect = b
        case "smoothCursor": l.smoothCursor = b
        case "customA": l.customA = value; l.background = "custom"
        case "customB": l.customB = value; l.background = "custom"
        case "customAngle": if let n { l.customAngle = n }
        case "customRadial": l.customRadial = b
        case "swapCustom": (l.customA, l.customB) = (l.customB, l.customA)
        default: return
        }
        guard l != look else { return }
        look = l
        saveLook()
        refresh()
        notify()
    }

    var lookInfo: [String: Any] {
        ["background": look.background, "aspect": look.aspect, "padding": look.padding.rounded(), "radius": look.radius.rounded(),
         "shadow": look.shadow, "cursor": look.cursor, "cursorSize": (look.cursorSize * 100).rounded(), "clickEffect": look.clickEffect,
         "smoothCursor": look.smoothCursor, "customA": look.customA, "customB": look.customB, "customAngle": look.customAngle.rounded(),
         "customRadial": look.customRadial]
    }

    func listen(_ owner: AnyObject, _ body: @escaping () -> Void) { listeners[ObjectIdentifier(owner)] = body }
    func unlisten(_ owner: AnyObject) { listeners[ObjectIdentifier(owner)] = nil }
    private func notify() { listeners.values.forEach { $0() }; onChange() }
    private func redrawViews() { listeners.values.forEach { $0() } }

    // MARK: Time

    /// The playhead in source seconds.
    var playhead: Double { map.source(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) }

    func seek(source t: Double) {
        let out = map.output(min(max(t, 0), duration))
        player.seek(to: CMTime(seconds: out, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
        settled?.cancel()
        let tell = DispatchWorkItem { [weak self] in self?.onChange() }
        settled = tell
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tell)
    }
    private var settled: DispatchWorkItem?

    func togglePlay() {
        endSample(returning: false)
        if isPlaying { player.pause(); return }
        if let item = player.currentItem, item.currentTime().seconds >= map.outputDuration - 0.05 { player.seek(to: .zero) }
        player.play()
    }

    // MARK: Showing a change once

    private var sampleEnd: Any?
    private var sampleReturn: Double?

    /// Play source seconds `from`–`to` once, then go back to where the playhead was:
    /// so a chosen animation is seen without pressing play. Not while already playing.
    func sample(_ from: Double, _ to: Double) {
        guard !isPlaying || sampleReturn != nil else { return }
        let back = sampleReturn ?? playhead
        endSample(returning: false)
        sampleReturn = back
        let a = max(0, from), b = min(duration, max(to, a + 0.2))
        let end = CMTime(seconds: map.output(b), preferredTimescale: 6000)
        sampleEnd = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            self?.endSample(returning: true)
        }
        player.seek(to: CMTime(seconds: map.output(a), preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            guard done, self?.sampleReturn != nil else { return }
            self?.player.play()
        }
    }

    private func endSample(returning: Bool) {
        if let o = sampleEnd { player.removeTimeObserver(o) }
        sampleEnd = nil
        guard let back = sampleReturn else { return }
        sampleReturn = nil
        guard returning else { return }
        player.pause()
        // A beat on the last frame, then back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.seek(source: back)
        }
    }

    /// The span that shows a segment's chosen look: its entrance, its exit, or a stretch of its middle.
    private func sampleSegment(_ s: Segment, part: String) {
        switch part {
        case "out": sample(s.end - 1.1, s.end)
        case "loop": sample(s.start + 0.6, min(s.end, s.start + 3))
        default: sample(s.start, min(s.end, s.start + 1.3))
        }
    }

    // MARK: Building

    func setLook(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        refresh()
    }

    private func setMeta(_ m: RecordingMeta) {
        meta = m
        try? Library.save(m)
        refresh()
        notify()
    }

    /// Redraw in place when the output keeps its size (padding, colours, a trim);
    /// rebuild only when the canvas itself changes (the frame's shape).
    private func refresh() {
        let next = Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder)
        next.canvas == state.current.canvas ? redraw() : rebuild(keepTime: true)
    }

    // MARK: Holding the picture through a rebuild

    /// The preview's hooks: show a still while the playback is replaced, then let it go.
    var freeze: (CGImage) -> Void = { _ in }
    var thaw: () -> Void = {}
    private var output: AVPlayerItemVideoOutput?
    private static let stills = CIContext()

    private func still() -> CGImage? {
        guard let item = player.currentItem, let output,
              let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return Editor.stills.createCGImage(image, from: image.extent)
    }

    func setCrop(_ crop: UnitRect) {
        var m = meta
        m.crop = crop
        setMeta(m)
    }

    /// The whole playback, made again: for timing changes and a new canvas.
    private func rebuild(keepTime: Bool) {
        let at = keepTime ? playhead : 0
        let wasPlaying = isPlaying
        let held = keepTime ? still() : nil
        if let held { freeze(held) }
        state.update(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        guard let (mix, composition, map) = try? Composition.make(asset: asset, meta: meta, edits: edits, state: state) else { return }
        self.map = map
        self.composition = composition
        let item = AVPlayerItem(asset: mix)
        item.videoComposition = composition
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        output = out
        player.replaceCurrentItem(with: item)
        let target = CMTime(seconds: map.output(min(max(at, 0), duration)), preferredTimescale: 6000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            // The new frame takes a moment to reach the screen after the seek lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { if held != nil { self?.thaw() } }
        }
        if wasPlaying { player.play() }
    }

    /// The framing swapped and the frame drawn again; the timing stays.
    private func redraw() {
        state.update(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        // A fresh copy of the same composition makes the player ask for frames again; while
        // paused, a seek to where it stands makes it draw this one now.
        if let c = composition?.mutableCopy() as? AVMutableVideoComposition {
            player.currentItem?.videoComposition = c
        }
        if !isPlaying, let item = player.currentItem {
            item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        redrawViews()
    }

    /// A separate composition for export, at this editor's edits and the look asked for.
    func exportable(look: Look) throws -> (AVAsset, AVMutableVideoComposition) {
        let own = RenderState(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        let (mix, composition, _) = try Composition.make(asset: asset, meta: meta, edits: edits, state: own)
        return (mix, composition)
    }

    // MARK: Editing

    private func save() {
        // Pretty and sorted, so a person or an agent can read it and a diff stays small.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(edits).write(to: folder.appendingPathComponent("edits.json"))
        stamps = Editor.stamps(folder)
    }

    private static func timing(_ e: Edits) -> String {
        "\(e.splits)|\(e.removed)|\(e.transitions.sorted { $0.key < $1.key })|\(e.speeds.map { "\($0.start),\($0.end),\($0.rate ?? 1)" })"
    }

    /// Land `next` if every segment in it may sit where it is; else keep the
    /// edits as they were and say why.
    @discardableResult
    private func apply(_ next: Edits) -> Bool {
        if let why = next.segments.lazy.compactMap({ next.conflict($0) }).first {
            refuse(why)
            return false
        }
        problem = ""
        guard next != edits else { save(); notify(); return true }
        let retime = Editor.timing(next) != Editor.timing(edits)
        edits = next
        save()
        retime ? rebuild(keepTime: true) : redraw()
        notify()
        return true
    }

    private func refuse(_ why: String) {
        problem = why
        notify()
    }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        problem = ""
        notify()
    }

    static func newID(_ prefix: String) -> String { "\(prefix)\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)\(Int.random(in: 10...99))" }

    var selectedSegment: Segment? { edits.segments.first { $0.id == selected } }
    var pieces: [Piece] { edits.pieces(duration) }
    var selectedPiece: Piece? { pieces.first { $0.id == selected } }
    var selectedMove: Move? { edits.moves.first { "m:" + $0.id == selected } }

    // MARK: The clip

    /// Split the clip at the playhead. A split inside a removed part leaves both halves removed.
    func splitClip() {
        let t = playhead
        guard t > 0.05, t < duration - 0.05 else { return refuse("Move the playhead into the clip to split it.") }
        guard !edits.splits.contains(where: { abs($0 - t) < 0.05 }) else { return refuse("The clip is already split there.") }
        var next = edits
        if let p = pieces.first(where: { t > $0.start && t < $0.end }), p.removed { next.removed.append(t) }
        next.splits = (next.splits + [t]).sorted()
        apply(next)
        if let p = edits.pieces(duration).first(where: { Edits.same($0.start, t) }) { select(p.id) }
    }

    /// Remove the selected part from the video, or put it back.
    func toggleRemoved() {
        guard let p = selectedPiece else { return }
        var next = edits
        if p.removed { next.removed.removeAll { Edits.same($0, p.start) } } else { next.removed.append(p.start) }
        if !p.removed && next.pieces(duration).allSatisfy(\.removed) { return refuse("Keep at least one part of the clip.") }
        apply(next)
    }

    /// Join the selected part with the one before (-1) or after (+1).
    func join(_ side: Int) {
        guard let p = selectedPiece else { return }
        let at = side < 0 ? p.start : p.end
        guard at > 0.001, at < duration - 0.001 else { return }
        guard let keep = side < 0 ? pieces.first(where: { Edits.same($0.end, p.start) }) : p else { return }
        var next = edits
        next.splits.removeAll { Edits.same($0, at) }
        next.removed.removeAll { Edits.same($0, at) || Edits.same($0, keep.start) }
        if keep.removed { next.removed.append(keep.start) }
        apply(next)
        if let j = edits.pieces(duration).first(where: { Edits.same($0.start, keep.start) }) { select(j.id) }
    }

    /// How the selected kept part passes into the next one: "cut", "crossfade" or "fade".
    func setTransition(_ kind: String) {
        guard let p = selectedPiece, !p.removed else { return }
        var next = edits
        next.transitions[Edits.key(p.end)] = kind == "cut" ? nil : kind
        apply(next)
    }

    // MARK: Effects and texts

    /// A new effect of `choice` at the playhead, on the first lane with room
    /// (a new lane when none has), selected. `choice` is a visual kind, "text",
    /// or "zoom-in", "zoom-out", "slow" or "fast".
    func add(_ choice: String) {
        var s = Segment(id: Editor.newID("s"), kind: choice, start: 0, end: 0)
        switch choice {
        case "zoom-in": s.kind = "zoom"; s.level = 2
        case "zoom-out": s.kind = "zoom"; s.level = 0.7
        case "slow": s.kind = "speed"; s.rate = 0.5
        case "fast": s.kind = "speed"; s.rate = 2
        case "3d": s.style = "hold"; s.tilt = 12; s.turn = -28; s.roll = 0
        case "text":
            s.text = "Your text here"; s.x = 0.5; s.y = 0.16; s.size = 0.075; s.color = "white"; s.weight = "heavy"
            s.style = "pill"; s.animIn = "letters"; s.animOut = "fade"; s.loop = "none"; s.rotation = 0
        default: break
        }
        guard Segment.kinds.contains(s.kind) else { return }
        let length: Double = s.kind == "zoom" || s.kind == "text" || s.kind == "3d" ? 3 : 2
        let t = min(playhead, max(0, duration - 0.3))
        if s.kind == "text" {
            s.start = t
            s.end = min(duration, t + length)
        } else {
            // Same-group segments bound it: it fills the room between them, up to its length.
            let before = edits.segments.filter { $0.group == s.group && $0.end <= t + 0.0001 }.map(\.end).max() ?? 0
            let after = edits.segments.filter { $0.group == s.group && $0.start >= t - 0.0001 }.map(\.start).min() ?? duration
            if edits.segments.contains(where: { $0.group == s.group && $0.start < t && $0.end > t }) || after - max(before, t) < 0.3 {
                return refuse("There’s already \(Segment.article(s.kind)) at the playhead. Move the playhead to a free spot.")
            }
            s.start = max(before, t)
            s.end = min(after, s.start + length)
        }
        var next = edits
        var lane = 0
        while lane < next.lanes && next.segments.contains(where: { $0.lane == lane && $0.overlaps(s) }) { lane += 1 }
        s.lane = lane
        next.lanes = max(next.lanes, lane + 1)
        next.segments.append(s)
        if apply(next) { select(s.id) }
    }

    func addLane() {
        var next = edits
        next.lanes += 1
        apply(next)
    }

    /// Remove an empty lane; the lanes below move up.
    func removeLane(_ lane: Int) {
        guard edits.lanes > 1, !edits.segments.contains(where: { $0.lane == lane }) else { return }
        var next = edits
        next.lanes -= 1
        next.segments = next.segments.map { var s = $0; if s.lane > lane { s.lane -= 1 }; return s }
        apply(next)
    }

    /// Set the selected segment's value: a zoom's level, a speed's rate, or (for
    /// a visual effect) another visual kind.
    func setValue(number: Double?, kind: String?) {
        guard var s = selectedSegment else { return }
        if s.kind == "zoom", let n = number { s.level = n }
        if s.kind == "speed", let n = number { s.rate = n }
        if Segment.visual.contains(s.kind), let k = kind, Segment.visual.contains(k) { s.kind = k }
        replace(s)
        sampleSegment(s, part: "in")
    }

    /// Set one field of the selected text.
    func setText(_ field: String, _ value: String) {
        guard var s = selectedSegment, s.kind == "text" else { return }
        let n = Double(value)
        switch field {
        case "text": s.text = value
        case "size": if let n { s.size = min(max(n / 100, 0.02), 0.3) }
        case "rotation": if let n { s.rotation = min(max(n, -180), 180) }
        case "color": s.color = value
        case "weight": s.weight = value
        case "style": s.style = value
        case "in": s.animIn = value
        case "out": s.animOut = value
        case "loop": s.loop = value
        default: return
        }
        replace(s)
        switch field {
        case "in", "style", "weight", "color": sampleSegment(s, part: "in")
        case "out": sampleSegment(s, part: "out")
        case "loop": sampleSegment(s, part: "loop")
        default: break
        }
    }

    private func replace(_ s: Segment) {
        var next = edits
        next.segments = next.segments.map { $0.id == s.id ? s : $0 }
        apply(next)
    }

    static func stamp(_ s: Double) -> String { String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

    /// Typed times for the selection: an effect's span, a clip part's edges
    /// (which move the splits beside it), or a move's arrival.
    func setTimes(start: Double?, end: Double?) {
        if var s = selectedSegment {
            let a = start ?? s.start, b = end ?? s.end
            guard a >= 0, b <= duration + 0.001, b - a >= 0.1 else { return refuse("Start must come at least 0.1 s before end, inside 0:00–\(Editor.stamp(duration)).") }
            s.start = a; s.end = min(b, duration)
            replace(s)
        } else if var m = selectedMove {
            guard let a = start ?? end, a >= 0, a <= duration else { return refuse("A move must land inside 0:00–\(Editor.stamp(duration)).") }
            m.t = a
            setMove(m)
        } else if let p = selectedPiece {
            let all = pieces
            guard let i = all.firstIndex(of: p) else { return }
            let low = i > 0 ? all[i - 1].start + 0.1 : 0, high = i + 1 < all.count ? all[i + 1].end - 0.1 : duration
            var next = edits
            if let a = start, i > 0 {
                guard a >= low, a < p.end - 0.1 else { return refuse("That start would pass the next split or the part before.") }
                next.splits = next.splits.map { Edits.same($0, p.start) ? a : $0 }.sorted()
                next.removed = next.removed.map { Edits.same($0, p.start) ? a : $0 }
            }
            if let b = end, i + 1 < all.count {
                guard b <= high, b > (start ?? p.start) + 0.1 else { return refuse("That end would pass the next split or the part after.") }
                next.splits = next.splits.map { Edits.same($0, p.end) ? b : $0 }.sorted()
                next.removed = next.removed.map { Edits.same($0, p.end) ? b : $0 }
                if let kind = next.transitions.removeValue(forKey: Edits.key(p.end)) { next.transitions[Edits.key(b)] = kind }
            }
            apply(next)
            if let a = start, i > 0, let q = edits.pieces(duration).first(where: { Edits.same($0.start, a) }) { select(q.id) }
        }
    }

    /// Delete: an effect, text or move goes; a clip part is removed from the video (or put back).
    func deleteSelected() {
        if selectedPiece != nil { return toggleRemoved() }
        guard !selected.isEmpty else { return }
        var next = edits
        next.segments.removeAll { $0.id == selected }
        next.moves.removeAll { "m:" + $0.id == selected }
        apply(next)
        select("")
    }

    /// Split the selected effect in two at the playhead.
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
        var zooms = Edits.autoZooms(meta.clicks, duration: meta.duration)
        var lane = 0
        while zooms.contains(where: { z in next.segments.contains { $0.lane == lane && $0.overlaps(z) } }) { lane += 1 }
        zooms = zooms.map { var z = $0; z.lane = lane; return z }
        next.lanes = max(next.lanes, lane + 1)
        next.segments += zooms
        apply(next)
        select("")
    }

    /// Set one field of the selected segment: a blur's or black and white's "scope", or a 3D
    /// turn's "pose" (a named pose), "tilt", "turn", "roll" or "style" ("hold" or "orbit").
    func setSegment(_ field: String, _ value: String) {
        guard var s = selectedSegment else { return }
        let n = Double(value)
        switch field {
        case "scope": s.scope = value == "frame" ? "frame" : nil
        case "pose": let a = Editor.pose(value); s.tilt = a.tilt; s.turn = a.turn; s.roll = a.roll
        case "tilt": if let n { s.tilt = min(max(n, -80), 80) }
        case "turn": if let n { s.turn = min(max(n, -80), 80) }
        case "roll": if let n { s.roll = min(max(n, -45), 45) }
        case "style": s.style = value
        default: return
        }
        replace(s)
        if s.kind == "3d", field == "pose" || field == "style" { sampleSegment(s, part: "loop") }
    }

    // MARK: Templates

    /// The edits before the last template, for one step back.
    private var beforeTemplate: Edits?

    /// Replace the texts, effects, zooms and moves with a ready-made edit laid out for the
    /// frame's shape. The clip's parts and the 3D settings stay.
    func applyTemplate(_ name: String) {
        let map = self.map
        guard let made = Templates.make(name, duration: map.outputDuration, source: { map.source($0) }, aspect: look.aspect,
                                        clicks: meta.clicks, three: edits.three) else { return }
        beforeTemplate = edits
        var next = edits
        // Each segment on the first lane where nothing overlaps it.
        var packed: [Segment] = []
        for var seg in made.segments.sorted(by: { $0.start < $1.start }) {
            var lane = 0
            while packed.contains(where: { $0.lane == lane && $0.overlaps(seg) }) { lane += 1 }
            seg.lane = lane
            packed.append(seg)
        }
        next.segments = packed
        next.moves = made.moves
        next.lanes = max(1, (packed.map(\.lane).max() ?? 0) + 1)
        next.base = made.base
        apply(next)
        select("")
    }

    func undoTemplate() {
        guard let before = beforeTemplate else { return }
        beforeTemplate = nil
        apply(before)
        select("")
    }

    func clearAll() {
        apply(Edits())
        select("")
    }

    // MARK: 3D

    /// Set one 3D setting: "on", an angle ("tilt", "turn", "roll"), "thickness" (percent),
    /// "edge", or "preset" (a named pose). `live` draws it without saving (a drag).
    func setThree(_ field: String, _ value: String, live: Bool = false) {
        var next = edits
        var t = next.three
        let n = Double(value)
        // An angle or a pose goes to the selected move (switching 3D on); else it is the base angle.
        // An angle or a pose goes where the angle on screen comes from: the selected move, else the
        // move in effect at the playhead (switching 3D on); only before any such move, the base angle.
        if var m = selectedMove ?? angleMove, ["tilt", "turn", "roll", "preset"].contains(field) {
            let now = framing.pose(at: m.t).angles
            var a = m.angles ?? now
            switch field {
            case "tilt": if let n { a.tilt = min(max(n, -80), 80) }
            case "turn": if let n { a.turn = min(max(n, -80), 80) }
            case "roll": if let n { a.roll = min(max(n, -180), 180) }
            default: a = Editor.pose(value)
            }
            m.angles = a
            next.moves = next.moves.map { $0.id == m.id ? m : $0 }
            next.three.on = true
            if live { edits = next; redraw() } else {
                apply(next)
                if field == "preset" { sample(m.t - m.duration - 0.3, m.t + 0.4) }
            }
            return
        }
        switch field {
        case "on": t.on = value == "true"
        case "tilt": if let n { t.tilt = min(max(n, -80), 80) }
        case "turn": if let n { t.turn = min(max(n, -80), 80) }
        case "roll": if let n { t.roll = min(max(n, -180), 180) }
        case "thickness": if let n { t.thickness = min(max(n / 100, 0.01), 0.3) }
        case "edge": t.edge = value
        case "preset":
            t.on = true
            let a = Editor.pose(value)
            (t.tilt, t.turn, t.roll) = (a.tilt, a.turn, a.roll)
        default: return
        }
        next.three = t
        if live { edits = next; redraw() } else { apply(next) }
    }

    /// The move whose 3D angle shows at the playhead: one travelling now, else the last to land; nil before any.
    var angleMove: Move? {
        let t = playhead
        let turning = edits.moves.filter { $0.angles != nil }.sorted { $0.t < $1.t }
        if let m = turning.first(where: { t > $0.t - $0.duration && t < $0.t }) { return m }
        return turning.last { $0.t <= t + 0.001 }
    }

    private var angleTarget: Angles {
        if let m = selectedMove ?? angleMove { return m.angles ?? framing.pose(at: m.t).angles }
        return Angles(tilt: edits.three.tilt, turn: edits.three.turn, roll: edits.three.roll)
    }

    /// A named 3D pose.
    static func pose(_ name: String) -> Angles {
        switch name {
        case "hero": return Angles(tilt: 12, turn: -28, roll: 0)
        case "lean-left": return Angles(tilt: 0, turn: -38, roll: 0)
        case "lean-right": return Angles(tilt: 0, turn: 38, roll: 0)
        case "lay-back": return Angles(tilt: 48, turn: 0, roll: 0)
        case "tumble": return Angles(tilt: 22, turn: 32, roll: -12)
        default: return Angles()
        }
    }

    /// Whether the selected move sets a 3D angle of its own, and the angle it lands at.
    private var moveAngles: (Bool, Angles) {
        guard let m = selectedMove else { return (false, Angles()) }
        return (m.angles != nil, m.angles ?? framing.pose(at: m.t).angles)
    }

    // MARK: Placement and moves

    /// Where the subject is at the playhead.
    var placementNow: Placement {
        let p = framing.pose(at: playhead)
        return Placement(x: p.x, y: p.y, scale: p.scale)
    }

    /// The move the playhead sits on (within a few frames), if any.
    private var moveAtPlayhead: Move? {
        if let m = selectedMove, abs(m.t - playhead) < 0.2 { return m }
        return edits.moves.first { abs($0.t - playhead) < 0.12 }
    }

    /// Put the subject at `to`: the selected move or the one at the playhead
    /// when there is one, a new move at the playhead when other moves exist,
    /// else the base placement for the whole video. `live` draws it without
    /// saving (a drag); the drop saves.
    func place(_ to: Placement, live: Bool = false) {
        var next = edits
        if let m = moveAtPlayhead {
            next.moves = next.moves.map { $0.id == m.id ? Move(id: m.id, t: m.t, to: to, style: m.style, duration: m.duration, angles: m.angles) : $0 }
        } else if !next.moves.isEmpty && !live {
            let m = Move(id: Editor.newID("m"), t: playhead, to: to, style: lastStyle, duration: lastDuration)
            next.moves.append(m)
            edits = next
            save(); redraw(); select("m:" + m.id)
            return
        } else if next.moves.isEmpty {
            next.base = to
        } else {
            // A live drag with moves but none here: show it; the drop makes the move.
            preview(next, placing: to)
            return
        }
        if live {
            edits = next
            redraw()
        } else {
            apply(next)
        }
    }

    private var pendingPlace: Placement?
    private func preview(_ e: Edits, placing: Placement) {
        pendingPlace = placing
        var shown = e
        shown.moves.append(Move(id: "live", t: playhead, to: placing, style: "linear", duration: 0.001))
        state.update(Framing(meta: meta, look: look, edits: shown, cursor: cursor, folder: folder))
        if let c = composition?.mutableCopy() as? AVMutableVideoComposition { player.currentItem?.videoComposition = c }
    }

    /// The end of a drag of the subject.
    func endPlace() {
        if let to = pendingPlace { pendingPlace = nil; place(to); return }
        save()
        notify()
    }

    private var lastStyle = "smooth", lastDuration = 0.8

    /// A move at the playhead from where the subject is now, selected, ready to be dragged.
    func addMove() {
        if let m = moveAtPlayhead { return select("m:" + m.id) }
        let m = Move(id: Editor.newID("m"), t: playhead, to: placementNow, style: lastStyle, duration: lastDuration)
        var next = edits
        next.moves.append(m)
        apply(next)
        select("m:" + m.id)
    }

    private func setMove(_ m: Move) {
        var next = edits
        next.moves = next.moves.map { $0.id == m.id ? m : $0 }
        lastStyle = m.style
        lastDuration = m.duration
        apply(next)
    }

    /// Set one field of the selected move.
    func setMoveField(_ field: String, _ value: String) {
        guard var m = selectedMove else { return }
        let n = Double(value)
        switch field {
        case "style": m.style = value
        case "duration": if let n { m.duration = min(max(n, 0.05), 10) }
        case "scale": if let n { m.to.scale = min(max(n / 100, 0.2), 4) }
        default: return
        }
        setMove(m)
        if field != "scale" { sample(m.t - m.duration - 0.3, m.t + 0.4) }
    }

    /// A named place: the subject's spot and size there.
    static func preset(_ name: String) -> Placement? {
        switch name {
        case "center": return Placement(x: 0.5, y: 0.5, scale: 1)
        case "left": return Placement(x: 0.3, y: 0.5, scale: 0.9)
        case "right": return Placement(x: 0.7, y: 0.5, scale: 0.9)
        case "top": return Placement(x: 0.5, y: 0.36, scale: 0.85)
        case "bottom": return Placement(x: 0.5, y: 0.64, scale: 0.85)
        case "large": return Placement(x: 0.5, y: 0.5, scale: 1.35)
        case "small": return Placement(x: 0.78, y: 0.72, scale: 0.45)
        default: return nil
        }
    }

    func placePreset(_ name: String) {
        guard let p = Editor.preset(name) else { return }
        place(p)
    }

    /// A ready-made sequence of moves, starting at the playhead.
    func pattern(_ name: String) {
        let t0 = playhead
        let room = duration - t0
        guard room > 1.5 else { return refuse("Move the playhead earlier: a pattern needs some room after it.") }
        func m(_ dt: Double, _ p: Placement, _ style: String, _ d: Double, _ a: Angles? = nil) -> Move {
            Move(id: Editor.newID("m"), t: min(duration, t0 + dt * min(1, room / 6)), to: p, style: style, duration: d * min(1, room / 6), angles: a)
        }
        // A 3D pattern keeps the subject where it is and only turns it.
        let here = placementNow
        let face = Angles()
        let c = Placement(), l = Editor.preset("left")!, r = Editor.preset("right")!
        var add: [Move]
        switch name {
        case "side":   // Left, right, back to the middle.
            add = [m(0.9, l, "smooth", 0.9), m(3.0, r, "smooth", 1.1), m(5.2, c, "smooth", 0.9)]
        case "tour":   // Through full screen to each side and back.
            add = [m(1.2, l, "zoom", 1.2), m(3.6, r, "zoom", 1.2), m(6.0, c, "zoom", 1.2)]
        case "entrance": // In from below with a spring.
            add = [m(0.01, Placement(x: 0.5, y: 1.5, scale: 0.9), "linear", 0.01), m(1.1, c, "spring", 1.0)]
        case "drift":  // A slow push in.
            add = [m(6.0, Placement(x: 0.52, y: 0.48, scale: 1.12), "linear", 6.0)]
        case "bounce": // Pop between the sides.
            add = [m(1.0, l, "pop", 0.8), m(2.8, r, "pop", 0.8), m(4.6, c, "pop", 0.8)]
        case "turntable": // Swing to one side, then the other, then face front.
            add = [m(1.5, here, "smooth", 1.5, Angles(tilt: 6, turn: -35)), m(4.0, here, "smooth", 2.5, Angles(tilt: 6, turn: 35)), m(6.0, here, "smooth", 1.8, face)]
        case "orbit": // One full turn about the vertical.
            add = [m(3.2, here, "spin", 3.2, Angles(tilt: 8, turn: 0))]
        case "reveal": // Up from lying back into a hero angle.
            add = [m(0.01, here, "linear", 0.01, Angles(tilt: 62, turn: 0)), m(1.7, here, "spring", 1.6, Editor.pose("hero"))]
        case "flip": // In edge-on, springing to face front.
            add = [m(0.01, here, "linear", 0.01, Angles(tilt: 0, turn: -88)), m(1.3, here, "spring", 1.2, face)]
        case "float": // A slow drift between gentle angles.
            add = [m(2.0, here, "smooth", 2.0, Angles(tilt: 8, turn: -14)), m(4.0, here, "smooth", 2.0, Angles(tilt: -5, turn: 14, roll: 3)), m(6.0, here, "smooth", 2.0, face)]
        default: return
        }
        var next = edits
        next.moves.removeAll { mv in add.contains { abs($0.t - mv.t) < 0.15 } }
        add = add.filter { $0.t <= duration }
        next.moves += add
        if add.contains(where: { $0.angles != nil }) { next.three.on = true }
        apply(next)
        if let first = add.last { select("m:" + first.id) }
    }

    // MARK: Texts and moves dragged in the preview

    func dragText(_ id: String, x: Double, y: Double, live: Bool) {
        var next = edits
        next.segments = next.segments.map { s in
            guard s.id == id else { return s }
            var m = s
            m.x = min(max(x, 0), 1); m.y = min(max(y, 0), 1)
            return m
        }
        if live { edits = next; redraw() } else { apply(next) }
    }

    func moveTime(_ id: String, to t: Double, live: Bool) {
        var next = edits
        next.moves = next.moves.map { $0.id == id ? Move(id: $0.id, t: min(max(t, 0), duration), to: $0.to, style: $0.style, duration: $0.duration, angles: $0.angles) : $0 }
        if live { edits = next; redraw() } else { apply(next) }
    }

    // MARK: Dragging (the timeline's)

    private var dragOrigin: Edits?

    /// Move or resize a segment while dragging: drawn at once, checked on drop.
    /// `lane` may be one past the last: the drop opens a new lane there.
    func drag(_ id: String, start: Double, end: Double, lane: Int) {
        if dragOrigin == nil { dragOrigin = edits }
        let s = max(0, min(start, duration - 0.1)), e = min(duration, max(end, s + 0.1))
        edits.segments = edits.segments.map {
            guard $0.id == id else { return $0 }
            var m = $0
            m.start = s; m.end = e; m.lane = max(0, lane)
            return m
        }
        redrawViews()
    }

    /// The drop: keep the move if it fits, else put the segment back.
    func endDrag() {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        var moved = edits
        moved.lanes = max(origin.lanes, (moved.segments.map(\.lane).max() ?? 0) + 1)
        edits = origin
        if !apply(moved) { redrawViews() }
    }

    // MARK: Finding a device

    /// Look for a device's bezel in the picture (an area or window recording of
    /// a Simulator): crop to it and cut to its rounded corners.
    func findDevice(quietly: Bool = false) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let at = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: at, actualTime: nil) else { return quietly ? () : refuse("Couldn’t read a frame of the recording.") }
        var m = meta
        if let found = Bezel.silhouette(image), let name = Library.saveMask(found.mask, in: folder) {
            if let old = m.mask { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
            m.crop = found.rect
            m.mask = name
            m.maskRect = found.rect
            m.cornerRadius = nil
        } else if let outline = Bezel.outline(image) {
            m.crop = outline.rect
            m.cornerRadius = outline.radius
        } else {
            return quietly ? () : refuse("No device found in the picture: it looks for a phone on its window’s panel.")
        }
        m.device = true
        setMeta(m)
    }

    func forgetDevice() {
        var m = meta
        if let old = m.mask { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        m.crop = .full
        m.cornerRadius = nil
        m.mask = nil
        m.maskRect = nil
        m.device = nil
        setMeta(m)
    }

    // MARK: What the inspector shows

    var selection: [String: Any] {
        var out: [String: Any] = ["id": "", "kind": "", "level": 0, "rate": 0, "start": 0, "end": 0, "startText": "", "endText": "",
                                  "removed": false, "first": false, "last": false, "transition": "cut", "text": "", "size": 0,
                                  "color": "", "weight": "", "style": "", "animIn": "", "animOut": "", "loop": "", "rotation": 0,
                                  "moveStyle": "", "duration": 0, "scale": 0, "tilt": 0, "turn": 0, "roll": 0, "hasAngles": false, "scope": "video", "problem": problem]
        if let s = selectedSegment {
            out.merge(["scope": s.scope ?? "video", "tilt": (s.tilt ?? 0).rounded(), "turn": (s.turn ?? 0).rounded(), "roll": (s.roll ?? 0).rounded()]) { $1 }
            out.merge(["id": s.id, "kind": s.kind, "level": s.level ?? 0, "rate": s.rate ?? 0, "start": s.start, "end": s.end,
                       "startText": Editor.stamp(s.start), "endText": Editor.stamp(s.end), "text": s.text ?? "",
                       "size": ((s.size ?? 0) * 1000).rounded() / 10, "color": s.color ?? "", "weight": s.weight ?? "", "style": s.style ?? "",
                       "animIn": s.animIn ?? "", "animOut": s.animOut ?? "", "loop": s.loop ?? "", "rotation": s.rotation ?? 0]) { $1 }
        } else if let m = selectedMove {
            out.merge(["id": "m:" + m.id, "kind": "move", "start": m.t, "end": m.t, "startText": Editor.stamp(m.t), "endText": Editor.stamp(m.t),
                       "moveStyle": m.style, "duration": m.duration, "scale": (m.to.scale * 100).rounded(),
                       "tilt": moveAngles.1.tilt.rounded(), "turn": moveAngles.1.turn.rounded(), "roll": moveAngles.1.roll.rounded(),
                       "hasAngles": moveAngles.0]) { $1 }
        } else if let p = selectedPiece {
            let all = pieces
            out.merge(["id": p.id, "kind": "clip", "start": p.start, "end": p.end, "startText": Editor.stamp(p.start), "endText": Editor.stamp(p.end),
                       "removed": p.removed, "first": all.first == p, "last": all.last == p,
                       "transition": edits.transitions[Edits.key(p.end)] ?? "cut"]) { $1 }
        }
        return out
    }

    var summary: [String: Any] {
        let parts = pieces
        return ["parts": parts.count, "removed": parts.filter(\.removed).count, "effects": edits.segments.count, "lanes": edits.lanes,
                "moves": edits.moves.count, "length": map.outputDuration, "source": duration, "playing": isPlaying,
                "device": meta.isDevice, "found": meta.device == true, "cursorDrawn": meta.drawsCursor,
                "baseScale": (edits.base.scale * 100).rounded(), "canUndoTemplate": beforeTemplate != nil,
                "threeOn": edits.three.on,
                // The angle the 3D controls edit: the move's in effect at the playhead, else the base.
                "tilt": angleTarget.tilt.rounded(), "turn": angleTarget.turn.rounded(), "roll": angleTarget.roll.rounded(),
                "angleMove": (selectedMove ?? angleMove).map { Editor.stamp($0.t) } ?? "",
                "thickness": (edits.three.thickness * 1000).rounded() / 10, "edge": edits.three.edge]
    }
}

extension Editor {
    static var defaultLook: [String: Any] {
        let l = Look()
        return ["background": l.background, "aspect": l.aspect, "padding": l.padding, "radius": l.radius, "shadow": l.shadow, "cursor": l.cursor,
                "cursorSize": l.cursorSize * 100, "clickEffect": l.clickEffect, "smoothCursor": l.smoothCursor, "customA": l.customA,
                "customB": l.customB, "customAngle": l.customAngle, "customRadial": l.customRadial]
    }
}

extension Segment {
    static func article(_ kind: String) -> String {
        ["zoom": "a zoom", "speed": "a speed change", "spotlight": "a spotlight", "highlight": "a cursor highlight",
         "blur": "a blur", "mono": "a black-and-white effect", "text": "a text"][kind] ?? "an effect"
    }
}
#endif
