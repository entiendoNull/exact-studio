// `<studio-timeline clip=…>`: the recording's timeline, in source time.
// A ruler, the Clip (a filmstrip with its cuts hatched over it, and its recorded sound as a
// band along its bottom), then rows in a fixed kind order, each only while it holds something:
// Moves, Effects, Text, Images, Music & Sound. A second row of a kind appears while two of its
// items overlap. An image lane opens to show one of its images' own Moves and Effects rows, a
// text lane one text's Effects rows. Click to seek, click a block to select it, drag it to move
// it (to another lane of its kind too: below the last opens a new one), drag an edge to resize;
// Delete removes the selection, Space plays, the arrow keys step a frame (Shift: a second).
// @ref LLP 0002#rows — what each row holds, and why rows come from use
#if os(macOS)
import AppKit
import AVFoundation

final class TimelineView: NSView {
    weak var editor: Editor?
    var onHeight: (CGFloat) -> Void = { _ in }
    /// The filmstrip's thumbnails, by level (the clip cut into 2^level equal steps) and step; see `drawFilm`.
    private struct Thumb: Hashable { let level: Int, index: Int }
    private var film: [Thumb: CGImage] = [:]
    private var filmUsed: [Thumb: Int] = [:]
    private var filmTick = 0
    private var filmPending: Set<Thumb> = []
    private var filmWanted: Set<Thumb> = []
    private var filmFor = ""
    private var generators: [Int: AVAssetImageGenerator] = [:]
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var lastHeight: CGFloat = 0

    private enum Drag {
        case scrub, move(String, Double, Double, Double), left(String, Double, Double, Int), right(String, Double, Double, Int), retime(String, Double)
        /// An image's effect: the image, the effect, 0 to move it or -1/1 for an edge, its span and lane, and where it was grabbed.
        case fx(String, String, Int, Double, Double, Int, Double)
        /// An image's move: the image, the move, and the grab's offset from where it lands.
        case imove(String, String, Double)
        /// An added sound: the sound, 0 to move it or -1/1 for an edge, its start, offset, length and lane, and where it was grabbed.
        case sound(String, Int, Double, Double, Double, Int, Double)
        /// The slim bar under the track while zoomed: where in it it was grabbed.
        case pan(CGFloat)
    }
    private var drag: Drag?
    private var moved = false

    // Geometry, top-down (the view is flipped).
    private static let labelWidth: CGFloat = 184, pad: CGFloat = 14
    private static let rulerTop: CGFloat = 10, rulerHeight: CGFloat = 20
    /// Where the rows start scrolling under the ruler, and the Clip under it, with room for the split markers.
    private static let videoTop: CGFloat = 34, clipTop: CGFloat = 48, clipHeight: CGFloat = 58
    /// The recorded sound's band along the bottom of the Clip.
    private static let bandHeight: CGFloat = 17
    private static let laneHeight: CGFloat = 28, laneGap: CGFloat = 8
    private static let motionHeight: CGFloat = 26
    /// How tall the rows are: 0 compact, 1 regular, 2 tall. The person's choice, kept between launches.
    private var size = min(max(Settings.store.integer(forKey: "ExactStudio.laneSize"), 0), 2)
    private var laneH: CGFloat { [Self.laneHeight, 42, 56][size] }
    private var motionH: CGFloat { [Self.motionHeight, 36, 46][size] }
    static func height(lanes: Int) -> CGFloat { clipTop + clipHeight + laneGap + CGFloat(lanes) * (laneHeight + laneGap) + 4 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What a row under the clip is.
    enum Kind: Equatable {
        /// The video's Moves row.
        case position
        /// A lane in a space (`Segment.space`): 0 the video's effects, 1 texts, 2 images, 3 whole-frame
        /// effects; or a sound lane (`Edits.soundSpace`).
        case lane(Int, Int)
        /// Under an open image lane, its current image's Moves row and effect rows; under an open
        /// text lane, its current text's effect rows.
        case imagePosition(String), imageEffects(String, Int)
    }
    struct Row { let kind: Kind; let y: CGFloat; let height: CGFloat
        var maxY: CGFloat { y + height } }

    /// The space of the segment being dragged, or nil when none is.
    private var draggedSpace: Int? {
        if case .sound(_, 0, _, _, _, _, _) = drag { return Edits.soundSpace }
        guard case let .move(id, _, _, _) = drag else { return nil }
        return editor?.edits.segments.first { $0.id == id }?.space
    }

    /// The rows under the Clip, top-down, in a fixed kind order: Moves, Effects, Text, Images, Music & Sound.
    /// While a block is dragged, its kind has one more lane to drop it on.
    // @ref LLP 0002#rows — rows come from use, in a fixed kind order, with no group headers
    var rows: [Row] {
        var out: [Row] = []
        var y = Self.clipTop + Self.clipHeight + Self.laneGap
        func add(_ kind: Kind, _ height: CGFloat) { out.append(Row(kind: kind, y: y, height: height)); y += height + Self.laneGap }
        guard let editor else { return out }
        let e = editor.edits, dragged = draggedSpace, empty = editor.showEmptyLanes
        func extra(_ space: Int) -> Int { dragged == space || empty ? 1 : 0 }
        add(.position, motionH)
        for l in 0..<e.lanes + extra(0) { add(.lane(0, l), laneH) }
        func effectRows(_ item: Segment) {
            var lanes = max(1, ((item.effects ?? []).map(\.lane).max() ?? -1) + 1)
            if case let .fx(id, _, 0, _, _, _, _) = drag, id == item.id { lanes += 1 }
            for l in 0..<lanes { add(.imageEffects(item.id, l), laneH) }
        }
        // @ref LLP 0002#where-an-effect-applies — a text's own effects fold under its lane, as an image's do
        for l in 0..<e.textLanes + extra(1) {
            add(.lane(1, l), laneH)
            guard l < e.textLanes, editor.openTextLanes.contains(l), let text = editor.currentItem(space: 1, lane: l) else { continue }
            effectRows(text)
        }
        // @ref LLP 0002#images — an open lane shows one image's own rows at a time
        for l in 0..<e.imageLanes + extra(2) {
            add(.lane(2, l), laneH)
            guard l < e.imageLanes, editor.openImageLanes.contains(l), let image = editor.currentImage(lane: l) else { continue }
            add(.imagePosition(image.id), motionH)
            effectRows(image)
        }
        for l in 0..<e.soundLanes + extra(Edits.soundSpace) { add(.lane(Edits.soundSpace, l), laneH) }
        return out
    }
    private func row(_ kind: Kind) -> Row? { rows.first { $0.kind == kind } }
    /// The row under `y`, counting the gaps between rows as half each neighbour's.
    private func row(at y: CGFloat) -> Row? { rows.first { y >= $0.y - Self.laneGap / 2 && y < $0.maxY + Self.laneGap / 2 } }
    /// The row a top-level segment is drawn on.
    private func row(of s: Segment) -> Row? { row(.lane(s.space, s.lane)) }
    /// Whether a lane exists in the edits, not only as a place to drop on.
    private func real(_ space: Int, _ lane: Int) -> Bool { lane < (editor?.edits.laneCount(space: space) ?? 1) }

    func attach(_ editor: Editor?) {
        if let old = self.editor, old !== editor { old.unlisten(self) }
        if let p = observedPlayer, let o = timeObserver { p.removeTimeObserver(o) }
        timeObserver = nil
        self.editor = editor
        shown = ([], [], [])
        guard let editor else { needsDisplay = true; return }
        editor.listen(self) { [weak self] in self?.changed() }
        editor.onZoom = { [weak self] in self?.needsDisplay = true }
        observedPlayer = editor.player
        timeObserver = editor.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.follow()
            self?.needsDisplay = true
        }
        resetFilm(editor)
        changed()
    }

    func detach() { attach(nil) }

    /// How much taller (or, negative, shorter) than its content the person made the timeline,
    /// by dragging its top edge; kept between launches. Shorter than its content, it scrolls.
    private var extra = CGFloat(Settings.store.double(forKey: "ExactStudio.timelineExtra"))
    var scrollY: CGFloat = 0
    private static let minimum: CGFloat = 120, grip: CGFloat = 8
    private var contentHeight: CGFloat { (rows.last?.maxY ?? Self.clipTop + Self.clipHeight) + 8 }
    private var resizing: (start: CGFloat, extra: CGFloat)?

    private var shown: (lanes: Set<Int>, texts: Set<Int>, rows: [Row]) = ([], [], [])

    // @ref LLP 0005#fold-everything-pick-a-size
    private func changed() {
        needsDisplay = true
        if let editor {
            let now = rows
            if editor.openImageLanes != shown.lanes || editor.openTextLanes != shown.texts {
                let top = scrollY + Self.videoTop, bottom = scrollY + bounds.height
                let toggled = editor.openImageLanes.symmetricDifference(shown.lanes).map { Kind.lane(2, $0) }
                    + editor.openTextLanes.symmetricDifference(shown.texts).map { Kind.lane(1, $0) }
                let seen = shown.rows.filter { $0.maxY > top && $0.y < bottom }
                let anchors = seen.filter { toggled.contains($0.kind) } + seen
                if let anchor = anchors.first(where: { a in now.contains { $0.kind == a.kind } }), let same = now.first(where: { $0.kind == anchor.kind }) {
                    scrollY += same.y - anchor.y
                }
            }
            shown = (editor.openImageLanes, editor.openTextLanes, now)
        }
        let h = contentHeight
        scrollY = min(max(scrollY, 0), max(0, contentHeight - bounds.height))
        if h != lastHeight { lastHeight = h; onHeight(h) }
    }

    /// A mouse event's point in the content, which scrolls under the view.
    private func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        // The ruler and the lane sizes do not scroll.
        return CGPoint(x: p.x, y: p.y < Self.videoTop ? p.y : p.y + scrollY)
    }

    // @ref LLP 0005#zoom-the-timeline — a mouse wheel zooms, a trackpad scrolls
    override func scrollWheel(with e: NSEvent) {
        if let editor {
            let p = convert(e.locationInWindow, from: nil)
            if !e.hasPreciseScrollingDeltas {
                // A mouse wheel: sideways (or with Shift) it pans; up and down it zooms around the pointer.
                if e.scrollingDeltaX != 0 || e.modifierFlags.contains(.shift) {
                    if editor.zoomed { pan(by: -(e.scrollingDeltaX != 0 ? e.scrollingDeltaX : e.scrollingDeltaY) * 8) }
                    return
                }
                if editor.wheelZoom, e.scrollingDeltaY != 0, p.x >= trackRect.minX, p.x <= trackRect.maxX {
                    return zoom(by: pow(1.12, Double(min(max(e.scrollingDeltaY, -6), 6))), at: p.x)
                }
            } else if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
                // A trackpad never zooms: sideways it pans the zoomed timeline.
                guard editor.zoomed else { return super.scrollWheel(with: e) }
                return pan(by: -e.scrollingDeltaX)
            }
        }
        let room = contentHeight - bounds.height
        guard room > 0 else { return super.scrollWheel(with: e) }
        scrollY = min(max(scrollY - e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8), 0), room)
        needsDisplay = true
    }

    /// A pinch zooms around the pointer, always.
    override func magnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        zoom(by: 1 + Double(e.magnification), at: min(max(p.x, trackRect.minX), trackRect.maxX))
    }

    // MARK: Zoom
    // Only the view changes: no edit, no save, no rebuild.

    /// The most a recording zooms: about 240 points a second, and never less than the whole of it.
    private var maxZoom: Double {
        guard let d = editor?.duration, d > 0 else { return 1 }
        return max(1, 240 * d / Double(trackRect.width))
    }
    /// The seconds the track shows, and the time at its left edge.
    private var span: Double {
        guard let editor, editor.duration > 0 else { return 1 }
        return editor.duration / min(max(editor.zoom, 1), maxZoom)
    }
    private var origin: Double {
        guard let editor else { return 0 }
        return min(max(editor.zoomStart, 0), max(0, editor.duration - span))
    }

    /// Zoom by `factor`, keeping the time under `px` under it.
    private func zoom(by factor: Double, at px: CGFloat) {
        guard let editor, editor.duration > 0 else { return }
        editor.zoomMax = maxZoom
        let f = Double((px - trackRect.minX) / trackRect.width)
        let at = origin + f * span
        let next = min(max(editor.duration / span * factor, 1), maxZoom)
        editor.setZoom(next, start: at - f * editor.duration / next)
    }

    /// Slide the zoomed timeline by `points` (positive: later).
    private func pan(by points: CGFloat) {
        guard let editor else { return }
        editor.setZoom(editor.zoom, start: origin + Double(points / trackRect.width) * span)
    }

    /// While playing, the view pages on when the playhead runs off it.
    private func follow() {
        guard let editor, editor.isPlaying, editor.zoomed, drag == nil else { return }
        let ph = editor.playhead
        if ph > origin + span * 0.98 || ph < origin { editor.setZoom(editor.zoom, start: ph - span * 0.02) }
    }

    /// Dragging to an edge of the zoomed track slides it slowly that way.
    private var lastDrag: NSEvent?
    private var pointer: NSEvent? { lastDrag }
    private var sliding: (ref: ItemRef, from: CGRect, began: CFTimeInterval)?
    private var slideTimer: Timer?

    private func rect(of ref: ItemRef) -> CGRect? {
        guard let editor else { return nil }
        let e = editor.edits
        func box(_ a: Double, _ b: Double, _ kind: Kind) -> CGRect? {
            row(kind).map { CGRect(x: x(a), y: $0.y + 2, width: max(4, x(b) - x(a)), height: $0.height - 4) }
        }
        switch ref.kind {
        case "sound": return e.sounds.first { $0.id == ref.id }.flatMap { box($0.start, $0.end(editor.map), .lane(Edits.soundSpace, $0.lane)) }
        case "image-effect":
            return e.segments.first { $0.id == ref.image }?.effects?.first { $0.id == ref.id }.flatMap { box($0.start, $0.end, .imageEffects(ref.image ?? "", $0.lane)) }
        case "move", "image-move": return nil
        default: return e.segments.first { $0.id == ref.id }.flatMap { box($0.start, $0.end, .lane($0.space, $0.lane)) }
        }
    }

    private func slideBack(_ ref: ItemRef, from: CGRect) {
        sliding = (ref, from, CACurrentMediaTime())
        slideTimer?.invalidate()
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.needsDisplay = true
            if let s = self.sliding, CACurrentMediaTime() - s.began > 0.25 { self.sliding = nil; t.invalidate() }
        }
    }
    private var edgeTimer: Timer?
    private func autoPan() {
        guard let editor, editor.zoomed, moved, let e = lastDrag, let drag else { return }
        if case .pan = drag { return }
        let px = convert(e.locationInWindow, from: nil).x, band: CGFloat = 16
        let over = px < trackRect.minX + band ? px - trackRect.minX - band : px > trackRect.maxX - band ? px - trackRect.maxX + band : 0
        guard over != 0 else { return }
        editor.setZoom(editor.zoom, start: origin + Double(min(max(over / band, -2), 2)) * span * 0.5 / 30)
        mouseDragged(with: e)
    }

    // MARK: Filmstrip

    private func resetFilm(_ editor: Editor) {
        guard filmFor != editor.id else { return }
        generators.values.forEach { $0.cancelAllCGImageGeneration() }
        filmFor = editor.id
        film = [:]; filmUsed = [:]; filmPending = []; filmWanted = []; generators = [:]
    }

    /// The level whose steps are about as wide as one thumbnail at this zoom, and its step in seconds.
    private func filmLevel(_ editor: Editor) -> (level: Int, step: Double) {
        let m = editor.meta, d = editor.duration
        let aspect = m.width > 0 && m.height > 0 && m.crop.h > 0 ? min(max(m.width * m.crop.w / (m.height * m.crop.h), 0.3), 3) : 16.0 / 9
        let want = Double(Self.clipHeight) * aspect * span / Double(trackRect.width)
        let level = min(max(0, Int(log2(d / max(want, 0.001)).rounded())), 18)
        return (level, d / pow(2, Double(level)))
    }

    /// The clip's thumbnails inside `r`: one a step at this zoom's level, sharp ones loaded in the
    /// background for what is in view; until one arrives, the nearest loaded one stands in.
    private func drawFilm(_ editor: Editor, in r: CGRect, ctx: CGContext) {
        guard editor.duration > 0 else { return }
        let (level, step) = filmLevel(editor)
        let from = max(origin, origin + Double((r.minX - trackRect.minX) / trackRect.width) * span)
        let to = min(origin + span, origin + Double((r.maxX - trackRect.minX) / trackRect.width) * span)
        guard to > from else { return }
        let last = (1 << level) - 1
        for i in max(0, Int(from / step))...min(last, max(0, Int(ceil(to / step)) - 1)) {
            let key = Thumb(level: level, index: i)
            var img = film[key]
            if img != nil { filmTick += 1; filmUsed[key] = filmTick }
            else {
                if !filmPending.contains(key) { filmWanted.insert(key) }
                let mid = (Double(i) + 0.5) * step, d = editor.duration
                img = film.min { abs((Double($0.key.index) + 0.5) * d / pow(2, Double($0.key.level)) - mid) < abs((Double($1.key.index) + 0.5) * d / pow(2, Double($1.key.level)) - mid) }?.value
            }
            guard let img else { continue }
            let cell = CGRect(x: x(Double(i) * step), y: Self.clipTop, width: x(Double(i + 1) * step) - x(Double(i) * step), height: Self.clipHeight)
            let k = max(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
            let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
            ctx.saveGState()
            ctx.clip(to: cell)
            ctx.translateBy(x: cell.midX, y: cell.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            ctx.restoreGState()
        }
        if !filmWanted.isEmpty { DispatchQueue.main.async { [weak self] in self?.loadFilm() } }
    }

    /// Ask for the thumbnails the last draw lacked, off the main thread; keep at most a few hundred.
    private func loadFilm() {
        guard let editor, filmFor == editor.id, !filmWanted.isEmpty else { return }
        if filmPending.count > 150 {
            // Zoomed or panned far past them: drop the old requests.
            generators.values.forEach { $0.cancelAllCGImageGeneration() }
            filmPending = []
        }
        let crop = editor.meta.crop, id = editor.id, d = editor.duration
        for (level, keys) in Dictionary(grouping: filmWanted.subtracting(filmPending), by: \.level) {
            let step = d / pow(2, Double(level))
            let generator = generators[level] ?? {
                let g = AVAssetImageGenerator(asset: editor.asset)
                g.maximumSize = CGSize(width: 240, height: 240)
                g.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: 600)
                g.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)
                generators[level] = g
                return g
            }()
            var byTime: [NSValue: Thumb] = [:]
            for key in keys { byTime[NSValue(time: CMTime(seconds: (Double(key.index) + 0.5) * step, preferredTimescale: 600))] = key }
            filmPending.formUnion(keys)
            generator.generateCGImagesAsynchronously(forTimes: Array(byTime.keys)) { [weak self] requested, image, _, _, _ in
                guard let key = byTime[NSValue(time: requested)] else { return }
                let cropped = image.map { image in
                    image.cropping(to: CGRect(x: crop.x * Double(image.width), y: crop.y * Double(image.height),
                                              width: crop.w * Double(image.width), height: crop.h * Double(image.height)).integral) ?? image
                }
                DispatchQueue.main.async {
                    guard let self, self.filmFor == id else { return }
                    self.filmPending.remove(key)
                    guard let cropped else { return }
                    self.film[key] = cropped
                    self.filmTick += 1
                    self.filmUsed[key] = self.filmTick
                    if self.film.count > 400 {
                        for old in self.filmUsed.sorted(by: { $0.value < $1.value }).prefix(100).map(\.key) { self.film[old] = nil; self.filmUsed[old] = nil }
                    }
                    self.needsDisplay = true
                }
            }
        }
        filmWanted = []
    }

    // MARK: Mapping

    private var trackRect: CGRect { CGRect(x: Self.labelWidth, y: 0, width: max(1, bounds.width - Self.labelWidth - Self.pad), height: bounds.height) }
    /// Time to the track and back, through the zoom: the track shows `span` seconds from `origin`.
    private func x(_ t: Double) -> CGFloat {
        guard let d = editor?.duration, d > 0 else { return trackRect.minX }
        return trackRect.minX + CGFloat((t - origin) / span) * trackRect.width
    }
    private func t(_ x: CGFloat) -> Double {
        guard let d = editor?.duration, d > 0 else { return 0 }
        return origin + Double(min(max((x - trackRect.minX) / trackRect.width, 0), 1)) * span
    }
    private func menuRow(_ r: Row) -> TimelineRow? {
        switch r.kind {
        case .position: return .position
        case let .lane(space, lane): return .lane(space, lane)
        case let .imagePosition(id): return .imagePosition(id)
        case let .imageEffects(id, lane): return .imageEffects(id, lane)
        }
    }
    private func hasPlus(_ r: Row) -> Bool {
        guard let editor, let row = menuRow(r) else { return false }
        return TimelineMenus.plus(row, editor) != nil
    }
    /// At the end of the row's label, every row's in one column just left of the track.
    private func plusRect(_ r: Row) -> CGRect {
        return CGRect(x: Self.labelWidth - 50, y: r.y + r.height / 2 - 9, width: 18, height: 18)
    }
    // @ref LLP 0005#the-lane-menu
    private func hasMore(_ r: Row) -> Bool {
        switch r.kind {
        case let .lane(space, lane): return real(space, lane)
        default: return false
        }
    }
    private func moreRect(_ r: Row) -> CGRect { CGRect(x: Self.labelWidth - 28, y: r.y + r.height / 2 - 9, width: 18, height: 18) }
    /// The three lane sizes, in the corner above the labels.
    private func sizeRect(_ i: Int) -> CGRect { CGRect(x: Self.pad + CGFloat(i) * 24, y: Self.rulerTop, width: 22, height: 18) }

    /// The recorded sound's band along the bottom of a clip part.
    private func bandRect(_ part: CGRect) -> CGRect { CGRect(x: part.minX, y: part.maxY - Self.bandHeight, width: part.width, height: Self.bandHeight) }

    private func diamond(_ t: Double, in r: Row) -> CGRect { CGRect(x: x(t) - 7, y: r.y + r.height / 2 - 7, width: 14, height: 14) }

    /// The lane of a space a dragged block would drop on at `y`, or one past the last.
    /// An open image lane's own rows count as that lane.
    private func lane(at y: CGFloat, space: Int) -> Int {
        guard let e = editor?.edits else { return 0 }
        let mine = rows.filter { if case let .lane(sp, _) = $0.kind { return sp == space } else { return false } }
        guard let first = mine.first, y >= first.y else { return 0 }
        let i = mine.lastIndex { y >= $0.y - Self.laneGap / 2 } ?? 0
        return min(y > (mine.last?.maxY ?? 0) + Self.laneGap / 2 ? i + 1 : i, e.laneCount(space: space))
    }

    /// The row of its image's effects a dragged image effect would drop on at `y`, or one past the last.
    private func fxLane(at y: CGFloat, image: String) -> Int {
        let mine = rows.filter { if case let .imageEffects(id, _) = $0.kind { return id == image } else { return false } }
        guard let first = mine.first, y >= first.y else { return 0 }
        return min((mine.lastIndex { y >= $0.y - Self.laneGap / 2 } ?? 0) + (y > (mine.last?.maxY ?? 0) + Self.laneGap / 2 ? 1 : 0), mine.count)
    }

    /// The chips an image's or a text's block shows: its own blur and black and white.
    // @ref LLP 0002#depth — the row stays; the block says it is behind
    static func chips(_ s: Segment) -> [String] {
        let kinds = Set((s.effects ?? []).map(\.kind))
        return (s.isBehind ? [behindChip] : []) + (kinds.contains("blur") ? ["Blur"] : []) + (kinds.contains("mono") ? ["B&W"] : [])
    }

    static let behindChip = "Behind video"

    static func chipColor(_ chip: String) -> NSColor {
        chip == behindChip ? NSColor(white: 0, alpha: 0.32) : chip == "Blur" ? .systemIndigo : .systemGray
    }

    static func color(image effect: Segment) -> NSColor {
        switch effect.kind {
        case "blur": return .systemIndigo
        case "mono": return .systemGray
        case "fade": return .systemBrown
        default: return .systemPurple
        }
    }

    static func caption(image effect: Segment) -> String {
        ["blur": "Blur", "mono": "Black & white", "fade": "Fade", "pulse": "Pulse", "float": "Float", "wiggle": "Wiggle"][effect.kind] ?? "Effect"
    }

    /// An added sound's blocks: a colour no other block has.
    static let soundColor = NSColor(srgbRed: 0.50, green: 0.60, blue: 0.17, alpha: 1)
    static let clipColor = NSColor(srgbRed: 0.93, green: 0.63, blue: 0.22, alpha: 1)
    /// A mask's blocks: a deep red no other block has.
    static let maskColor = NSColor(srgbRed: 0.66, green: 0.20, blue: 0.24, alpha: 1)

    static func color(_ s: Segment) -> NSColor {
        switch s.kind {
        case "zoom": return (s.level ?? 2) < 1 ? .systemTeal : .systemBlue
        case "speed": return .systemOrange
        case "spotlight": return .systemPurple
        case "highlight": return .systemYellow
        case "blur": return .systemIndigo
        case "mono": return .systemGray
        case "text": return .systemPink
        case "image": return .systemGreen
        case "3d": return .systemMint
        case "mask": return maskColor
        default: return .systemPink
        }
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        // The grip on the top edge, drawn over the content after it.
        defer {
            if bounds.height > 40, contentHeight > bounds.height + 1 {
                // How far down the lanes are scrolled.
                let track = bounds.height - 24, h = max(16, track * bounds.height / contentHeight)
                NSColor(white: 1, alpha: 0.2).setFill()
                NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 6, y: 12 + scrollY / (contentHeight - bounds.height) * (track - h), width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        guard let editor else { return }
        // The view's height is the person's (the handle above it): keep the scroll inside the content.
        scrollY = min(max(scrollY, 0), max(0, contentHeight - bounds.height))
        // The rows scroll under the ruler: the ruler, the lane sizes and the playhead stay put.
        // Undone before the indicator above is drawn: it stays at the view's edge, not in the content.
        let scroller = NSGraphicsContext.current?.cgContext
        scroller?.saveGState()
        scroller?.clip(to: CGRect(x: 0, y: Self.videoTop - max(0, 4 - scrollY), width: bounds.width, height: bounds.height))
        scroller?.translateBy(x: 0, y: -scrollY)
        var scrolling = true
        func pin() { if scrolling { scrolling = false; scroller?.restoreGState() } }
        defer { pin() }
        let pinnedClip = CGRect(x: trackRect.minX - 2, y: 0, width: trackRect.width + 4, height: bounds.height - (editor.zoomed ? 8 : 0))
        let d = editor.duration
        let rulerTop = Self.rulerTop, rulerHeight = Self.rulerHeight, clipTop = Self.clipTop, clipHeight = Self.clipHeight

        editor.zoomMax = maxZoom
        // Zoomed or scrolled, the track's drawing stays in the track: never over the labels.
        // @ref LLP 0005#zoom-the-timeline — the label column is never drawn over
        // Zoomed, it also stops above the slim bar along the bottom.
        let trackClip = CGRect(x: trackRect.minX - 2, y: -100_000, width: trackRect.width + 4,
                               height: 100_000 + scrollY + bounds.height - (editor.zoomed ? 8 : -100_000))
        // The ruler: the densest step whose labels still fit apart, ticks only where it shows.
        let perPoint = span / Double(trackRect.width)
        let step = [0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60].first { $0 / perPoint >= ($0 < 1 ? 58 : 46) } ?? 60 * ceil(46 * perPoint / 60)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.45)]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        // The ruler and the lane sizes, drawn last and unscrolled.
        func drawBand() {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: pinnedClip).addClip()
        var tick = floor(origin / step)
        while tick * step <= min(d, origin + span) + 0.001 {
            let s = tick * step, px = x(s)
            tick += 1
            NSColor(white: 1, alpha: 0.18).setFill()
            NSRect(x: px, y: rulerTop + rulerHeight - 6, width: 1, height: 6).fill()
            let text = Self.clock(s + 0.001, tenths: step < 1) as NSString
            // A label that would run past the track's end is left out rather than cut.
            guard px + 3 + text.size(withAttributes: small).width <= trackRect.maxX + 2 else { continue }
            text.draw(at: CGPoint(x: px + 3, y: rulerTop + 2), withAttributes: small)
        }
        NSGraphicsContext.restoreGraphicsState()

        // The lane sizes: three bars, thin to thick; the chosen one lit.
        for i in 0..<3 {
            let b = sizeRect(i)
            NSColor(white: 1, alpha: i == self.size ? 0.16 : 0.05).setFill()
            NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
            NSColor(white: 1, alpha: i == self.size ? 0.9 : 0.45).setFill()
            let h = CGFloat(3 + i * 3)
            NSBezierPath(roundedRect: CGRect(x: b.minX + 5, y: b.midY - h / 2, width: b.width - 10, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        }
        drawLabel("Clip", symbol: "film", y: clipTop, height: clipHeight, attrs: label, tint: NSColor(white: 1, alpha: 0.7))
        // From here to the playhead, labels and +s wait in `labelQueue` and are drawn after, unclipped.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: trackClip).addClip()
        labelQueue = []

        do {
            // The clip: each part its own rounded block of filmstrip, a clear gap between parts,
            // a scissors pin over each split; a removed part dark and hatched.
            // @ref LLP 0002#sound — the recorded sound is cut with the clip, so it is drawn inside it: a band along its bottom
            let wave = editor.hasSound ? Waveform.of(editor.asset.url, ready: { [weak self] in self?.needsDisplay = true }) : nil
            let soundSelected = editor.selected == Editor.recordedSound
            let gap: CGFloat = 4
            let all = editor.pieces
            let bridged = Set(all.indices.filter { !all[$0].removed && editor.edits.transitions[Edits.key(all[$0].end)] != nil }.flatMap { i -> [Int] in
                let run = Array(all.indices.dropFirst(i + 1).prefix { all[$0].removed })
                return (run.last ?? i) + 1 < all.count ? run : []
            })
            for (index, piece) in all.enumerated() {
                let r = CGRect(x: x(piece.start) + (piece.start > 0 ? gap : 0), y: clipTop,
                               width: max(3, x(piece.end) - x(piece.start) - (piece.start > 0 ? gap : 0) - (piece.end < d ? gap : 0)), height: clipHeight)
                let shape = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor(white: 1, alpha: 0.08).setFill()
                r.fill()
                // The filmstrip runs across the whole clip; each block shows its own stretch of it.
                if let ctx = NSGraphicsContext.current?.cgContext { drawFilm(editor, in: r, ctx: ctx) }
                if piece.removed {
                    NSColor(calibratedWhite: 0.06, alpha: 0.84).setFill()
                    r.fill()
                    NSColor.systemRed.withAlphaComponent(0.35).setStroke()
                    var hx = r.minX - r.height
                    while hx < r.maxX {
                        let line = NSBezierPath()
                        line.move(to: CGPoint(x: hx, y: r.maxY)); line.line(to: CGPoint(x: hx + r.height, y: r.minY))
                        line.lineWidth = 2
                        line.stroke()
                        hx += 9
                    }
                } else {
                    // A warm wash, so the kept parts read as clip blocks.
                    Self.clipColor.withAlphaComponent(0.22).setFill()
                    r.fill()
                    if editor.hasSound {
                        let band = bandRect(r)
                        NSColor(srgbRed: 0.17, green: 0.13, blue: 0.09, alpha: soundSelected ? 0.95 : 0.88).setFill()
                        band.fill()
                        NSColor(white: 0, alpha: 0.35).setFill()
                        CGRect(x: band.minX, y: band.minY, width: band.width, height: 1).fill()
                        if let wave {
                            drawWave(wave, in: band.insetBy(dx: 5, dy: 3), alpha: editor.edits.volume <= 0.001 ? 0.22 : 0.7) { t in t }
                        }
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                (piece.removed ? NSColor(white: 1, alpha: 0.12) : Self.clipColor.withAlphaComponent(0.9)).setStroke()
                shape.lineWidth = 1.5
                shape.stroke()
                if piece.removed, !bridged.contains(index) { title("Removed", in: r) }
                if soundSelected, !piece.removed {
                    NSColor.white.setStroke()
                    let sel = Self.shape(bandRect(r).insetBy(dx: 1, dy: 1), radius: 6, square: (false, false))
                    sel.lineWidth = 2
                    sel.stroke()
                }
                if editor.selected == piece.id {
                    NSColor.white.setStroke()
                    let sel = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 10, yRadius: 10)
                    sel.lineWidth = 2.5
                    sel.stroke()
                }
            }
            // @ref LLP 0002#our-own-look — our own marker, not one from another app
            // A split marker over each split: a thin line down the gap, with two small arrowheads
            // above the clip pointing in at it.
            for split in editor.edits.splits where split > 0.001 && split < d - 0.001 {
                let cx = x(split)
                NSColor(white: 1, alpha: 0.8).setFill()
                CGRect(x: cx - 0.75, y: clipTop - 12, width: 1.5, height: clipHeight + 12).fill()
                let mid = clipTop - 8, w: CGFloat = 6, h: CGFloat = 5
                for side in [-1.0, 1.0] {
                    let head = NSBezierPath()
                    let tipX = cx + CGFloat(side) * 2.5, backX = tipX + CGFloat(side) * w
                    head.move(to: CGPoint(x: tipX, y: mid)); head.line(to: CGPoint(x: backX, y: mid - h)); head.line(to: CGPoint(x: backX, y: mid + h)); head.close()
                    NSColor.white.setFill()
                    head.fill()
                }
            }

            // Transitions across removed parts: a badge on the gap they bridge.
            let parts = editor.pieces
            for (i, p) in parts.enumerated() where !p.removed {
                guard let kind = editor.edits.transitions[Edits.key(p.end)], parts.dropFirst(i + 1).contains(where: { !$0.removed }) else { continue }
                let next = parts.dropFirst(i + 1).first { !$0.removed }!
                let mid = (x(p.end) + x(next.start)) / 2
                let tag = (kind == "crossfade" ? "Crossfade" : "Fade") as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
                let size = tag.size(withAttributes: attrs)
                let pill = CGRect(x: mid - size.width / 2 - 7, y: clipTop + clipHeight / 2 - 9, width: size.width + 14, height: 18)
                NSColor.systemGreen.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
                tag.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 2.5), withAttributes: attrs)
            }
        }

        // The rows under the clip.
        let shown = rows
        let segments = editor.edits.segments
        let images = editor.edits.images
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.35)]
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.38), .kern: 0.5]
        let child: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.5)]
        func bed(_ r: Row, alpha: CGFloat = 0.05) {
            NSColor(white: 1, alpha: alpha).setFill()
            NSBezierPath(roundedRect: CGRect(x: trackRect.minX, y: r.y, width: trackRect.width, height: r.height), xRadius: 7, yRadius: 7).fill()
        }
        // An empty row's hint, ending in an ellipsis where the track is too narrow for it.
        let fit = NSMutableParagraphStyle()
        fit.lineBreakMode = .byTruncatingTail
        func drawHint(_ words: String, in r: Row) {
            let room = trackRect.width - 24
            (words as NSString).draw(in: CGRect(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7, width: max(0, room), height: 16), withAttributes: hint.merging([.paragraphStyle: fit]) { $1 })
        }
        // An image's own rows are lit only across that image's time, so it is plain whose they are.
        // @ref LLP 0002#images — the rows under a lane belong to one image at a time
        func childBed(_ r: Row, _ image: Segment) {
            bed(r, alpha: 0.02)
            let from = max(x(image.start), trackRect.minX), to = min(x(image.end), trackRect.maxX)
            guard to > from + 1 else { return }
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: CGRect(x: from, y: r.y, width: to - from, height: r.height), xRadius: 7, yRadius: 7).fill()
        }
        /// An empty child row's hint, kept inside the image's lit stretch and cut with an ellipsis to
        /// fit it; a stretch too short for a few words shows none, and the row's + says the rest.
        func childHint(_ words: String, _ r: Row, _ image: Segment) {
            let from = max(x(image.start), trackRect.minX) + 12, to = min(x(image.end), trackRect.maxX) - 10
            guard to - from > 90 else { return }
            (words as NSString).draw(in: CGRect(x: from, y: r.y + r.height / 2 - 7, width: to - from, height: 16), withAttributes: hint.merging([.paragraphStyle: fit]) { $1 })
        }
        func block(_ r: CGRect, _ color: NSColor, _ text: String, selected: Bool, dark: Bool = false, joined: (Bool, Bool) = (false, false),
                   chips: [String] = [], ref: ItemRef? = nil, inside: ((CGRect) -> Void)? = nil) {
            let r = ref.map { slid($0, r) } ?? r
            let state = ref.map(self.state) ?? .plain
            color.withAlphaComponent(selected ? 0.95 : 0.78).setFill()
            Self.shape(r, radius: 6, square: joined).fill()
            inside?(r)
            if state == .refused { hatch(r, square: joined) }
            stroke(r, selected: selected && state == .plain, square: joined)
            // Zoomed, a block's name stays in the part of it that shows.
            let from = max(r.minX, trackRect.minX)
            var to = min(r.maxX, trackRect.maxX)
            // @ref LLP 0002#where-an-effect-applies — an item's own blur or black and white shows as a chip at its end
            let chipFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white]
            for chip in chips.reversed() {
                let w = (chip as NSString).size(withAttributes: chipFont).width + 10, h: CGFloat = 15
                guard to - from > w + 40 else { break }
                let c = CGRect(x: to - w - 10, y: r.midY - h / 2, width: w, height: h)
                Self.chipColor(chip).setFill()
                NSBezierPath(roundedRect: c, xRadius: 4, yRadius: 4).fill()
                NSColor(white: 0, alpha: 0.35).setStroke()
                NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
                (chip as NSString).draw(at: CGPoint(x: c.minX + 5, y: c.midY - 6.5), withAttributes: chipFont)
                to = c.minX - 2
            }
            title(text, in: CGRect(x: from, y: r.minY, width: max(0, to - from), height: r.height), dark: dark)
            NSColor(white: 1, alpha: 0.55).setFill()
            if r.width > 24 {
                NSBezierPath(roundedRect: CGRect(x: r.minX + 3, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
            }
            switch state {
            case .refused: ring(r, square: joined, glow: false); noEntry(in: r)
            case .lit: ring(r, square: joined, glow: true)
            case .standing: badge(in: r)
            case .plain: break
            }
        }
        for r in shown {
            switch r.kind {
            case .position:
                drawLabel("Moves", symbol: "arrow.up.and.down.and.arrow.left.and.right", y: r.y, height: r.height, attrs: label, tint: .systemTeal, plus: true)
                bed(r)
                if editor.edits.moves.isEmpty {
                    drawHint("Drag the video in the preview to place it. Press + to add a move that animates it.", in: r)
                }
                for m in editor.edits.moves.sorted(by: { $0.t < $1.t }) { draw(move: m, in: r, selected: editor.selected == "m:" + m.id, threeD: m.angles != nil, ref: .move(m)) }
            case let .lane(space, lane):
                let symbol = space == 1 ? "textformat" : space == 2 ? "photo" : space == Edits.soundSpace ? "music.note" : "wand.and.stars"
                // An image or text lane with items folds its current item's own rows; an empty one keeps its name in line.
                let folds = (space == 1 || space == 2) && segments.contains { $0.space == space && $0.lane == lane }
                drawLabel(TimelineMenus.laneName(space, lane), symbol: symbol, y: r.y, height: r.height, attrs: label, tint: NSColor(white: 1, alpha: 0.5),
                          open: folds ? editor.isOpen(space: space, lane: lane) : nil, indent: (space == 1 || space == 2) && !folds ? 14 : 0, plus: hasPlus(r))
                bed(r, alpha: real(space, lane) ? 0.05 : 0.025)
                // A row shown only as a target says what its + adds; it is not stored.
                if !real(space, lane), draggedSpace != space {
                    drawHint(space == 1 ? "+ adds a text" : space == 2 ? "+ adds an image" : space == Edits.soundSpace ? "+ adds music or a sound"
                        : "+ adds an effect", in: r)
                }
            case let .imagePosition(id):
                guard let image = images.first(where: { $0.id == id }) else { continue }
                drawLabel("Moves", symbol: "", y: r.y, height: r.height, attrs: child, tint: .clear, indent: 22, plus: true)
                childBed(r, image)
                if (image.moves ?? []).isEmpty {
                    childHint("Drag the image in the preview to place it. Press + to add a move that animates it.", r, image)
                }
                for m in (image.moves ?? []).sorted(by: { $0.t < $1.t }) {
                    draw(move: m, in: r, selected: editor.selected == Editor.childID("im", image: id, m.id), threeD: false, ref: .move(m, image: id))
                }
            case let .imageEffects(id, lane):
                guard let image = segments.first(where: { $0.id == id && $0.isOverlay }) else { continue }
                drawLabel(lane == 0 ? "Effects" : "", symbol: "", y: r.y, height: r.height, attrs: child, tint: .clear, indent: 22, plus: true)
                childBed(r, image)
                if lane == 0, (image.effects ?? []).isEmpty {
                    childHint(image.kind == "text" ? "Press + to blur this text only, make it black and white, or fade it."
                        : "Press + to add an effect to this image only: blur, fade, pulse and more.", r, image)
                }
                let pool = Joins.whole(image, run: Joins.run(image, in: editor.edits.segments)).effects ?? []
                for fx in image.effects ?? [] where (landing(.effect(fx, image: id)) ?? fx.lane) == lane {
                    let b = CGRect(x: x(fx.start), y: r.y + 2, width: max(4, x(fx.end) - x(fx.start)), height: r.height - 4)
                    block(b, Self.color(image: fx), Self.caption(image: fx), selected: editor.selected == Editor.childID("ie", image: id, fx.id),
                          joined: (pool.contains { $0.joins(fx) }, pool.contains { fx.joins($0) }), ref: .effect(fx, image: id))
                }
            }
            if hasPlus(r) {
                let b = plusRect(r)
                labelQueue?.append {
                NSColor(white: 1, alpha: 0.1).setFill()
                NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
                NSColor.controlAccentColor.setFill()
                CGRect(x: b.midX - 4.5, y: b.midY - 0.75, width: 9, height: 1.5).fill()
                CGRect(x: b.midX - 0.75, y: b.midY - 4.5, width: 1.5, height: 9).fill()
                }
            }
            if hasMore(r) {
                let b = moreRect(r)
                labelQueue?.append {
                NSColor(white: 1, alpha: 0.06).setFill()
                NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
                NSColor(white: 1, alpha: 0.6).setFill()
                for i in -1...1 { NSBezierPath(ovalIn: CGRect(x: b.midX + CGFloat(i) * 4 - 1.25, y: b.midY - 1.25, width: 2.5, height: 2.5)).fill() }
                }
            }
        }
        drawDropHints(editor)
        for seg in segments {
            guard let r = landing(.of(seg)).flatMap({ row(.lane(seg.space, $0)) }) ?? row(of: seg) else { continue }
            let b = CGRect(x: x(seg.start), y: r.y + 2, width: max(4, x(seg.end) - x(seg.start)), height: r.height - 4)
            // An image stays lit while one of its own moves or effects is selected; the image whose
            // rows an open lane shows has a quiet outline.
            let selected = editor.selected == seg.id || (seg.isOverlay && editor.selectedItem?.id == seg.id)
            // @ref LLP 0002#split — a joined edge is square: the block goes on
            block(b, Self.color(seg), Self.caption(seg), selected: selected, dark: seg.kind == "highlight",
                  joined: (segments.contains { $0.joins(seg) }, segments.contains { seg.joins($0) }), chips: Self.chips(seg), ref: .of(seg))
            if !selected, seg.isOverlay, editor.isOpen(space: seg.space, lane: seg.lane), editor.currentItem(space: seg.space, lane: seg.lane)?.id == seg.id {
                NSColor(white: 1, alpha: 0.6).setStroke()
                let p = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                p.lineWidth = 1
                p.stroke()
            }
        }
        // The added sounds: each from its start for as long as it plays in the video, its file's
        // waveform inside, faint, at the moment of the file that plays there.
        let map = editor.map
        for snd in editor.edits.sounds {
            guard let r = row(.lane(Edits.soundSpace, landing(.sound(snd)) ?? snd.lane)) else { continue }
            let b = CGRect(x: x(snd.start), y: r.y + 2, width: max(4, x(snd.end(map)) - x(snd.start)), height: r.height - 4)
            let from = map.output(snd.start) - snd.offset
            let sounds = editor.edits.sounds
            block(b, Self.soundColor, URL(fileURLWithPath: snd.file).lastPathComponent, selected: editor.selected == Editor.soundID(snd.id),
                  joined: (sounds.contains { $0.joins(snd, map: map) }, sounds.contains { snd.joins($0, map: map) }), ref: .sound(snd)) { box in
                guard let wave = Waveform.of(editor.folder.appendingPathComponent(snd.file), ready: { [weak self] in self?.needsDisplay = true }) else { return }
                self.drawWave(wave, in: box.insetBy(dx: 6, dy: max(3, box.height * 0.2)), alpha: 0.3) { t in map.output(t) - from }
            }
        }

        // The playhead.
        let ph = x(editor.playhead)
        NSGraphicsContext.restoreGraphicsState()
        let labels = labelQueue ?? []
        labelQueue = nil
        labels.forEach { $0() }
        pin()
        drawBand()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: pinnedClip).addClip()
        NSColor.systemRed.setFill()
        NSRect(x: ph - 1, y: rulerTop + 4, width: 2, height: bounds.height - rulerTop - 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Zoomed in, a slim bar along the bottom shows which part of the recording is in view.
        if editor.zoomed, let b = panBar {
            NSColor(white: 1, alpha: 0.2).setFill()
            NSBezierPath(roundedRect: b, xRadius: 1.5, yRadius: 1.5).fill()
        }
        defer { drawReason() }
        guard ph >= trackRect.minX - 1, ph <= trackRect.maxX + 1 else { return }
        let tag = Self.clock(editor.playhead, tenths: true) as NSString
        let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
        let size = tag.size(withAttributes: tagAttrs)
        let pill = CGRect(x: min(max(ph - size.width / 2 - 6, trackRect.minX - 6), bounds.width - size.width - 14), y: rulerTop - 2, width: size.width + 12, height: 17)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8.5, yRadius: 8.5).fill()
        tag.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: tagAttrs)
    }

    /// Labels and +s met while the track is clipped, drawn once it is not.
    private var labelQueue: [() -> Void]?

    /// The slim bar along the bottom of the track while zoomed, in the view's (unscrolled) points.
    private var panBar: CGRect? {
        guard let editor, editor.zoomed, editor.duration > 0 else { return nil }
        let w = max(16, CGFloat(span / editor.duration) * trackRect.width)
        let at = trackRect.minX + CGFloat(origin / max(editor.duration - span, 0.001)) * (trackRect.width - w)
        return CGRect(x: at, y: bounds.height - 6, width: w, height: 3)
    }

    /// A row's label: a triangle when the row folds (`open` says which way), its symbol, and its name, cut to fit.
    private func drawLabel(_ text: String, symbol: String, y: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any], tint: NSColor, open: Bool? = nil, indent: CGFloat = 0, plus: Bool = false) {
        if labelQueue != nil {
            labelQueue?.append { [self] in drawLabel(text, symbol: symbol, y: y, height: height, attrs: attrs, tint: tint, open: open, indent: indent, plus: plus) }
            return
        }
        var at = Self.pad + indent
        if let open {
            let tri = NSBezierPath()
            let c = CGPoint(x: at + 4, y: y + height / 2)
            if open { tri.move(to: CGPoint(x: c.x - 4, y: c.y - 2.5)); tri.line(to: CGPoint(x: c.x + 4, y: c.y - 2.5)); tri.line(to: CGPoint(x: c.x, y: c.y + 3.5)) }
            else { tri.move(to: CGPoint(x: c.x - 2.5, y: c.y - 4)); tri.line(to: CGPoint(x: c.x + 3.5, y: c.y)); tri.line(to: CGPoint(x: c.x - 2.5, y: c.y + 4)) }
            tri.close()
            NSColor(white: 1, alpha: 0.55).setFill()
            tri.fill()
            at += 14
        }
        if !symbol.isEmpty, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus()
            tint.set()
            CGRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: CGRect(x: at, y: y + height / 2 - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            at += 20
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        var cut = attrs
        cut[.paragraphStyle] = style
        // The name stops before the row's +.
        let room = Self.labelWidth - at - (plus ? 54 : 8)
        (text as NSString).draw(in: CGRect(x: at, y: y + height / 2 - 7, width: max(10, room), height: 16), withAttributes: cut)
    }

    /// A waveform across `box`: at each x, how loud `file(t)` (the file's own time at recording time t) is, as a bar about the middle.
    private func drawWave(_ wave: Waveform, in box: CGRect, alpha: CGFloat, file: (Double) -> Double) {
        guard !wave.peaks.isEmpty, box.width > 2, box.height > 2 else { return }
        let path = NSBezierPath()
        // Only the part in view: zoomed in, a long sound's block runs far past the track.
        var px = max(box.minX, trackRect.minX)
        let end = min(box.maxX, trackRect.maxX)
        while px < end {
            let a = file(t(px)), b = file(t(px + 2))
            let h = max(1, CGFloat(wave.level(min(a, b), max(a, b, min(a, b) + 0.01))) * box.height)
            path.appendRect(CGRect(x: px, y: box.midY - h / 2, width: 1.2, height: h))
            px += 2
        }
        NSColor(white: 1, alpha: alpha).setFill()
        path.fill()
    }

    /// A move on a Moves row: its travel as a bar, ending in a diamond where it lands.
    private func draw(move m: Move, in r: Row, selected: Bool, threeD: Bool, ref: ItemRef) {
        let bar = CGRect(x: x(m.t - m.duration), y: r.y + 7, width: max(2, x(m.t) - x(m.t - m.duration)), height: r.height - 14)
        let state = self.state(ref)
        NSColor.systemTeal.withAlphaComponent(selected ? 0.85 : 0.45).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        if state == .refused { hatch(bar, square: (false, false)) }
        if selected, state == .plain { stroke(bar.insetBy(dx: -2, dy: -3), selected: true) }
        if state == .refused || state == .lit { ring(bar.insetBy(dx: -2, dy: -3), square: (false, false), glow: state == .lit) }
        let name = (["smooth": "Smooth", "linear": "Linear", "spring": "Spring", "zoom": "Zoom through", "swipe": "Swipe",
                     "fade": "Fade", "spin": "Spin", "pop": "Pop"][m.style] ?? m.style) + (threeD ? " · 3D" : "") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
        // Zoomed, the name stays in the part of the bar that shows.
        let from = max(bar.minX, trackRect.minX), shown = min(bar.maxX, trackRect.maxX) - from
        if shown > name.size(withAttributes: attrs).width + 16 { name.draw(at: CGPoint(x: from + 6, y: bar.minY - 1), withAttributes: attrs) }
        let d = diamond(m.t, in: r)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: d.midX, y: d.minY)); path.line(to: CGPoint(x: d.maxX, y: d.midY))
        path.line(to: CGPoint(x: d.midX, y: d.maxY)); path.line(to: CGPoint(x: d.minX, y: d.midY)); path.close()
        (selected ? NSColor.white : NSColor.systemTeal).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.4).setStroke()
        path.stroke()
        if state == .standing { badge(in: CGRect(x: bar.minX, y: r.y + 2, width: max(bar.width, d.maxX - bar.minX), height: r.height - 4)) }
    }

    static func shape(_ r: CGRect, radius: CGFloat, square: (Bool, Bool)) -> NSBezierPath {
        let k = max(0, min(radius, r.width / 2, r.height / 2)), l = square.0 ? 0 : k, g = square.1 ? 0 : k
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX + l, y: r.minY))
        p.line(to: CGPoint(x: r.maxX - g, y: r.minY))
        if g > 0 { p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + g), radius: g) }
        p.line(to: CGPoint(x: r.maxX, y: r.maxY - g))
        if g > 0 { p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX - g, y: r.maxY), radius: g) }
        p.line(to: CGPoint(x: r.minX + l, y: r.maxY))
        if l > 0 { p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY - l), radius: l) }
        p.line(to: CGPoint(x: r.minX, y: r.minY + l))
        if l > 0 { p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + l, y: r.minY), radius: l) }
        p.close()
        return p
    }

    private func stroke(_ r: CGRect, selected: Bool, square: (Bool, Bool) = (false, false)) {
        guard selected else { return }
        NSColor.white.setStroke()
        let p = Self.shape(r.insetBy(dx: 1, dy: 1), radius: 6, square: square)
        p.lineWidth = 2
        p.stroke()
    }

    private func title(_ text: String, in r: CGRect, dark: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: dark ? NSColor.black : NSColor.white]
        var s = text as NSString
        var size = s.size(withAttributes: attrs)
        // Too long: the name before its " · " detail, when that fits.
        if r.width <= size.width + 16, let short = text.components(separatedBy: " · ").first, short != text {
            s = short as NSString
            size = s.size(withAttributes: attrs)
        }
        guard r.width > size.width + 16 else { return }
        s.draw(at: CGPoint(x: r.minX + 10, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    static func caption(_ s: Segment) -> String {
        switch s.kind {
        case "image":
            let moves = s.moves?.count ?? 0, effects = s.effects?.count ?? 0
            let name = URL(fileURLWithPath: s.file ?? "").lastPathComponent
            return name + (moves > 0 ? " · \(moves) move\(moves == 1 ? "" : "s")" : "") + (effects > 0 ? " · \(effects) effect\(effects == 1 ? "" : "s")" : "")
        default: return s.label
        }
    }

    /// A blur's or black and white's reach, short, for its block.
    // @ref LLP 0002#where-an-effect-applies

    private static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

    static func clock(_ s: Double, tenths: Bool) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return tenths ? String(format: "%d:%02d.%d", m, sec, Int((s - floor(s)) * 10)) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Interaction

    /// The top-level segment under the pointer on a lane or an image's row.
    private func hit(_ p: CGPoint, in r: Row) -> Segment? {
        guard let editor, p.x >= trackRect.minX - 4 else { return nil }
        let near = { (s: Segment) in p.x >= self.x(s.start) - 4 && p.x <= self.x(s.end) + 4 }
        let onRow: [Segment]
        switch r.kind {
        case let .lane(space, lane): onRow = editor.edits.segments.filter { $0.space == space && $0.lane == lane && near($0) }
        default: return nil
        }
        // The selected one first, then the shortest (a short segment over a long one stays reachable).
        return onRow.first { $0.id == editor.selected } ?? onRow.min { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    /// The move under the pointer on a Moves row: its diamond, else its travel bar.
    private func moveHit(_ p: CGPoint, _ moves: [Move], in r: Row) -> Move? {
        guard let editor, editor.duration > 0, p.x >= trackRect.minX - 8 else { return nil }
        if let m = moves.first(where: { diamond($0.t, in: r).insetBy(dx: -5, dy: -6).contains(p) }) { return m }
        let at = t(p.x)
        let slop = Double(6 / max(trackRect.width, 1)) * span
        return moves.filter { at >= $0.t - $0.duration - slop && at <= $0.t + slop }.min { abs($0.t - at) < abs($1.t - at) }
    }

    // MARK: Adding
    // @ref LLP 0005#add-where-it-goes — each row adds its own kind of thing

    private final class Act: NSObject { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
    @objc private func picked(_ item: NSMenuItem) { (item.representedObject as? Act)?.run() }

    func nsMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .line: menu.addItem(.separator())
            case let .dim(title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .title(text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .item(title, run):
                let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Act(run)
                menu.addItem(item)
            case let .check(title, on, run):
                let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Act(run)
                item.state = on ? .on : .off
                menu.addItem(item)
            case let .off(title, why):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = why
                menu.addItem(item)
                let reason = NSMenuItem(title: why, action: nil, keyEquivalent: "")
                reason.isEnabled = false
                reason.attributedTitle = NSAttributedString(string: why, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                                                      .foregroundColor: NSColor.tertiaryLabelColor])
                menu.addItem(reason)
            case let .sub(title, inner):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = nsMenu(inner)
                menu.addItem(item)
            }
        }
        return menu
    }

    private func popUp(_ entries: [MenuEntry], under r: CGRect) {
        nsMenu(entries).popUp(positioning: nil, at: CGPoint(x: r.minX, y: r.maxY - scrollY + 4), in: self)
    }

    private func laneMenu(for r: Row) -> [MenuEntry] {
        guard let editor else { return [] }
        switch r.kind {
        case let .lane(space, lane):
            return TimelineMenus.lane(space, lane, editor) { [weak self] title, detail, run in self?.confirm(title, detail, run) }
        default: return []
        }
    }

    private func confirm(_ title: String, _ detail: String, _ run: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        guard let window else { if alert.runModal() == .alertFirstButtonReturn { run() }; return }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { run() } }
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = local(e)
        guard p.x < Self.labelWidth, let r = row(at: p.y), hasMore(r) else { return super.rightMouseDown(with: e) }
        nsMenu(laneMenu(for: r)).popUp(positioning: nil, at: CGPoint(x: p.x, y: p.y - scrollY), in: self)
    }

    private func showAdd(for r: Row) {
        guard let editor, let row = menuRow(r), let plus = TimelineMenus.plus(row, editor) else { return }
        switch plus {
        case let .menu(entries): popUp(entries, under: plusRect(r))
        case let .direct(run): run()
        }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor else { return }
        let p = local(e)
        moved = false
        func scrub() { drag = .scrub; editor.seek(source: t(p.x)) }
        // The slim bar under the zoomed track: drag it to slide the view; a click beside it centres there.
        let v = convert(e.locationInWindow, from: nil)
        if let b = panBar, v.y >= b.minY - 6, v.x >= trackRect.minX, v.x <= trackRect.maxX {
            drag = .pan(b.contains(CGPoint(x: v.x, y: b.midY)) ? v.x - b.minX : b.width / 2)
            return mouseDragged(with: e)
        }
        // The lane sizes, in the corner.
        if p.y < Self.videoTop, p.x < Self.labelWidth {
            if let i = (0..<3).first(where: { sizeRect($0).insetBy(dx: -1, dy: -3).contains(p) }) {
                size = i
                Settings.store.set(i, forKey: "ExactStudio.laneSize")
                changed()
            }
            return
        }
        // The clip: a part of it is selected, and the playhead goes there; its band selects the recorded sound.
        if p.y >= Self.clipTop, p.y <= Self.clipTop + Self.clipHeight {
            if p.x < Self.labelWidth { return }
            guard let piece = editor.pieces.first(where: { t(p.x) >= $0.start && t(p.x) <= $0.end }) else { return scrub() }
            // @ref LLP 0002#sound — the recorded sound is selected by its band in the Clip
            editor.select(editor.hasSound && !piece.removed && p.y >= Self.clipTop + Self.clipHeight - Self.bandHeight ? Editor.recordedSound : piece.id)
            return scrub()
        }
        guard let r = row(at: p.y) else {
            if p.y > Self.clipTop + Self.clipHeight { editor.select("") }
            return scrub()
        }
        if hasMore(r), moreRect(r).insetBy(dx: -2, dy: -4).contains(p) { return popUp(laneMenu(for: r), under: moreRect(r)) }
        if hasPlus(r), plusRect(r).insetBy(dx: -2, dy: -4).contains(p) { return showAdd(for: r) }
        // Only a label that folds or selects its row acts; a click on any other label does nothing.
        // Up to 8 points left of the track still reaches a block or a move that starts at its edge.
        if p.x < trackRect.minX - 8 {
            switch r.kind {
            case .lane(2, _): break
            default: return
            }
        }
        switch r.kind {
        case .position:
            if let m = moveHit(p, editor.edits.moves, in: r) {
                editor.select("m:" + m.id)
                editor.seek(source: m.t)
                // Keep where in the move it was grabbed, so a drag slides it from there.
                drag = .retime(m.id, m.t - t(p.x))
            } else { scrub() }
        case let .imagePosition(id):
            guard let image = editor.edits.images.first(where: { $0.id == id }) else { return }
            if let m = moveHit(p, image.moves ?? [], in: r) {
                editor.select(Editor.childID("im", image: id, m.id))
                editor.seek(source: m.t)
                drag = .imove(id, m.id, m.t - t(p.x))
            } else { scrub() }
        case let .imageEffects(id, lane):
            guard let image = editor.edits.segments.first(where: { $0.id == id && $0.isOverlay }) else { return }
            let on = (image.effects ?? []).filter { $0.lane == lane && p.x >= trackRect.minX - 4 && p.x >= x($0.start) - 4 && p.x <= x($0.end) + 4 }
            guard let fx = on.min(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return scrub() }
            editor.select(Editor.childID("ie", image: id, fx.id))
            let edge: CGFloat = 7, wide = x(fx.end) - x(fx.start) > edge * 2
            let mode = wide && p.x - x(fx.start) < edge ? -1 : wide && x(fx.end) - p.x < edge ? 1 : 0
            drag = .fx(id, fx.id, mode, fx.start, fx.end, fx.lane, t(p.x))
        case .lane:
            // An image or text lane's label folds its current item's rows.
            if case let .lane(space, lane) = r.kind, space == 1 || space == 2, p.x < Self.labelWidth {
                if editor.edits.segments.contains(where: { $0.space == space && $0.lane == lane }) { editor.toggleLane(space: space, lane) }
                return
            }
            if case let .lane(space, lane) = r.kind, space == Edits.soundSpace {
                let map = editor.map
                let on = editor.edits.sounds.filter { $0.lane == lane && p.x >= x($0.start) - 4 && p.x <= x($0.end(map)) + 4 }
                guard let snd = on.first(where: { Editor.soundID($0.id) == editor.selected }) ?? on.min(by: { $0.length < $1.length }) else {
                    editor.select("")
                    return scrub()
                }
                editor.select(Editor.soundID(snd.id))
                let a = x(snd.start), b = x(snd.end(map)), edge: CGFloat = 7, wide = b - a > edge * 2
                let mode = wide && p.x - a < edge ? -1 : wide && b - p.x < edge ? 1 : 0
                drag = .sound(snd.id, mode, snd.start, snd.offset, snd.length, snd.lane, t(p.x))
            } else if let s = hit(p, in: r) {
                editor.select(s.id)
                let edge: CGFloat = 7, wide = x(s.end) - x(s.start) > edge * 2
                if wide && p.x - x(s.start) < edge { drag = .left(s.id, s.start, s.end, s.lane) }
                else if wide && x(s.end) - p.x < edge { drag = .right(s.id, s.start, s.end, s.lane) }
                else { drag = .move(s.id, s.start, s.end, t(p.x)) }
            } else {
                editor.select("")
                scrub()
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if let r = resizing {
            // Window coordinates grow upward: dragging the edge up makes the timeline taller.
            extra = min(max(r.extra + (e.locationInWindow.y - r.start), Self.minimum - contentHeight), 600)
            changed()
            return
        }
        guard let editor, let drag else { return }
        let p = local(e), now = t(p.x)
        moved = true
        lastDrag = e
        if edgeTimer == nil, editor.zoomed {
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.autoPan() }
        }
        switch drag {
        case let .pan(grab):
            guard let b = panBar else { return }
            let x0 = convert(e.locationInWindow, from: nil).x - grab
            editor.setZoom(editor.zoom, start: Double((x0 - trackRect.minX) / max(trackRect.width - b.width, 1)) * (editor.duration - span))
            return
        case .scrub:
            editor.seek(source: now)
        case let .retime(id, grab):
            let to = now + grab
            editor.moveTime(id, to: to, live: true)
            editor.seek(source: to)
        case let .imove(image, id, grab):
            let to = now + grab
            editor.dragImageMove(image, id, to: to, live: true)
            editor.seek(source: to)
        case let .fx(image, id, mode, s, end, lane, grab):
            switch mode {
            case -1: editor.dragImageEffect(image, id, start: min(now, end - 0.1), end: end, lane: lane)
            case 1: editor.dragImageEffect(image, id, start: s, end: max(now, s + 0.1), lane: lane)
            default:
                guard let span = editor.edits.segments.first(where: { $0.id == image && $0.isOverlay }) else { return }
                let len = end - s
                let start = min(max(s + now - grab, span.start), span.end - len)
                editor.dragImageEffect(image, id, start: start, end: start + len, lane: fxLane(at: p.y, image: image))
            }
        case let .move(id, s, end, grab):
            guard let seg = editor.edits.segments.first(where: { $0.id == id }) else { return }
            let len = end - s
            let start = min(max(s + now - grab, 0), editor.duration - len)
            editor.drag(id, start: start, end: start + len, lane: lane(at: p.y, space: seg.space))
        case let .sound(id, mode, s, offset, length, lane, grab):
            let map = editor.map
            guard let snd = editor.edits.sounds.first(where: { $0.id == id }) else { return }
            switch mode {
            case 0:
                editor.dragSound(id, start: min(max(s + now - grab, 0), editor.duration - 0.1), offset: offset, length: length, lane: self.lane(at: p.y, space: Edits.soundSpace))
            case 1:
                // Its end: as long as it plays to here, but no longer than its file has left.
                let whole = Sounds.length(snd.file, in: editor.folder) ?? .infinity
                editor.dragSound(id, start: s, offset: offset, length: min(max(map.output(now) - map.output(s), 0.1), whole - offset), lane: lane)
            default:
                // Its beginning: the start and the place in the file move together, the end stays.
                let was = map.output(s), raw = map.output(now) - was
                let by = min(max(raw, -offset), length - 0.1)
                editor.dragSound(id, start: by == raw ? now : map.source(was + by), offset: offset + by, length: length - by, lane: lane)
            }
        case let .left(id, _, end, l):
            editor.drag(id, start: min(now, end - 0.1), end: end, lane: l)
        case let .right(id, s, _, l):
            editor.drag(id, start: s, end: max(now, s + 0.1), lane: l)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if resizing != nil {
            resizing = nil
            Settings.store.set(Double(extra), forKey: "ExactStudio.timelineExtra")
            needsDisplay = true
            return
        }
        edgeTimer?.invalidate()
        edgeTimer = nil
        lastDrag = nil
        if let drag, moved, let editor {
            switch drag {
            case .scrub, .pan: break
            case let .retime(id, _): if let m = editor.edits.moves.first(where: { $0.id == id }) { editor.moveTime(id, to: m.t, live: false) }
            case let .imove(image, id, _):
                if let m = editor.edits.images.first(where: { $0.id == image })?.moves?.first(where: { $0.id == id }) { editor.dragImageMove(image, id, to: m.t, live: false) }
            default:
                let refused = editor.dragCheck.flatMap { c in c.conflict == nil ? nil : rect(of: c.item).map { (c.item, $0) } }
                if !editor.endDrag(), let (ref, from) = refused { slideBack(ref, from: from) }
            }
        }
        drag = nil
        changed()
    }

    override func keyDown(with e: NSEvent) {
        guard let editor else { return super.keyDown(with: e) }
        switch e.keyCode {
        case 51, 117: editor.deleteSelected()            // Delete, Forward Delete
        case 49: editor.togglePlay()                      // Space
        case 1: e.modifierFlags.contains(.shift) ? editor.splitAll() : editor.split()   // S, ⇧S
        case 123: editor.seek(source: editor.playhead - (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        case 124: editor.seek(source: editor.playhead + (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        default: super.keyDown(with: e)
        }
    }
}

// MARK: Refusals
// @ref LLP 0005#refusals — the refusal look, the lit clash, the reason at the pointer, the slide back

extension TimelineView {
    static let refusalColor = NSColor(srgbRed: 1, green: 0x7a / 255.0, blue: 0x6e / 255.0, alpha: 1)
    static let landingColor = NSColor(srgbRed: 0.42, green: 0.66, blue: 1, alpha: 1)

    enum BlockState { case plain, refused, lit, standing }

    func landing(_ ref: ItemRef) -> Int? {
        guard let check = editor?.dragCheck, check.item == ref else { return nil }
        return check.landing
    }

    func state(_ ref: ItemRef) -> BlockState {
        guard let editor else { return .plain }
        if let check = editor.dragCheck, let c = check.conflict {
            if check.item == ref { return .refused }
            if c.other == ref || (c.item == ref && check.item != ref) { return .lit }
        }
        return editor.standing.contains { $0.involves(ref) } ? .standing : .plain
    }

    func hatch(_ r: CGRect, square: (Bool, Bool)) {
        NSGraphicsContext.saveGraphicsState()
        Self.shape(r, radius: 6, square: square).addClip()
        Self.refusalColor.withAlphaComponent(0.22).setFill()
        r.fill()
        let lines = NSBezierPath()
        var x = r.minX - r.height
        while x < r.maxX {
            lines.move(to: CGPoint(x: x, y: r.maxY)); lines.line(to: CGPoint(x: x + r.height, y: r.minY))
            x += 7
        }
        lines.lineWidth = 2
        NSColor(white: 1, alpha: 0.38).setStroke()
        lines.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func ring(_ r: CGRect, square: (Bool, Bool), glow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        if glow {
            let shadow = NSShadow()
            shadow.shadowColor = Self.refusalColor.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 9
            shadow.set()
        }
        Self.refusalColor.setStroke()
        let p = Self.shape(r.insetBy(dx: -1.5, dy: -1.5), radius: 7, square: square)
        p.lineWidth = 2
        p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func noEntry(in r: CGRect) {
        let d = min(14, r.height - 8)
        guard d > 6, r.width > d + 8 else { return }
        let c = CGRect(x: r.maxX - d - 10, y: r.midY - d / 2, width: d, height: d)
        Self.refusalColor.setFill()
        NSBezierPath(ovalIn: c).fill()
        NSColor(white: 0, alpha: 0.35).setStroke()
        NSBezierPath(ovalIn: c).stroke()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: c.minX + d * 0.22, y: c.midY - 1.25, width: d * 0.56, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
    }

    func badge(in r: CGRect) {
        let d: CGFloat = 12
        guard r.width > d + 6, r.height > d else { return }
        let c = CGRect(x: r.maxX - d - 4, y: r.minY + 3, width: d, height: d)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: c).fill()
        let bang = "!" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.black]
        let size = bang.size(withAttributes: attrs)
        bang.draw(at: CGPoint(x: c.midX - size.width / 2, y: c.midY - size.height / 2), withAttributes: attrs)
    }

    func drawDropHints(_ editor: Editor) {
        guard let check = editor.dragCheck, let origin = editor.dragFrom else { return }
        func span(_ e: Edits) -> (Double, Double, Kind)? {
            switch check.item.kind {
            case "sound":
                guard let s = e.sounds.first(where: { $0.id == check.item.id }) else { return nil }
                return (s.start, s.end(editor.map), .lane(Edits.soundSpace, s.lane))
            case "image-effect":
                guard let fx = e.segments.first(where: { $0.id == check.item.image })?.effects?.first(where: { $0.id == check.item.id }) else { return nil }
                return (fx.start, fx.end, .imageEffects(check.item.image ?? "", fx.lane))
            case "move", "image-move": return nil
            default:
                guard let s = e.segments.first(where: { $0.id == check.item.id }) else { return nil }
                return (s.start, s.end, .lane(s.space, s.lane))
            }
        }
        func dashed(_ r: CGRect, _ color: NSColor, fill: CGFloat) {
            color.withAlphaComponent(fill).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            color.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            p.lineWidth = 1.5
            p.setLineDash([5, 4], count: 2, phase: 0)
            p.stroke()
        }
        if check.conflict != nil, let (a, b, kind) = span(origin), let r = row(kind) {
            dashed(CGRect(x: x(a), y: r.y + 2, width: max(4, x(b) - x(a)), height: r.height - 4), NSColor(white: 1, alpha: 0.45), fill: 0.03)
        }
        if let lane = check.landing, let (a, b, kind) = span(editor.edits) {
            let target: Kind
            switch kind {
            case let .lane(space, _): target = .lane(space, lane)
            case let .imageEffects(image, _): target = .imageEffects(image, lane)
            default: return
            }
            guard let r = row(target) else { return }
            dashed(CGRect(x: x(a), y: r.y, width: max(4, x(b) - x(a)), height: r.height).insetBy(dx: -3, dy: -1), Self.landingColor, fill: 0.14)
        }
    }

    func drawReason() {
        guard let c = editor?.dragCheck?.conflict, let e = pointer else { return }
        let p = convert(e.locationInWindow, from: nil)
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.8)]
        let one = c.line1 as NSString, two = c.line2 as NSString
        let room: CGFloat = 300
        let w1 = one.size(withAttributes: bold).width
        let r2 = two.boundingRect(with: CGSize(width: room, height: 200), options: [.usesLineFragmentOrigin], attributes: plain)
        let w = min(room, max(w1, ceil(r2.width))) + 24, h = 14 + 16 + (c.line2.isEmpty ? 0 : ceil(r2.height) + 3)
        let blocks = drawnBlocks(), key = [editor?.dragCheck?.item, c.other].compactMap { $0 }.compactMap(rect(of:))
            .map { CGRect(x: $0.minX, y: $0.minY - scrollY, width: $0.width, height: $0.height) }
        var candidates: [CGRect] = []
        for dy in stride(from: -220.0, through: 220.0, by: 6.0) {
            for x0 in [p.x + 16, p.x - 16 - w, p.x + 60, p.x - 60 - w] {
                candidates.append(CGRect(x: min(max(trackRect.minX, x0), bounds.maxX - w - 8), y: min(max(Self.videoTop, p.y + CGFloat(dy) - h / 2), bounds.maxY - h - 6), width: w, height: h))
            }
        }
        func area(_ rs: [CGRect], _ b: CGRect) -> CGFloat {
            rs.reduce(0) { sum, r in let i = r.intersection(b.insetBy(dx: -4, dy: -4)); return sum + (i.isNull ? 0 : i.width * i.height) }
        }
        func cost(_ b: CGRect) -> CGFloat {
            area(blocks, b) + 20 * area(key, b) + (b.insetBy(dx: -6, dy: -6).contains(p) ? 1_000_000 : 0) + hypot(b.midX - p.x, b.midY - p.y) * 4
        }
        let box = candidates.min { cost($0) < cost($1) } ?? candidates[0]
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(calibratedWhite: 0.14, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        Self.refusalColor.setStroke()
        let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        edge.lineWidth = 1.5
        edge.stroke()
        one.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 7), withAttributes: bold)
        if !c.line2.isEmpty { two.draw(with: CGRect(x: box.minX + 12, y: box.minY + 26, width: w - 24, height: ceil(r2.height) + 2), options: [.usesLineFragmentOrigin], attributes: plain) }
    }

    func drawnBlocks() -> [CGRect] {
        guard let editor else { return [] }
        let e = editor.edits
        var refs = e.segments.map(ItemRef.of) + e.sounds.map(ItemRef.sound)
        for i in e.images { refs += (i.effects ?? []).map { ItemRef.effect($0, image: i.id) } }
        var out = refs.compactMap(rect(of:)).map { CGRect(x: $0.minX, y: $0.minY - scrollY, width: $0.width, height: $0.height) }
        out.append(CGRect(x: trackRect.minX, y: Self.clipTop - scrollY, width: trackRect.width, height: Self.clipHeight))
        if let p = row(.position) {
            for m in e.moves { out.append(CGRect(x: x(m.t - m.duration), y: p.y - scrollY, width: x(m.t) - x(m.t - m.duration) + 8, height: p.height)) }
        }
        return out
    }

    func slid(_ ref: ItemRef, _ r: CGRect) -> CGRect {
        guard let s = sliding, s.ref == ref else { return r }
        let u = min(1, CACurrentMediaTime() - s.began) / 0.2
        guard u < 1 else { return r }
        let k = CGFloat(Ease.smooth(u))
        return CGRect(x: s.from.minX + (r.minX - s.from.minX) * k, y: s.from.minY + (r.minY - s.from.minY) * k,
                      width: s.from.width + (r.width - s.from.width) * k, height: s.from.height + (r.height - s.from.height) * k)
    }
}

#endif
