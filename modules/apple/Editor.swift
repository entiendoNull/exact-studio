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
    /// The added sounds' audio tracks in the playing composition, by track id.
    private var soundTracks: [CMPersistentTrackID: String] = [:]
    /// The selected segment, clip part ("p:…") or move ("m:…"); empty for none.
    private(set) var selected = ""
    /// Why the last edit was refused; cleared by the next one that lands.
    private(set) var refusal: Conflict?
    var problem: String { refusal?.text ?? "" }
    // @ref LLP 0004#a-file-that-cannot-be-read
    private(set) var unreadable: [String: String] = [:]
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
        do {
            // A first open starts clean; Zoom on Clicks adds zooms where the clicks are.
            edits = try EditFile.read(Edits.self, file) ?? Edits()
        } catch {
            edits = Edits()
            unreadable["edits.json"] = Editor.unreadableText("edits.json", error)
        }
        map = TimeMap(duration: meta.duration, edits: edits)
        let folder = Library.recordings.appendingPathComponent(id)
        // The recording's own look; a recording without one starts from the last look used.
        do {
            if let saved = try EditFile.read(Look.self, folder.appendingPathComponent("look.json")) {
                look = saved
            } else if let last = Settings.store.data(forKey: "ExactStudio.lastLook"), let saved = try? JSONDecoder().decode(Look.self, from: last) {
                look = saved
            }
        } catch {
            unreadable["look.json"] = Editor.unreadableText("look.json", error)
        }
        state = RenderState(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        player.actionAtItemEnd = .pause
        rebuild(keepTime: false)
        // A device recording without its silhouette yet (made before there was one): find it now.
        if meta.isDevice && meta.mask == nil && meta.crop == .full { findDevice(quietly: true) }
        // A window recording made before its corners were measured: measure them now.
        if meta.isWindow && meta.cornerRadius == nil { measureWindow() }
        playing = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.notify() }
        }
        stamps = Editor.stamps(folder)
        committed = snapshot
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
        let wasUnreadable = unreadable
        if let disk = reread("edits.json", Edits.self), disk != edits {
            timing = Editor.timing(disk) != Editor.timing(edits)
            edits = disk
            drawn = true
            dropGoneSelection()
        }
        if let disk = reread("look.json", Look.self), disk != look {
            look = disk
            drawn = true
        }
        if unreadable != wasUnreadable { drawn = true }
        if let data = read("meta.json"), let disk = try? JSONDecoder().decode(RecordingMeta.self, from: data),
           (try? JSONEncoder().encode(disk)) != (try? JSONEncoder().encode(meta)) {
            meta = disk
            timing = true
        }
        guard timing || drawn else { return }
        refusal = nil
        record(named: "Edit from File")
        timing ? rebuild(keepTime: true) : refresh()
        notify()
    }

    private func reread<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
        do {
            let value = try EditFile.read(type, folder.appendingPathComponent(name))
            unreadable[name] = nil
            return value
        } catch {
            unreadable[name] = Editor.unreadableText(name, error)
            return nil
        }
    }

    static func unreadableText(_ name: String, _ error: Error) -> String {
        "\(name) can’t be read (\(EditFile.problem(error))). Nothing is saved over it until it is fixed: run exact-studio validate, fix the file, and the change shows here."
    }

    private var blocked: String? { unreadable["edits.json"] ?? unreadable["look.json"] }

    // MARK: The look

    private func saveLook() {
        guard unreadable["look.json"] == nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(look) else { return }
        try? data.write(to: folder.appendingPathComponent("look.json"))
        stamps = Editor.stamps(folder)
        Settings.store.set(data, forKey: "ExactStudio.lastLook")
        record()
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
        if let why = unreadable["look.json"] { return refuse(why) }
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
        guard !probing else { return }
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
        guard !probing else { return }
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
        record()
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
        guard let (mix, composition, map, sounds) = try? Composition.make(asset: asset, meta: meta, edits: edits, state: state) else { return }
        self.map = map
        self.composition = composition
        soundTracks = sounds
        let item = AVPlayerItem(asset: mix)
        item.videoComposition = composition
        item.audioMix = Composition.audioMix(mix, map: map, edits: edits, sounds: sounds)
        item.audioTimePitchAlgorithm = .spectral
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
        if let item = player.currentItem { item.audioMix = Composition.audioMix(item.asset, map: map, edits: edits, sounds: soundTracks) }
        if !isPlaying, let item = player.currentItem {
            item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
        redrawViews()
    }

    /// A separate composition for export, at this editor's edits and the look asked for.
    func exportable(look: Look) throws -> (AVAsset, AVMutableVideoComposition, AVAudioMix?) {
        let own = RenderState(Framing(meta: meta, look: look, edits: edits, cursor: cursor, folder: folder))
        let (mix, composition, map, sounds) = try Composition.make(asset: asset, meta: meta, edits: edits, state: own)
        return (mix, composition, Composition.audioMix(mix, map: map, edits: edits, sounds: sounds))
    }

    /// Whether the recording has sound.
    private(set) lazy var hasSound = !asset.tracks(withMediaType: .audio).isEmpty

    func setVolume(_ v: Double) {
        var next = edits
        next.volume = min(max(v, 0), 1)
        apply(next)
    }

    // MARK: Editing

    private func save() {
        guard unreadable["edits.json"] == nil else { return }
        // Pretty and sorted, so a person or an agent can read it and a diff stays small.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(edits).write(to: folder.appendingPathComponent("edits.json"))
        stamps = Editor.stamps(folder)
        record()
    }

    // MARK: Undo
    // @ref LLP 0002#undo

    private var undone: [HistoryStep] = []
    private var redone: [HistoryStep] = []
    private var committed: Snapshot?
    private var naming: String?

    var snapshot: Snapshot {
        Snapshot(edits: edits, look: look, crop: meta.crop, cornerRadius: meta.cornerRadius, device: meta.device, mask: meta.mask, maskRect: meta.maskRect)
    }
    var undoName: String { undone.last?.name ?? "" }
    var redoName: String { redone.last?.name ?? "" }

    private func record(named name: String? = nil) {
        guard let before = committed else { return }
        let now = snapshot
        guard now != before else { return }
        committed = now
        redone = []
        let title = name ?? naming
        let key = title == nil ? History.key(before, now) : nil
        if let key, let last = undone.last, last.key == key, Date().timeIntervalSince(last.at) < History.gather {
            undone[undone.count - 1].after = now
            undone[undone.count - 1].at = Date()
            return
        }
        undone.append(HistoryStep(before: before, after: now, name: title ?? History.name(before, now), key: key, at: Date()))
        if undone.count > History.limit { undone.removeFirst(undone.count - History.limit) }
    }

    @discardableResult
    private func named<T>(_ name: String, _ body: () -> T) -> T {
        naming = name
        defer { naming = nil }
        return body()
    }

    func undo() {
        guard let step = undone.popLast() else { return }
        restore(step.before)
        redone.append(step)
        notify()
    }

    func redo() {
        guard let step = redone.popLast() else { return }
        restore(step.after)
        undone.append(step)
        notify()
    }

    private func restore(_ s: Snapshot) {
        endSample(returning: false)
        dragOrigin = nil
        dragCheck = nil
        let now = snapshot
        let retime = Editor.timing(s.edits) != Editor.timing(edits) || !s.sameMeta(now)
        let lookChanged = s.look != look
        committed = s
        edits = s.edits
        look = s.look
        meta.crop = s.crop
        meta.cornerRadius = s.cornerRadius
        meta.device = s.device
        meta.mask = s.mask
        meta.maskRect = s.maskRect
        if lookChanged { saveLook() }
        if !s.sameMeta(now) { try? Library.save(meta) }
        save()
        refusal = nil
        dropGoneSelection()
        retime ? rebuild(keepTime: true) : refresh()
    }

    private func dropGoneSelection() {
        if !selected.isEmpty, selectedSegment == nil, selectedMove == nil, selectedPiece == nil, selectedImageMove == nil, selectedItemEffect == nil,
           selectedSound == nil, selected != Editor.recordedSound { selected = "" }
    }

    /// What the playback is built from; a change rebuilds it. A sound's volume and fades only change the mix.
    private static func timing(_ e: Edits) -> String {
        "\(e.splits)|\(e.removed)|\(e.transitions.sorted { $0.key < $1.key })|\(e.speeds.map { "\($0.start),\($0.end),\($0.rate ?? 1)" })"
            + "|\(e.sounds.map { "\($0.file),\($0.start),\($0.length),\($0.offset)" })"
    }

    /// Land `next` unless it breaks a rule the edit did not break before; else keep the
    /// edits as they were and say why. A file that broke a rule when it was opened still opens and saves.
    // @ref LLP 0005#refusals — refuse only what a change breaks; never lose an edit
    @discardableResult
    func apply(_ proposed: Edits) -> Bool {
        if let why = unreadable["edits.json"] { refuse(why); return false }
        let next = settle(proposed)
        if let c = Editor.newConflict(next, since: baseline, duration: duration) {
            refuse(c)
            return false
        }
        if probing { return false }
        refusal = nil
        guard next != edits else { save(); notify(); return true }
        let retime = Editor.timing(next) != Editor.timing(edits)
        edits = next
        save()
        retime ? rebuild(keepTime: true) : redraw()
        notify()
        return true
    }

    private var baseline: Edits { dragOrigin ?? committed?.edits ?? edits }

    // @ref LLP 0002#what-may-overlap — a taken lane is never a refusal in the app
    private func settle(_ proposed: Edits) -> Edits {
        var next = proposed
        // @ref LLP 0002#split — a half moved or resized away from the other is no longer joined
        next.dropLooseJoins(map: TimeMap(duration: duration, edits: next))
        let changed = Editor.changed(baseline, next)
        for _ in 0..<4 {
            let map = TimeMap(duration: duration, edits: next)
            let old = Set(baseline.conflicts(map: TimeMap(duration: duration, edits: baseline)).map(\.key))
            guard let c = next.conflicts(map: map).first(where: { $0.rule == "lane-taken" && !old.contains($0.key) }),
                  let mover = [c.item, c.other].compactMap({ $0 }).first(where: changed.contains) else { break }
            Editor.relane(&next, mover, map: map)
        }
        next.fitLanes()
        return next
    }

    private static func relane(_ e: inout Edits, _ ref: ItemRef, map: TimeMap) {
        switch ref.kind {
        case "sound":
            guard let i = e.sounds.firstIndex(where: { $0.id == ref.id }) else { return }
            var probe = e.sounds[i]
            probe.lane = 0
            while e.conflict(probe, map: map) != nil { probe.lane += 1 }
            e.sounds[i].lane = probe.lane
        case "image-effect":
            guard let i = e.segments.firstIndex(where: { $0.id == ref.image }), var fx = e.segments[i].effects, let j = fx.firstIndex(where: { $0.id == ref.id }) else { return }
            var row = 0
            while fx.contains(where: { $0.id != ref.id && $0.lane == row && $0.overlaps(fx[j]) && $0.kind != fx[j].kind }) { row += 1 }
            fx[j].lane = row
            e.segments[i].effects = fx
        case "move", "image-move": return
        default:
            guard let i = e.segments.firstIndex(where: { $0.id == ref.id }) else { return }
            e.segments[i].lane = e.freeLane(for: e.segments[i])
        }
    }

    static func changed(_ a: Edits, _ b: Edits) -> Set<ItemRef> {
        var out = Set<ItemRef>()
        for s in b.segments where a.segments.first(where: { $0.id == s.id }) != s {
            out.insert(.of(s))
            let was = a.segments.first { $0.id == s.id }
            for fx in s.effects ?? [] where was?.effects?.first(where: { $0.id == fx.id }) != fx { out.insert(.effect(fx, image: s.id)) }
            for m in s.moves ?? [] where was?.moves?.first(where: { $0.id == m.id }) != m { out.insert(.move(m, image: s.id)) }
        }
        for m in b.moves where a.moves.first(where: { $0.id == m.id }) != m { out.insert(.move(m)) }
        for s in b.sounds where a.sounds.first(where: { $0.id == s.id }) != s { out.insert(.sound(s)) }
        return out
    }

    static func newConflict(_ next: Edits, since before: Edits, duration: Double) -> Conflict? {
        let map = TimeMap(duration: duration, edits: next)
        let old = Set(before.conflicts(map: TimeMap(duration: duration, edits: before)).map(\.key))
        let fresh = next.conflicts(map: map).filter { !old.contains($0.key) }
        guard let first = fresh.first else { return nil }
        let changed = changed(before, next)
        for ref in changed.sorted(by: { $0.key < $1.key }) {
            if let c = next.conflicts(of: ref, map: map).first(where: { c in fresh.contains { $0.key == c.key } }) { return c }
        }
        return first
    }

    var standing: [Conflict] {
        let shown = dragOrigin ?? edits
        if let cached = standingCache, cached.edits == shown { return cached.conflicts }
        let found = shown.conflicts(map: map)
        standingCache = (shown, found)
        return found
    }
    private var standingCache: (edits: Edits, conflicts: [Conflict])?

    private var standingProblem: String {
        let ref: ItemRef? = selectedSegment.map(ItemRef.of) ?? selectedSound.map(ItemRef.sound) ?? selectedMove.map { ItemRef.move($0) }
            ?? selectedImageMove.map { ItemRef.move($0.move, image: $0.image.id) } ?? selectedItemEffect.map { ItemRef.effect($0.effect, image: $0.item.id) }
        guard let ref, let c = standing.first(where: { $0.involves(ref) }) else { return "" }
        return c.text
    }

    private func refuse(_ why: String) { refuse(.plain(why)) }

    private func refuse(_ c: Conflict) {
        if probing { probed = probed ?? c; return }
        refusal = c
        notify()
    }

    // MARK: Asking first

    private var probing = false
    private var probed: Conflict?

    // @ref LLP 0005#refusals — a menu item that would be refused is off, with its reason
    func probe(_ body: () -> Void) -> Conflict? {
        let was = (edits, selected, refusal, wantLane)
        probing = true
        probed = nil
        body()
        probing = false
        (edits, selected, refusal, wantLane) = was
        return probed
    }

    func select(_ id: String) {
        if probing { selected = id; return }
        guard selected != id else { return }
        selected = id
        typed = nil
        refusal = nil
        if let item = selectedItem {
            open(item)
            recentImages.removeAll { $0 == item.id }
            recentImages.insert(item.id, at: 0)
        }
        if let s = selectedSegment ?? selectedItem { reveal(space: s.space) }
        else if selectedSound != nil { reveal(space: Edits.soundSpace) }
        else if selectedPiece != nil || selectedMove != nil || id == Editor.recordedSound { reveal(space: 0) }
        notify()
    }

    nonisolated(unsafe) private static var lastID = 0
    static func newID(_ prefix: String) -> String {
        lastID = max(lastID + 1, Int(Date().timeIntervalSince1970 * 1000) % 100_000_000 * 100 + Int.random(in: 0...9))
        return "\(prefix)\(lastID)"
    }

    var selectedSegment: Segment? { edits.segments.first { $0.id == selected } }
    var pieces: [Piece] { edits.pieces(duration) }
    var selectedPiece: Piece? { pieces.first { $0.id == selected } }
    var selectedMove: Move? { edits.moves.first { "m:" + $0.id == selected } }

    // MARK: The clip

    /// Split the clip at the playhead. A split inside a removed part leaves both halves removed.
    func splitClip() {
        let t = playhead
        var next = edits
        do { try next.splitClip(at: t, duration: duration) } catch { return refuse((error as? SplitRefused)?.why ?? "") }
        named("Split Clip") { apply(next) }
        if let p = edits.pieces(duration).first(where: { Edits.same($0.start, t) }) { select(p.id) }
    }

    /// Remove the selected part from the video, or put it back.
    func toggleRemoved() {
        guard let p = selectedPiece else { return }
        var next = edits
        if p.removed { next.removed.removeAll { Edits.same($0, p.start) } } else { next.removed.append(p.start) }
        if !p.removed && next.pieces(duration).allSatisfy(\.removed) {
            return refuse(Rules.keepAPart)
        }
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
        case "blur-frame": s.kind = "blur"; s.scope = "frame"
        case "mono-frame": s.kind = "mono"; s.scope = "frame"
        case "3d": s.style = "hold"; s.tilt = 12; s.turn = -28; s.roll = 0
        case "mask":
            // A third of the visible video's width and a fifth of its height, in its middle: drag it onto what
            // it hides. The rect is in the full frame's units, so it goes through the crop.
            let c = meta.crop
            s.style = "blur"; s.rect = UnitRect(x: c.x + c.w / 3, y: c.y + c.h * 0.4, w: c.w / 3, h: c.h * 0.2)
        case "text":
            s.text = "Your text here"; s.x = 0.5; s.y = 0.16; s.size = 0.075; s.color = "white"; s.weight = "heavy"
            s.style = "pill"; s.animIn = "letters"; s.animOut = "fade"; s.loop = "none"; s.rotation = 0
        default: break
        }
        guard Segment.kinds.contains(s.kind) else { return }
        let length: Double = s.kind == "zoom" || s.kind == "text" || s.kind == "3d" ? 3 : 2
        let t = min(playhead, max(0, duration - 0.3))
        if s.isOverlay {
            s.start = t
            s.end = min(duration, t + length)
        } else {
            // Same-group segments bound it: it fills the room between them, up to its length.
            let before = edits.segments.filter { $0.group == s.group && $0.end <= t + 0.0001 }.map(\.end).max() ?? 0
            let after = edits.segments.filter { $0.group == s.group && $0.start >= t - 0.0001 }.map(\.start).min() ?? duration
            if let o = edits.segments.first(where: { $0.group == s.group && $0.start < t && $0.end > t })
                ?? (after - max(before, t) < 0.3 ? edits.segments.filter({ $0.group == s.group && $0.start >= t - 0.0001 }).min(by: { $0.start < $1.start }) : nil) {
                return refuse(Rules.noRoom(s.kind, at: t, o))
            }
            s.start = max(before, t)
            s.end = min(after, s.start + length)
        }
        land(s)
    }

    private var wantLane: Int?

    // @ref LLP 0005#add-where-it-goes
    func onLane(_ lane: Int?, _ body: () -> Void) {
        wantLane = lane
        defer { wantLane = nil }
        body()
    }

    /// Put a new segment on the first lane with room (a new lane when none has) and select it.
    private func land(_ segment: Segment) {
        var s = segment
        var next = edits
        s.lane = next.freeLane(for: s)
        if let want = wantLane, want < next.laneCount(space: s.space) {
            var there = s
            there.lane = want
            if next.fits(there) { s.lane = want }
        }
        next.segments.append(s)
        next.fitLanes()
        reveal(space: s.space)
        if apply(next) { select(s.id) }
    }

    // MARK: Images
    // @ref LLP 0002#images — images share lanes; each has its own moves and effects

    /// The image lanes and the text lanes open in the timeline, and the groups folded away: "video" (the Clip and every
    /// row under it), "top" (texts and images), "sound" and "frame". How the timeline looks, not part of the edit.
    private(set) var openImageLanes: Set<Int> = []
    private(set) var openTextLanes: Set<Int> = []
    private(set) var folded = Settings.folded
    var videoOpen: Bool { !folded.contains("video") }
    /// The images and texts selected so far, the last one first.
    private var recentImages: [String] = []

    func toggleImageLane(_ lane: Int) { toggleLane(space: 2, lane) }

    /// Open or fold an image lane (space 2) or a text lane (space 1): open, it shows one item's own rows.
    func toggleLane(space: Int, _ lane: Int) {
        if space == 1 {
            if openTextLanes.contains(lane) { openTextLanes.remove(lane) } else { openTextLanes.insert(lane) }
        } else {
            if openImageLanes.contains(lane) { openImageLanes.remove(lane) } else { openImageLanes.insert(lane) }
        }
        redrawViews()
    }

    func isOpen(space: Int, lane: Int) -> Bool { space == 1 ? openTextLanes.contains(lane) : space == 2 && openImageLanes.contains(lane) }

    private func open(_ item: Segment) {
        if item.kind == "text" { openTextLanes.insert(item.lane) } else if item.kind == "image" { openImageLanes.insert(item.lane) }
    }

    func currentImage(lane: Int) -> Segment? { currentItem(space: 2, lane: lane) }

    /// The image or text whose own rows an open lane shows: the selected one (or the
    /// one whose move or effect is selected) when it is on the lane; else the one on it selected
    /// last; else the one under the playhead; else the first. While a block is dragged, the lanes
    /// as they were, so the rows stay put under the pointer.
    func currentItem(space: Int, lane: Int) -> Segment? {
        let on = (dragOrigin ?? edits).segments.filter { $0.isOverlay && $0.space == space && $0.lane == lane }.sorted { $0.start < $1.start }
        if let s = selectedItem, let hit = on.first(where: { $0.id == s.id }) { return hit }
        if let id = recentImages.first(where: { id in on.contains { $0.id == id } }) { return on.first { $0.id == id } }
        return on.first { playhead >= $0.start && playhead < $0.end } ?? on.first
    }

    func toggle(group: String) {
        if folded.contains(group) { folded.remove(group) } else { folded.insert(group) }
        Settings.store.set(folded.sorted(), forKey: Settings.foldedKey)
        redrawViews()
    }

    /// The group a selection or a new segment shows in opens, so it is never out of sight.
    private func reveal(space: Int) {
        guard !probing else { return }
        let group = space == 0 ? "video" : space == 3 ? "frame" : space == Edits.soundSpace ? "sound" : "top"
        if folded.contains(group) { toggle(group: group) }
    }

    // MARK: Timeline zoom
    // @ref LLP 0005#zoom-the-timeline — view state, never part of the edit

    /// How far the timeline is zoomed in (1: the whole recording fits) and the recording time at
    /// its left edge. The timeline sets `zoomMax` from its width; it draws on `onZoom`.
    private(set) var zoom = 1.0
    private(set) var zoomStart = 0.0
    var zoomMax = 1.0
    var onZoom: () -> Void = {}
    var zoomed: Bool { zoom > 1.0001 }
    /// Whether the mouse wheel zooms the timeline (else it scrolls the rows). Kept between launches.
    var wheelZoom: Bool { Settings.store.object(forKey: "ExactStudio.wheelZoom") as? Bool ?? true }

    /// Zoom to `z`, with `start` at the left edge, kept inside the recording. Only redraws.
    func setZoom(_ z: Double, start: Double) {
        let was = zoomed
        zoom = min(max(z, 1), max(zoomMax, 1))
        let span = duration / zoom
        zoomStart = min(max(start, 0), max(0, duration - span))
        onZoom()
        if was != zoomed { onChange() }
    }

    /// The zoom buttons: by `factor` around the playhead when it is in view, else around the middle.
    func zoomStep(_ factor: Double) {
        let span = duration / zoom
        let at = playhead >= zoomStart && playhead <= zoomStart + span ? playhead : zoomStart + span / 2
        let next = min(max(zoom * factor, 1), max(zoomMax, 1))
        setZoom(next, start: at - (at - zoomStart) * zoom / next)
    }

    func setWheelZoom(_ on: Bool) {
        Settings.store.set(on, forKey: "ExactStudio.wheelZoom")
        onChange()
    }

    /// The selection id of an image's own move ("im") or an image's or a text's own effect ("ie").
    static func childID(_ kind: String, image: String, _ id: String) -> String { "\(kind):\(image):\(id)" }

    private var selectedChild: (kind: String, image: Segment, id: String)? {
        let parts = selected.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "im" || parts[0] == "ie",
              let item = edits.segments.first(where: { $0.id == parts[1] && (parts[0] == "ie" ? $0.isOverlay : $0.kind == "image") }) else { return nil }
        return (parts[0], item, parts[2])
    }
    var selectedImageMove: (image: Segment, move: Move)? {
        guard let c = selectedChild, c.kind == "im", let m = c.image.moves?.first(where: { $0.id == c.id }) else { return nil }
        return (c.image, m)
    }
    /// The selected own effect of an image or a text, with its owner.
    var selectedItemEffect: (item: Segment, effect: Segment)? {
        guard let c = selectedChild, c.kind == "ie", let e = c.image.effects?.first(where: { $0.id == c.id }) else { return nil }
        return (c.image, e)
    }
    /// The image the selection is, or belongs to.
    var selectedImage: Segment? {
        if let s = selectedSegment, s.kind == "image" { return s }
        return selectedChild.flatMap { $0.image.kind == "image" ? $0.image : nil }
    }
    /// The image or text the selection is, or belongs to.
    var selectedItem: Segment? {
        if let s = selectedSegment, s.isOverlay { return s }
        return selectedChild?.image
    }

    /// A new image at the playhead, from a picture file, centred on `at` (the middle of the frame when nil).
    func addImage(_ url: URL, at: CGPoint? = nil) {
        do {
            let file = try Pictures.bring(url, into: folder)
            let t = min(playhead, max(0, duration - 0.3))
            land(Pictures.segment(id: Editor.newID("i"), file: file, in: folder, canvas: framing.canvas, start: t, end: min(duration, t + 4),
                                  x: Double(at?.x ?? 0.5), y: Double(at?.y ?? 0.5)))
        } catch { refuse((error as? Pictures.Refused)?.why ?? "Couldn’t add that picture.") }
    }

    /// Show another picture in the selected image, keeping its place, size, timing, moves and effects.
    func replaceImage(_ url: URL) {
        guard var s = selectedImage else { return }
        do {
            s.file = try Pictures.bring(url, into: folder)
            replace(s)
        } catch { refuse((error as? Pictures.Refused)?.why ?? "Couldn’t use that picture.") }
    }

    /// Set one field of the selected image (or of the image the selected move or effect belongs to).
    func setImage(_ field: String, _ value: String) {
        guard var s = selectedImage else { return }
        let n = Double(value)
        switch field {
        case "size": if let n { s.size = min(max(n / 100, 0.02), 1.5) }
        case "opacity": if let n { s.opacity = min(max(n / 100, 0), 1) }
        case "rotation": if let n { s.rotation = min(max(n, -180), 180) }
        case "radius": if let n { s.radius = min(max(n / 100, 0), 0.5) }
        case "shadow": s.shadow = value == "true"
        case "in": s.animIn = value
        case "out": s.animOut = value
        default: return
        }
        replace(s)
        if field == "in" { sampleSegment(s, part: "in") }
        if field == "out" { sampleSegment(s, part: "out") }
    }

    /// A new effect on the selected image or text at the playhead, on the first of its rows with room, selected.
    /// The + always adds when there is room: off the item it starts at the item's start, and where
    /// that kind already is, in the first free gap of it; the playhead goes there.
    // @ref LLP 0002#where-an-effect-applies — one item only: its own effect, by the per-item rule
    func addItemEffect(_ kind: String) {
        guard var image = selectedItem else { return refuse("Select an image or a text first, then add an effect to it.") }
        guard Segment.ownEffects(image.kind).contains(kind) else { return }
        let all = image.effects ?? [], same = all.filter { $0.kind == kind }
        /// Where the next effect of this kind starts after `t` (or the image's end), or nil when `t` is inside one.
        func until(_ t: Double) -> Double? {
            if same.contains(where: { $0.start < t && $0.end > t }) { return nil }
            return same.filter { $0.start >= t - 0.0001 }.map(\.start).min() ?? image.end
        }
        let here = playhead
        let first = here >= image.start - 0.001 && here < image.end - 0.3 ? here : image.start
        guard let t = ([first, image.start] + same.map(\.end).sorted()).first(where: { $0 >= image.start - 0.001 && (until($0) ?? $0) - $0 >= 0.3 }),
              let after = until(t) else {
            let rule = image.kind == "text" ? "text-one-each" : "image-one-each"
            return refuse(Conflict(rule: rule, item: nil, other: same.first.map { .effect($0, image: image.id) }, Rules.line1(rule),
                                   "Its \(Segment.imageNoun(kind)) leaves no 0.3 s free. Shorten or remove it."))
        }
        if abs(t - here) > 0.001 { seek(source: t) }
        var fx = Segment(id: Editor.newID("x"), kind: kind, start: max(t, image.start), end: min(after, t + 2))
        if kind == "fade" { fx.level = 0.3 }
        while all.contains(where: { $0.lane == fx.lane && $0.overlaps(fx) }) { fx.lane += 1 }
        image.effects = all + [fx]
        replace(image)
        select(Editor.childID("ie", image: image.id, fx.id))
        sample(fx.start, fx.end)
    }

    /// A move on the selected image at the playhead, from where the image is now, selected, ready to be dragged.
    /// Off the image, or at its very start, it lands a little after the start and the playhead goes there.
    func addImageMove() {
        guard var image = selectedImage else { return refuse("Select an image first, then add a move to it.") }
        var t = playhead
        if !(t > image.start + 0.05 && t <= image.end + 0.001) {
            t = image.start + min(1.0, (image.end - image.start) / 2)
            seek(source: t)
        }
        if let m = image.moves?.first(where: { abs($0.t - t) < 0.12 }) { return select(Editor.childID("im", image: image.id, m.id)) }
        let p = framing.imagePose(image, at: t)
        // It travels from the image's start at the earliest.
        let m = Move(id: Editor.newID("m"), t: t, to: Placement(x: p.x, y: p.y, scale: p.scale), style: lastStyle == "zoom" ? "smooth" : lastStyle,
                     duration: max(0.01, min(lastDuration, t - image.start)))
        image.moves = (image.moves ?? []) + [m]
        replace(image)
        select(Editor.childID("im", image: image.id, m.id))
    }

    /// Set one field of the selected image move: "style", "duration" or "scale" (percent of the image's size).
    func setImageMove(_ field: String, _ value: String) {
        guard let (image, move) = selectedImageMove else { return }
        var m = move
        let n = Double(value)
        switch field {
        case "style": m.style = value
        case "duration": if let n { m.duration = min(max(n, 0.05), 10) }
        case "scale": if let n { m.to.scale = min(max(n / 100, 0.1), 8) }
        default: return
        }
        var next = image
        next.moves = image.moves?.map { $0.id == m.id ? m : $0 }
        replace(next)
        if field != "scale" { sample(m.t - m.duration - 0.3, m.t + 0.4) }
    }

    /// Set the selected image's or text's effect's level: a fade's opacity, in percent.
    func setItemEffect(_ field: String, _ value: String) {
        guard let (image, effect) = selectedItemEffect, field == "level", let n = Double(value) else { return }
        var e = effect
        e.level = min(max(n / 100, 0), 1)
        var next = image
        next.effects = image.effects?.map { $0.id == e.id ? e : $0 }
        replace(next)
    }

    /// What a drag or a resize of an image in the preview changes: the move at the playhead (or the
    /// one being made by this drag), a new move there when the image already has moves, else the image's own place.
    private enum ImageTarget { case base, move(Int), new }
    private func imageTarget(_ image: Segment, at t: Double) -> ImageTarget {
        let moves = image.moves ?? []
        if let i = moves.firstIndex(where: { $0.id == "live" }) { return .move(i) }
        if let sel = selectedImageMove, moves.contains(where: { $0.id == sel.move.id }), abs(sel.move.t - t) < 0.2, let i = moves.firstIndex(where: { $0.id == sel.move.id }) { return .move(i) }
        if let i = moves.firstIndex(where: { abs($0.t - t) < 0.12 }) { return .move(i) }
        if moves.isEmpty || t <= (moves.map { $0.t - $0.duration }.min() ?? 0) { return .base }
        return .new
    }

    /// Put an image at (x, y), and scale it by `factor`. `live` draws it without saving (a drag); the drop saves.
    func placeImage(_ id: String, x: Double? = nil, y: Double? = nil, factor: Double = 1, live: Bool) {
        guard let image = edits.segments.first(where: { $0.id == id && $0.kind == "image" }) else { return }
        let t = playhead, now = framing.imagePose(image, at: t)
        let x = min(max(x ?? now.x, 0), 1), y = min(max(y ?? now.y, 0), 1)
        // @ref LLP 0002#split — joined halves of an image share one place and one set of moves
        let run = Joins.run(image, in: edits.segments), whole = Joins.whole(image, run: run)
        var members = run
        func owner(_ move: String) -> Int { members.firstIndex { ($0.moves ?? []).contains { $0.id == move } } ?? 0 }
        func change(_ move: String, _ body: (inout Move) -> Void) {
            let i = owner(move)
            members[i].moves = members[i].moves?.map { var m = $0; if m.id == move { body(&m) }; return m }
        }
        switch imageTarget(whole, at: t) {
        case .base:
            for i in members.indices {
                members[i].x = x; members[i].y = y
                members[i].size = min(max((members[i].size ?? 0.25) * factor, 0.02), 1.5)
            }
        case let .move(i):
            change(whole.moves![i].id) { $0.to = Placement(x: x, y: y, scale: min(max($0.to.scale * factor, 0.1), 8)) }
        case .new:
            let i = members.firstIndex { $0.id == id } ?? 0
            members[i].moves = (members[i].moves ?? []) + [Move(id: "live", t: t, to: Placement(x: x, y: y, scale: min(max(now.scale * factor, 0.1), 8)),
                                                               style: lastStyle == "zoom" ? "smooth" : lastStyle, duration: min(lastDuration, max(0.05, t - whole.start)))]
        }
        var made: (image: String, move: String)?
        if !live, members.contains(where: { ($0.moves ?? []).contains { $0.id == "live" } }) {
            let fresh = Editor.newID("m"), i = owner("live")
            change("live") { $0.id = fresh }
            made = (members[i].id, fresh)
        }
        var next = edits
        next.segments = next.segments.map { s in members.first { $0.id == s.id } ?? s }
        if live { edits = next; redraw() } else {
            apply(next)
            if let made { select(Editor.childID("im", image: made.image, made.move)) }
        }
    }

    /// An image's (or a text's) own moves and effects kept inside its time: an effect is cut to it (and goes when
    /// too little is left), a move lands inside it.
    private static func tidy(_ image: Segment) -> Segment {
        var s = image
        s.effects = s.effects?.compactMap { e in
            var m = e
            m.start = max(e.start, s.start); m.end = min(e.end, s.end)
            return m.end - m.start >= 0.1 ? m : nil
        }
        s.moves = s.moves?.map { var m = $0; m.t = min(max($0.t, s.start), s.end); return m }
        if s.effects?.isEmpty == true { s.effects = nil }
        if s.moves?.isEmpty == true { s.moves = nil }
        return s
    }

    /// Move or resize an image's effect while dragging: drawn at once, checked on drop.
    func dragImageEffect(_ image: String, _ id: String, start: Double, end: Double, lane: Int) {
        if dragOrigin == nil { dragOrigin = edits }
        edits.segments = edits.segments.map { img in
            guard img.id == image else { return img }
            var next = img
            let a = max(img.start, min(start, img.end - 0.1)), b = min(img.end, max(end, a + 0.1))
            next.effects = img.effects?.map { e in
                guard e.id == id else { return e }
                var m = e
                m.start = a; m.end = b; m.lane = max(0, lane)
                return m
            }
            return next
        }
        check(ItemRef(kind: "image-effect", id: id, image: image))
        redraw()
    }

    /// Slide an image's move in time. `live` draws it without saving.
    func dragImageMove(_ image: String, _ id: String, to t: Double, live: Bool) {
        if live, dragOrigin == nil { dragOrigin = edits }
        var next = edits
        next.segments = next.segments.map { img in
            guard img.id == image else { return img }
            var m = img
            m.moves = img.moves?.map { var mv = $0; if mv.id == id { mv.t = min(max(t, img.start), img.end) }; return mv }
            return m
        }
        if live {
            edits = next
            check(ItemRef(kind: "image-move", id: id, image: image))
            redraw()
        } else { finish(next) }
    }

    // MARK: Sounds
    // @ref LLP 0002#sound — the recorded sound follows the cuts; an added sound plays straight through

    /// The selection id of the recorded sound's row.
    static let recordedSound = "sound:clip"
    /// The selection id of an added sound.
    static func soundID(_ id: String) -> String { "snd:" + id }
    var selectedSound: Sound? { edits.sounds.first { Editor.soundID($0.id) == selected } }

    /// A new sound at the playhead from a sound file: the whole file, or what fits before the video
    /// ends, on the first sound lane where it plays alone (a new lane when none has room), selected.
    func addSound(_ url: URL) {
        do {
            let file = try Sounds.bring(url, into: folder)
            let t = min(playhead, max(0, duration - 0.3))
            var n = edits.sounds.count + 1
            while edits.sounds.contains(where: { $0.id == "sound\(n)" }) { n += 1 }
            guard var s = Sounds.make(id: "sound\(n)", file: file, in: folder, start: t, map: map) else {
                return refuse("There’s no room for a sound there. Move the playhead earlier.")
            }
            var next = edits
            s.lane = next.freeLane(for: s, map: map)
            if let want = wantLane, want < next.soundLanes {
                var there = s
                there.lane = want
                if next.conflict(there, map: map) == nil { s.lane = want }
            }
            next.sounds.append(s)
            next.fitLanes()
            reveal(space: Edits.soundSpace)
            if apply(next) { select(Editor.soundID(s.id)) }
        } catch { refuse((error as? Sounds.Refused)?.why ?? "Couldn’t add that sound.") }
    }

    /// Play another file in the selected sound, from its start; its place and settings stay.
    func replaceSound(_ url: URL) {
        guard var s = selectedSound else { return }
        do {
            s.file = try Sounds.bring(url, into: folder)
            let whole = Sounds.length(s.file, in: folder) ?? s.length
            s.offset = 0
            s.length = min(s.length, whole)
            replace(s)
        } catch { refuse((error as? Sounds.Refused)?.why ?? "Couldn’t use that sound.") }
    }

    /// Set one field of the selected sound ("volume" in percent, "fadeIn" or "fadeOut" in seconds),
    /// or of the recorded sound ("volume" in percent, "mute").
    func setSound(_ field: String, _ value: String) {
        let n = Double(value)
        if selected == Editor.recordedSound {
            switch field {
            case "volume": if let n { setVolume(n / 100) }
            case "mute": setVolume(value == "true" ? 0 : 1)
            default: break
            }
            return
        }
        guard var s = selectedSound, let n else { return }
        switch field {
        case "volume": s.volume = min(max(n / 100, 0), 1)
        case "fadeIn": s.fadeIn = min(max(n, 0), 5)
        case "fadeOut": s.fadeOut = min(max(n, 0), 5)
        default: return
        }
        replace(s)
    }

    /// Move a sound, or trim either end, while dragging: drawn at once, checked on drop.
    /// `lane` may be one past the last: the drop opens a new sound lane there.
    func dragSound(_ id: String, start: Double, offset: Double, length: Double, lane: Int) {
        if dragOrigin == nil { dragOrigin = edits }
        edits.sounds = edits.sounds.map {
            guard $0.id == id else { return $0 }
            var m = $0
            m.start = min(max(start, 0), duration - 0.1)
            m.offset = max(0, offset)
            m.length = max(0.1, length)
            m.lane = max(0, lane)
            return m
        }
        check(ItemRef(kind: "sound", id: id))
        redrawViews()
    }

    private func replace(_ s: Sound) {
        var next = edits
        next.sounds = next.sounds.map { $0.id == s.id ? s : $0 }
        apply(next)
    }

    /// A new empty lane in a space (`Segment.space`): 0 for the video's effects, 1 for texts, 2 for images, 3 for whole-frame effects.
    func addLane(space: Int = 0) {
        var next = edits
        switch space {
        case 1: next.textLanes += 1
        case 2: next.imageLanes += 1
        case 3: next.frameLanes += 1
        case Edits.soundSpace: next.soundLanes += 1
        default: next.lanes += 1
        }
        reveal(space: space)
        apply(next)
    }

    // @ref LLP 0005#the-lane-menu
    private static func setLaneCount(_ e: inout Edits, space: Int, _ n: Int) {
        switch space {
        case 1: e.textLanes = n
        case 2: e.imageLanes = n
        case 3: e.frameLanes = n
        case Edits.soundSpace: e.soundLanes = n
        default: e.lanes = n
        }
    }

    private static func relane(_ e: inout Edits, space: Int, _ map: (Int) -> Int?) {
        e.segments = e.segments.compactMap { s in
            guard s.space == space else { return s }
            guard let l = map(s.lane) else { return nil }
            var t = s; t.lane = l; return t
        }
        if space == Edits.soundSpace {
            e.sounds = e.sounds.compactMap { s in
                guard let l = map(s.lane) else { return nil }
                var t = s; t.lane = l; return t
            }
        }
    }

    private func relaneOpen(space: Int, _ map: (Int) -> Int?) {
        if space == 1 { openTextLanes = Set(openTextLanes.compactMap(map)) }
        else if space == 2 { openImageLanes = Set(openImageLanes.compactMap(map)) }
        else { return }
        redrawViews()
    }

    func insertLane(space: Int, at index: Int) {
        let count = edits.laneCount(space: space)
        let at = min(max(index, 0), count)
        var next = edits
        Editor.setLaneCount(&next, space: space, count + 1)
        let shift = { (l: Int) -> Int? in l >= at ? l + 1 : l }
        Editor.relane(&next, space: space, shift)
        reveal(space: space)
        if named("New \(TimelineMenus.kindName(space)) Lane", { apply(next) }) { relaneOpen(space: space, shift) }
    }

    func moveLane(_ lane: Int, space: Int, by step: Int) {
        let other = lane + step
        guard lane >= 0, other >= 0, lane < edits.laneCount(space: space), other < edits.laneCount(space: space), lane != other else { return }
        var next = edits
        let swap = { (l: Int) -> Int? in l == lane ? other : l == other ? lane : l }
        Editor.relane(&next, space: space, swap)
        if named(step < 0 ? "Move Lane Up" : "Move Lane Down", { apply(next) }) { relaneOpen(space: space, swap) }
    }

    func laneItems(_ lane: Int, space: Int) -> Int {
        space == Edits.soundSpace ? edits.sounds.filter { $0.lane == lane }.count
            : edits.segments.filter { $0.space == space && $0.lane == lane }.count
    }

    func deleteLane(_ lane: Int, space: Int) {
        let count = edits.laneCount(space: space)
        guard lane >= 0, lane < count, space != 0 || count > 1 else { return }
        var next = edits
        Editor.setLaneCount(&next, space: space, count - 1)
        let drop = { (l: Int) -> Int? in l == lane ? nil : l > lane ? l - 1 : l }
        Editor.relane(&next, space: space, drop)
        if named("Delete Lane", { apply(next) }) {
            relaneOpen(space: space, drop)
            dropGoneSelection()
            notify()
        }
    }

    /// Set the selected segment's value: a zoom's level, a speed's rate, or (for
    /// a visual effect) another visual kind.
    func setValue(number: Double?, kind: String?) {
        guard var s = selectedSegment else { return }
        let was = s.space
        if s.kind == "zoom", let n = number { s.level = n }
        if s.kind == "speed", let n = number { s.rate = n }
        if Segment.visual.contains(s.kind), let k = kind, Segment.visual.contains(k) {
            s.kind = k
            // Spotlight and cursor highlight follow the cursor on the video: they have no reach.
            if k != "blur" && k != "mono" { s.scope = nil }
        }
        s.space != was ? relaneTo(s) : replace(s)
        sampleSegment(s, part: "in")
    }

    /// Put `s` on the first free lane of its space, as when its reach takes it to the other lanes.
    private func relaneTo(_ segment: Segment) {
        var s = segment
        var next = edits
        next.segments.removeAll { $0.id == s.id }
        s.lane = next.freeLane(for: s)
        next.segments.append(s)
        next.fitLanes()
        apply(next)
    }

    /// Set one field of the selected text, or ("add-effect") give it an effect of its own.
    func setText(_ field: String, _ value: String) {
        if field == "add-effect" { return addItemEffect(value) }
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

    // @ref LLP 0002#depth
    func arrange(_ step: String) {
        guard let item = selectedSegment.flatMap({ $0.isOverlay ? $0 : nil }), let name = Edits.arrangeName(step) else { return }
        if let why = edits.arrangeProblem(item.id, step) { return refuse(why) }
        guard let next = edits.arranged(item.id, step) else { return }
        named(name) { apply(next) }
    }

    private func replace(_ s: Segment) {
        var next = edits
        next.segments = next.segments.map { $0.id == s.id ? s : $0 }
        apply(next)
    }

    static func stamp(_ s: Double) -> String { (s < 0 ? "-" : "") + String(format: "%d:%05.2f", Int(abs(s)) / 60, abs(s).truncatingRemainder(dividingBy: 60)) }

    private(set) var typed: (field: String, conflict: Conflict)?

    // @ref LLP 0005#refusals — a typed time that clashes says why under its field before Return
    func checkTime(_ field: String, _ t: Double?) {
        let was = typed?.conflict
        if let t, field == "start" || field == "end" {
            typed = probe { field == "start" ? setTimes(start: t, end: nil) : setTimes(start: nil, end: t) }.map { (field, $0) }
        } else {
            typed = nil
        }
        if typed?.conflict != was { notify() }
    }

    /// Typed times for the selection: an effect's span, a clip part's edges
    /// (which move the splits beside it), or a move's arrival.
    func setTimes(start: Double?, end: Double?) {
        if !probing { typed = nil }
        if var s = selectedSound {
            // Start moves it; End sets how long it plays, up to the end of its file.
            if let a = start {
                guard a >= 0, a < duration - 0.1 else { return refuse("A sound must start inside 0:00–\(Editor.stamp(duration)).") }
                s.start = a
            }
            if let b = end {
                let length = map.output(b) - map.output(s.start)
                guard length >= 0.1 else { return refuse("End must come at least 0.1 s of video after the start.") }
                s.length = min(length, (Sounds.length(s.file, in: folder) ?? length) - s.offset)
            }
            replace(s)
        } else if let (image, effect) = selectedItemEffect {
            let a = start ?? effect.start, b = end ?? effect.end
            guard a >= image.start - 0.001, b <= image.end + 0.001, b - a >= 0.1 else {
                let noun = image.kind == "text" ? "A text’s effect must stay inside the text" : "An image’s effect must stay inside the image"
                return refuse("\(noun), \(Editor.stamp(image.start))–\(Editor.stamp(image.end)), and last at least 0.1 s.")
            }
            var next = image
            next.effects = image.effects?.map { var e = $0; if e.id == effect.id { e.start = a; e.end = b }; return e }
            replace(next)
        } else if let (image, move) = selectedImageMove {
            guard let a = start ?? end, a >= image.start, a <= image.end else {
                return refuse("An image’s move must land inside the image, \(Editor.stamp(image.start))–\(Editor.stamp(image.end)).")
            }
            dragImageMove(image.id, move.id, to: a, live: false)
        } else if var s = selectedSegment {
            let a = start ?? s.start, b = end ?? s.end
            guard a >= 0, b <= duration + 0.001, b - a >= 0.1 else {
                return refuse(Rules.minLength(.of(s), duration: duration))
            }
            s.start = a; s.end = min(b, duration)
            replace(s.isOverlay ? Editor.tidy(s) : s)
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
        // The recorded sound is part of the clip: it is muted, not removed.
        guard !selected.isEmpty, selected != Editor.recordedSound else { return }
        var next = edits
        if let c = selectedChild {
            // An image's (or a text's) own move or effect goes; the item stays, selected.
            var image = c.image
            image.moves = image.moves?.filter { c.kind != "im" || $0.id != c.id }
            image.effects = image.effects?.filter { c.kind != "ie" || $0.id != c.id }
            next.segments = next.segments.map { $0.id == image.id ? Editor.tidy(image) : $0 }
            apply(next)
            select(image.id)
            return
        }
        next.segments.removeAll { $0.id == selected }
        next.moves.removeAll { "m:" + $0.id == selected }
        next.sounds.removeAll { Editor.soundID($0.id) == selected }
        apply(next)
        select("")
    }

    // @ref LLP 0002#split
    private enum SplitTarget { case clip, segment(Segment), imageEffect(Segment, Segment), sound(Sound) }

    private var splitTarget: SplitTarget {
        if let s = selectedSegment { return .segment(s) }
        if let (image, fx) = selectedItemEffect { return .imageEffect(image, fx) }
        if let s = selectedSound { return .sound(s) }
        return .clip
    }

    var splitLabel: String {
        switch splitTarget {
        case .clip: return "Split Clip"
        case let .segment(s): return "Split " + History.kindName(s.kind)
        case let .imageEffect(item, _): return item.kind == "text" ? "Split Text Effect" : "Split Image Effect"
        case .sound: return "Split Sound"
        }
    }

    private func splitting(at t: Double) -> Result<(Edits, String?), SplitRefused> {
        var next = edits
        do {
            let made: String?
            switch splitTarget {
            case .clip: try next.splitClip(at: t, duration: duration); made = nil
            case let .segment(s): made = try next.splitSegment(s.id, at: t)
            case let .imageEffect(image, fx): made = Editor.childID("ie", image: image.id, try next.splitImageEffect(image: image.id, effect: fx.id, at: t))
            case let .sound(s): made = Editor.soundID(try next.splitSound(s.id, at: t, map: map))
            }
            return .success((next, made))
        } catch { return .failure(error as? SplitRefused ?? SplitRefused(why: "")) }
    }

    var splitProblem: String {
        if case let .failure(why) = splitting(at: playhead) { return why.why }
        return ""
    }

    var splitAllProblem: String {
        var next = edits
        do { try next.splitAll(at: playhead, duration: duration, map: map); return "" } catch { return (error as? SplitRefused)?.why ?? "" }
    }

    func split() {
        if case .clip = splitTarget { return splitClip() }
        switch splitting(at: playhead) {
        case let .failure(why): refuse(why.why)
        case let .success((next, made)):
            let landed = named(splitLabel) { apply(next) }
            if landed, let made { select(made) }
        }
    }

    func splitAll() {
        var next = edits
        do { try next.splitAll(at: playhead, duration: duration, map: map) } catch { return refuse((error as? SplitRefused)?.why ?? "") }
        named("Split All Lanes") { apply(next) }
    }

    func autoZoom() {
        var next = edits
        next.segments.removeAll { $0.kind == "zoom" }
        var zooms = Edits.autoZooms(meta.clicks, duration: meta.duration)
        var lane = 0
        while zooms.contains(where: { z in next.segments.contains { $0.space == 0 && $0.lane == lane && $0.overlaps(z) } }) { lane += 1 }
        zooms = zooms.map { var z = $0; z.lane = lane; return z }
        next.lanes = max(next.lanes, lane + 1)
        next.segments += zooms
        apply(next)
        select("")
    }

    /// Set one field of the selected segment: a blur's or black and white's "scope", a 3D
    /// turn's "pose" (a named pose), "tilt", "turn", "roll" or "style" ("hold" or "orbit"), or a
    /// mask's "style" ("blur", "pixels" or "solid") or "color" ("#RRGGBB").
    func setSegment(_ field: String, _ value: String) {
        guard var s = selectedSegment else { return }
        let n = Double(value)
        switch field {
        case "scope":
            // Between the video's lanes and the whole-frame lanes: it lands on the first free one there.
            // @ref LLP 0002#where-an-effect-applies
            guard s.kind == "blur" || s.kind == "mono", Segment.scopes.contains(value) else { return }
            let was = s.space
            s.scope = value == "video" ? nil : value
            if s.space != was { return relaneTo(s) }
        case "pose": let a = Editor.pose(value); s.tilt = a.tilt; s.turn = a.turn; s.roll = a.roll
        case "tilt": if let n { s.tilt = min(max(n, -80), 80) }
        case "turn": if let n { s.turn = min(max(n, -80), 80) }
        case "roll": if let n { s.roll = min(max(n, -45), 45) }
        case "style":
            if s.kind == "mask" && !Segment.maskStyles.contains(value) { return }
            s.style = value
            if s.kind == "mask", value == "solid", s.color == nil { s.color = "#000000" }
        case "color":
            guard s.kind == "mask", Segment.maskHex(value) != nil else { return }
            s.color = Segment.maskHex(value)
        default: return
        }
        replace(s)
        if s.kind == "3d", field == "pose" || field == "style" { sampleSegment(s, part: "loop") }
    }

    // MARK: Templates

    func applyTemplate(_ name: String) {
        guard let info = Templates.info(name) else { return }
        guard let made = Templates.make(name, map: map, meta: meta, look: look, keep: Templates.kept(edits)) else {
            return refuse(Templates.refusal(info, duration: map.outputDuration))
        }
        let next = Templates.apply(made, to: edits)
        named("Template") { apply(next) }
        select(next.texts.sorted { $0.start < $1.start }.first(where: \.isPlaceholder)?.id ?? "")
    }

    func clearAll() {
        named("Clear Edits") { apply(Edits()) }
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
            if apply(next) { select("m:" + m.id) } else { redraw() }
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
        reveal(space: 0)
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

    // MARK: Texts, images and moves dragged in the preview

    /// Put a mask's rectangle at `rect` (full-frame units), kept inside the frame and at least 0.5% on each
    /// side. `live` draws it without saving (a drag); the drop saves.
    // @ref LLP 0006#follows-the-video — the rect is in the full recorded frame's units
    func setMaskRect(_ id: String, _ rect: UnitRect, live: Bool) {
        let m = 0.005
        var u = rect
        u.w = min(max(u.w, m), 1); u.h = min(max(u.h, m), 1)
        u.x = min(max(u.x, 0), 1 - u.w); u.y = min(max(u.y, 0), 1 - u.h)
        var next = edits
        next.segments = next.segments.map { var s = $0; if s.id == id, s.kind == "mask" { s.rect = u }; return s }
        if live { edits = next; redraw() } else { apply(next) }
    }

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
        if live, dragOrigin == nil { dragOrigin = edits }
        var next = edits
        next.moves = next.moves.map { $0.id == id ? Move(id: $0.id, t: min(max(t, 0), duration), to: $0.to, style: $0.style, duration: $0.duration, angles: $0.angles) : $0 }
        if live {
            edits = next
            check(ItemRef(kind: "move", id: id))
            redraw()
        } else { finish(next) }
    }

    // MARK: Dragging (the timeline's)

    private var dragOrigin: Edits?
    var dragFrom: Edits? { dragOrigin }

    /// Move or resize a segment while dragging: drawn at once, checked on drop.
    /// `lane` may be one past the last: the drop opens a new lane there.
    func drag(_ id: String, start: Double, end: Double, lane: Int) {
        if dragOrigin == nil { dragOrigin = edits }
        let s = max(0, min(start, duration - 0.1)), e = min(duration, max(end, s + 0.1))
        edits.segments = edits.segments.map {
            guard $0.id == id else { return $0 }
            var m = $0
            if m.isOverlay {
                // Moved as a whole, its own moves and effects come along.
                let by = s - m.start
                if abs((e - s) - (m.end - m.start)) < 0.0005, abs(by) > 0 {
                    m.moves = m.moves?.map { var mv = $0; mv.t += by; return mv }
                    m.effects = m.effects?.map { var fx = $0; fx.start += by; fx.end += by; return fx }
                }
            }
            m.lane = max(0, lane)
            m.start = s; m.end = e
            return m
        }
        check(ItemRef(kind: edits.segments.first { $0.id == id }?.kind ?? "", id: id))
        // An image's children move in the picture too; the rest only in the timeline.
        selectedSegment?.isOverlay == true ? redraw() : redrawViews()
    }

    struct DragCheck: Equatable {
        var item: ItemRef
        var conflict: Conflict?
        var landing: Int?
    }
    private(set) var dragCheck: DragCheck?

    private func dropped() -> Edits {
        var moved = edits
        guard let origin = dragOrigin else { return moved }
        moved.segments = moved.segments.map { $0.isOverlay ? Editor.tidy($0) : $0 }
        moved.lanes = origin.lanes; moved.textLanes = origin.textLanes; moved.imageLanes = origin.imageLanes
        moved.frameLanes = origin.frameLanes; moved.soundLanes = origin.soundLanes
        moved.fitLanes()
        return moved
    }

    // @ref LLP 0005#refusals — the check runs on every drag step, not only on the drop
    private func check(_ ref: ItemRef) {
        let next = settle(dropped())
        let conflict = Editor.newConflict(next, since: baseline, duration: duration)
        func lane(_ e: Edits) -> Int? {
            switch ref.kind {
            case "sound": return e.sounds.first { $0.id == ref.id }?.lane
            case "image-effect": return e.segments.first { $0.id == ref.image }?.effects?.first { $0.id == ref.id }?.lane
            case "move", "image-move": return nil
            default: return e.segments.first { $0.id == ref.id }?.lane
            }
        }
        let landing = conflict == nil && lane(next) != lane(edits) ? lane(next) : nil
        dragCheck = DragCheck(item: ref, conflict: conflict, landing: landing)
    }

    /// The drop: keep the move if it fits (on the first free lane when its own is taken), else put it back.
    @discardableResult
    func endDrag() -> Bool {
        guard dragOrigin != nil else { return true }
        return finish(dropped())
    }

    @discardableResult
    private func finish(_ next: Edits) -> Bool {
        let origin = dragOrigin
        dragOrigin = nil
        dragCheck = nil
        if let origin { edits = origin }
        guard apply(next) else { redraw(); return false }
        // An image dropped on another lane opens that lane, as selecting it does.
        if let item = selectedItem, !isOpen(space: item.space, lane: item.lane) { open(item); redrawViews() }
        return true
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

    /// The window's own corner radius, from a frame's alpha.
    func measureWindow() {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600), actualTime: nil),
              let r = Bezel.windowRadius(image) else { return }
        var m = meta
        m.cornerRadius = r
        setMeta(m)
    }

    func forgetDevice() {
        var m = meta
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
                                  "moveStyle": "", "duration": 0, "scale": 0, "tilt": 0, "turn": 0, "roll": 0, "hasAngles": false, "scope": "video", "problem": blocked ?? (problem.isEmpty ? standingProblem : problem),
                                  "startWhy": typed?.field == "start" ? typed!.conflict.text : "", "endWhy": typed?.field == "end" ? typed!.conflict.text : "",
                                  "file": "", "opacity": 100, "radius": 0, "shadow": false, "fx": "",
                                  "volume": 100, "fadeIn": 0, "fadeOut": 0,
                                  "layer": "", "canForward": false, "canBackward": false, "canFront": false, "canBack": false]
        if selected == Editor.recordedSound {
            out.merge(["id": selected, "kind": "recorded", "volume": (edits.volume * 100).rounded()]) { $1 }
        } else if let s = selectedSound {
            let end = s.end(map)
            out.merge(["id": selected, "kind": "sound", "start": s.start, "end": end, "startText": Editor.stamp(s.start), "endText": Editor.stamp(end),
                       "file": URL(fileURLWithPath: s.file).lastPathComponent, "volume": (s.volume * 100).rounded(),
                       "fadeIn": (s.fadeIn * 10).rounded() / 10, "fadeOut": (s.fadeOut * 10).rounded() / 10]) { $1 }
        } else if let s = selectedSegment {
            out.merge(["scope": s.scope ?? "video", "tilt": (s.tilt ?? 0).rounded(), "turn": (s.turn ?? 0).rounded(), "roll": (s.roll ?? 0).rounded()]) { $1 }
            out.merge(["id": s.id, "kind": s.kind, "level": s.level ?? 0, "rate": s.rate ?? 0, "start": s.start, "end": s.end,
                       "startText": Editor.stamp(s.start), "endText": Editor.stamp(s.end), "text": s.text ?? "",
                       "size": ((s.size ?? 0) * 1000).rounded() / 10, "color": s.color ?? "", "weight": s.weight ?? "", "style": s.style ?? "",
                       "animIn": Editor.shown(s.animIn, s.kind == "image" ? Editor.imageIns : Editor.textIns, or: s.kind == "image" ? "fade" : "pop"),
                       "animOut": Editor.shown(s.animOut, s.kind == "image" ? Editor.imageOuts : Editor.textOuts, or: "fade"),
                       "loop": Editor.shown(s.loop, Editor.loops, or: "none"), "rotation": s.rotation ?? 0]) { $1 }
            if s.kind == "mask" {
                out.merge(["style": s.style ?? "blur", "color": Segment.maskHex(s.color) ?? "#000000"]) { $1 }
            }
            if s.isOverlay {
                let can = { (step: String) in self.edits.arrangeProblem(s.id, step) == nil }
                out.merge(["layer": s.isBehind ? "behind" : "front", "canForward": can("forward"), "canBackward": can("backward"),
                           "canFront": can("front"), "canBack": can("back")]) { $1 }
            }
            if s.kind == "image" {
                out.merge(["file": URL(fileURLWithPath: s.file ?? "").lastPathComponent, "opacity": ((s.opacity ?? 1) * 100).rounded(),
                           "size": ((s.size ?? 0.25) * 1000).rounded() / 10, "radius": ((s.radius ?? 0) * 100).rounded(), "shadow": s.shadow ?? false]) { $1 }
            }
        } else if let (image, m) = selectedImageMove {
            out.merge(["id": selected, "kind": "imove", "start": m.t, "end": m.t, "startText": Editor.stamp(m.t), "endText": Editor.stamp(m.t),
                       "moveStyle": m.style, "duration": m.duration, "scale": (m.to.scale * 100).rounded(),
                       "file": URL(fileURLWithPath: image.file ?? "").lastPathComponent]) { $1 }
        } else if let (item, e) = selectedItemEffect {
            out.merge(["id": selected, "kind": "ifx", "fx": e.kind, "start": e.start, "end": e.end, "startText": Editor.stamp(e.start),
                       "endText": Editor.stamp(e.end), "level": ((e.level ?? 0.3) * 100).rounded(),
                       "file": item.kind == "text" ? "“\(item.text ?? "")”" : URL(fileURLWithPath: item.file ?? "").lastPathComponent,
                       "text": item.kind == "text" ? (item.text ?? "") : ""]) { $1 }
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

    static let textIns = ["letters", "letters-pop", "drop", "typewriter", "pop", "spin", "slide", "rise", "blur", "fade", "none"]
    static let textOuts = ["fade", "fall", "letters", "pop", "sink", "blur", "none"]
    static let imageIns = ["pop", "fade", "rise", "slide", "spin", "blur", "none"]
    static let imageOuts = ["fade", "pop", "sink", "blur", "none"]
    static let loops = ["none", "wave", "pulse", "float", "wiggle"]

    static func shown(_ value: String?, _ known: [String], or fallback: String) -> String {
        guard let value else { return fallback }
        return known.contains(value) ? value : "none"
    }

    var summary: [String: Any] {
        let parts = pieces
        return ["parts": parts.count, "removed": parts.filter(\.removed).count, "effects": edits.segments.count, "lanes": edits.lanes + edits.textLanes + edits.imageLanes + edits.frameLanes, "images": edits.images.count,
                "moves": edits.moves.count, "length": map.outputDuration, "source": duration, "playing": isPlaying,
                "device": meta.isDevice, "found": meta.device == true, "cursorDrawn": meta.drawsCursor,
                "baseScale": (edits.base.scale * 100).rounded(), "undoName": undoName, "redoName": redoName,
                "threeOn": edits.three.on,
                // The angle the 3D controls edit: the move's in effect at the playhead, else the base.
                "tilt": angleTarget.tilt.rounded(), "turn": angleTarget.turn.rounded(), "roll": angleTarget.roll.rounded(),
                "angleMove": (selectedMove ?? angleMove).map { Editor.stamp($0.t) } ?? "",
                "thickness": (edits.three.thickness * 1000).rounded() / 10, "edge": edits.three.edge,
                "zoomed": zoomed, "wheelZoom": wheelZoom,
                "splitLabel": splitLabel, "canSplit": splitProblem.isEmpty, "splitWhy": splitProblem,
                "canSplitAll": splitAllProblem.isEmpty, "splitAllWhy": splitAllProblem]
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
         "blur": "a blur", "mono": "a black-and-white effect", "text": "a text", "image": "an image", "mask": "a mask"][kind] ?? "an effect"
    }
}

struct Snapshot: Equatable {
    var edits: Edits
    var look: Look
    var crop: UnitRect
    var cornerRadius: Double?
    var device: Bool?
    var mask: String?
    var maskRect: UnitRect?

    func sameMeta(_ o: Snapshot) -> Bool {
        o.crop == crop && o.cornerRadius == cornerRadius && o.device == device && o.mask == mask && o.maskRect == maskRect
    }
}

struct HistoryStep {
    let before: Snapshot
    var after: Snapshot
    var name: String
    let key: String?
    var at: Date
}

enum History {
    static let limit = 200
    // @ref LLP 0002#undo — a slider scrub or a run of scrolls is one step
    static let gather = 1.0

    static func fields<T: Encodable>(_ a: T, _ b: T) -> [String] {
        guard let x = dictionary(a), let y = dictionary(b) else { return [] }
        return Set(x.keys).union(y.keys).filter { !equal(x[$0], y[$0]) }.sorted()
    }

    private static func dictionary<T: Encodable>(_ v: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }

    private static func changed<T: Encodable>(_ before: [T], _ after: [T], id: (T) -> String) -> (added: [T], removed: [T], changed: [(T, T)]) {
        let old = Dictionary(before.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let added = after.filter { old[id($0)] == nil }
        let removed = before.filter { new[id($0)] == nil }
        let changed = after.compactMap { a -> (T, T)? in
            guard let b = old[id(a)], !fields(b, a).isEmpty else { return nil }
            return (b, a)
        }
        return (added, removed, changed)
    }

    private static let timeFields: Set<String> = ["start", "end", "lane", "t", "length", "offset"]

    static func key(_ a: Snapshot, _ b: Snapshot) -> String? {
        let meta = a.sameMeta(b)
        let look = fields(a.look, b.look)
        let edits = fields(a.edits, b.edits)
        if !meta { return nil }
        if edits.isEmpty { return look.isEmpty ? nil : "look:" + look.joined(separator: ",") }
        guard look.isEmpty, edits.count == 1, let top = edits.first else { return nil }
        switch top {
        case "base": return "base:" + fields(a.edits.base, b.edits.base).joined(separator: ",")
        case "three": return "three:" + fields(a.edits.three, b.edits.three).joined(separator: ",")
        case "volume": return "volume"
        case "segments":
            let c = changed(a.edits.segments, b.edits.segments, id: \.id)
            guard c.added.isEmpty, c.removed.isEmpty, c.changed.count == 1, let (x, y) = c.changed.first else { return nil }
            let f = fields(x, y)
            return f.contains(where: timeFields.contains) || f.contains("moves") || f.contains("effects") ? nil : "seg:\(y.id):" + f.joined(separator: ",")
        case "moves":
            let c = changed(a.edits.moves, b.edits.moves, id: \.id)
            guard c.added.isEmpty, c.removed.isEmpty, c.changed.count == 1, let (x, y) = c.changed.first else { return nil }
            let f = fields(x, y)
            return f.contains(where: timeFields.contains) ? nil : "move:\(y.id):" + f.joined(separator: ",")
        case "sounds":
            let c = changed(a.edits.sounds, b.edits.sounds, id: \.id)
            guard c.added.isEmpty, c.removed.isEmpty, c.changed.count == 1, let (x, y) = c.changed.first else { return nil }
            let f = fields(x, y)
            return f.contains(where: timeFields.contains) ? nil : "sound:\(y.id):" + f.joined(separator: ",")
        default: return nil
        }
    }

    static func kindName(_ kind: String) -> String {
        ["zoom": "Zoom", "speed": "Speed Change", "spotlight": "Spotlight", "highlight": "Cursor Highlight", "blur": "Blur",
         "mono": "Black & White", "text": "Text", "image": "Image", "mask": "Mask", "3d": "3D Turn"][kind] ?? "Effect"
    }

    private static let lookNames = ["background": "Background", "customA": "Background", "customB": "Background", "customAngle": "Background",
                                    "customRadial": "Background", "aspect": "Frame Shape", "padding": "Padding", "radius": "Corners",
                                    "shadow": "Shadow", "cursor": "Cursor", "cursorSize": "Cursor Size", "clickEffect": "Squeeze on Click",
                                    "smoothCursor": "Smooth Movement"]

    static func name(_ a: Snapshot, _ b: Snapshot) -> String {
        if !a.sameMeta(b) {
            if a.device != b.device || a.mask != b.mask { return b.device == true ? "Find Device" : "Not a Device" }
            return "Crop"
        }
        let look = Set(fields(a.look, b.look).map { lookNames[$0] ?? "Look" })
        let edits = fields(a.edits, b.edits)
        if edits.isEmpty { return look.count == 1 ? look.first! : "Look" }
        if !look.isEmpty { return "Edit" }
        let e = Set(edits)
        if e.contains("splits") {
            return b.edits.splits.count > a.edits.splits.count ? "Split Clip" : "Join Parts"
        }
        if e == ["removed"] { return b.edits.removed.count > a.edits.removed.count ? "Remove Part" : "Restore Part" }
        if e == ["transitions"] { return "Transition" }
        if e.isSubset(of: ["segments", "lanes", "textLanes", "imageLanes", "frameLanes"]) {
            let c = changed(a.edits.segments, b.edits.segments, id: \.id)
            if c.added.count == 1, c.removed.isEmpty, c.changed.count == 1, c.changed[0].1.kind == c.added[0].kind { return "Split " + kindName(c.added[0].kind) }
            if c.added.count == 1, c.removed.isEmpty { return "Add " + kindName(c.added[0].kind) }
            if c.removed.count == 1, c.added.isEmpty { return "Remove " + kindName(c.removed[0].kind) }
            if c.added.isEmpty, c.removed.isEmpty, c.changed.count == 1 {
                let (x, y) = c.changed[0]
                return segmentName(x, y)
            }
            if c.added.isEmpty, c.removed.isEmpty, c.changed.isEmpty { return b.edits.lanes + b.edits.textLanes + b.edits.imageLanes + b.edits.frameLanes > a.edits.lanes + a.edits.textLanes + a.edits.imageLanes + a.edits.frameLanes ? "Add Lane" : "Remove Lane" }
            return "Edit"
        }
        if e == ["moves"] || e == ["moves", "three"] {
            let c = changed(a.edits.moves, b.edits.moves, id: \.id)
            if c.added.count >= 1, c.removed.isEmpty { return c.added.count == 1 ? "Add Move" : "Add Moves" }
            if c.removed.count == 1, c.added.isEmpty { return "Remove Move" }
            if c.added.isEmpty, c.removed.isEmpty, c.changed.count == 1 {
                let f = fields(c.changed[0].0, c.changed[0].1)
                return f == ["t"] ? "Move Move" : f.contains("angles") ? "3D Angle" : "Edit Move"
            }
            return "Edit Moves"
        }
        if e == ["base"] { return "Placement" }
        if e == ["three"] { return "3D" }
        if e == ["volume"] { return "Volume" }
        if e.isSubset(of: ["sounds", "soundLanes"]) {
            let c = changed(a.edits.sounds, b.edits.sounds, id: \.id)
            if c.added.count == 1, c.removed.isEmpty { return "Add Sound" }
            if c.removed.count == 1, c.added.isEmpty { return "Remove Sound" }
            if c.changed.count == 1, c.added.isEmpty, c.removed.isEmpty {
                let f = fields(c.changed[0].0, c.changed[0].1)
                return f.contains("file") ? "Replace Sound" : f.allSatisfy(timeFields.contains) ? "Move Sound" : "Edit Sound"
            }
        }
        return "Edit"
    }

    private static func segmentName(_ x: Segment, _ y: Segment) -> String {
        let f = fields(x, y)
        let kind = kindName(y.kind)
        if f.contains("effects") {
            let n = (y.effects?.count ?? 0) - (x.effects?.count ?? 0)
            let owner = y.kind == "text" ? "Text" : "Image"
            return n > 0 ? "Add \(owner) Effect" : n < 0 ? "Remove \(owner) Effect" : "Edit \(owner) Effect"
        }
        if f.contains("moves") && !f.contains("start") {
            let n = (y.moves?.count ?? 0) - (x.moves?.count ?? 0)
            return n > 0 ? "Add Image Move" : n < 0 ? "Remove Image Move" : "Edit Image Move"
        }
        if f.contains("start") || f.contains("end") || f.contains("lane") {
            return abs((y.end - y.start) - (x.end - x.start)) > 0.0005 ? "Resize " + kind : "Move " + kind
        }
        if f.allSatisfy({ ["x", "y", "rect"].contains($0) }) { return "Move " + kind }
        if f == ["file"] { return "Replace " + kind }
        return "Edit " + kind
    }
}

// @ref LLP 0005#show-what-moves
extension Editor {
    func setLanding(_ id: String, image: String? = nil, x: Double, y: Double, live: Bool) {
        let x = min(max(x, 0), 1), y = min(max(y, 0), 1)
        var next = edits
        if let image {
            next.segments = next.segments.map { s in
                guard s.id == image, s.kind == "image" else { return s }
                var s = s
                s.moves = s.moves?.map { $0.id == id ? Move(id: $0.id, t: $0.t, to: Placement(x: x, y: y, scale: $0.to.scale), style: $0.style, duration: $0.duration, angles: $0.angles) : $0 }
                return s
            }
        } else {
            next.moves = next.moves.map { $0.id == id ? Move(id: $0.id, t: $0.t, to: Placement(x: x, y: y, scale: $0.to.scale), style: $0.style, duration: $0.duration, angles: $0.angles) : $0 }
        }
        if live { edits = next; redraw(); return }
        named("Move Landing") { apply(next) }
    }
}
#endif
