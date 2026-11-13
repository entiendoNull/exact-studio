// `<studio-timeline clip=…>`: the recording's timeline, in source time.
// A ruler, then rows in four groups. The video: the clip as a filmstrip with
// its cuts hatched over it, its recorded sound, its Position track and its effect
// lanes. On top of the video: the text lanes, and one row for each image, which
// opens to show that image's own Position and Effects rows. Sound: lanes for the
// sounds added over the video. The whole frame: lanes for a blur or black and
// white over everything. The video's rows and each image's fold
// away. Click to seek, click a block to select it, drag it to move it (to
// another lane of its kind too: below the last opens a new one), drag an edge
// to resize; Delete removes the selection, Space plays, the arrow keys step a
// frame (Shift: a second).
// @ref LLP 0002#rows — what each group holds, and why they fold
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
    private static let labelWidth: CGFloat = 148, pad: CGFloat = 14
    private static let rulerTop: CGFloat = 10, rulerHeight: CGFloat = 20
    private static let clipTop: CGFloat = 34, clipHeight: CGFloat = 56
    private static let laneHeight: CGFloat = 28, laneGap: CGFloat = 8
    private static let motionHeight: CGFloat = 26, headerHeight: CGFloat = 22
    /// How tall the rows are: 0 compact, 1 regular, 2 tall. The person's choice, kept between launches.
    private var size = min(max(UserDefaults.standard.integer(forKey: "ExactStudio.laneSize"), 0), 2)
    private var laneH: CGFloat { [Self.laneHeight, 42, 56][size] }
    private var motionH: CGFloat { [Self.motionHeight, 36, 46][size] }
    static func height(lanes: Int) -> CGFloat { clipTop + clipHeight + laneGap + motionHeight + laneGap + CGFloat(lanes + 1) * (laneHeight + laneGap) + 4 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What a row under the clip is.
    private enum Kind: Equatable {
        /// A group's header, by its key: "top" (texts and images), "sound" or "frame". It folds its group.
        case header(String)
        /// The recording's own sound, under the clip.
        case sound
        /// The video's Position track.
        case position
        /// A lane in a space (`Segment.space`): 0 the video's effects, 1 texts, 3 whole-frame effects;
        /// or a sound lane (`Edits.soundSpace`).
        case lane(Int, Int)
        /// An image's own row, and under it, while it is open, its Position row and its effect rows.
        case image(String), imagePosition(String), imageEffects(String, Int)
    }
    private struct Row { let kind: Kind; let y: CGFloat; let height: CGFloat
        var maxY: CGFloat { y + height } }

    /// The space of the segment being dragged, or nil when none is.
    private var draggedSpace: Int? {
        if case .sound(_, 0, _, _, _, _, _) = drag { return Edits.soundSpace }
        guard case let .move(id, _, _, _) = drag else { return nil }
        return editor?.edits.segments.first { $0.id == id }?.space
    }

    /// The rows under the clip, top-down. While a block is dragged, its kind has one more lane to drop it on.
    /// A folded group shows only its header.
    private var rows: [Row] {
        var out: [Row] = []
        var y = Self.clipTop + Self.clipHeight + Self.laneGap
        func add(_ kind: Kind, _ height: CGFloat) { out.append(Row(kind: kind, y: y, height: height)); y += height + Self.laneGap }
        guard let editor else { add(.lane(0, 0), laneH); return out }
        let e = editor.edits, dragged = draggedSpace
        if editor.videoOpen {
            // @ref LLP 0002#sound — the recorded sound is part of the clip, so it sits with it
            if editor.hasSound { add(.sound, laneH) }
            add(.position, motionH)
            for l in 0..<e.lanes + (dragged == 0 ? 1 : 0) { add(.lane(0, l), laneH) }
        }
        add(.header("top"), Self.headerHeight)
        if !editor.folded.contains("top") {
            for l in 0..<e.textLanes + (dragged == 1 ? 1 : 0) { add(.lane(1, l), laneH) }
            for image in e.images.sorted(by: { $0.lane < $1.lane }) {
                add(.image(image.id), laneH)
                guard editor.openImages.contains(image.id) else { continue }
                add(.imagePosition(image.id), motionH)
                var lanes = max(1, ((image.effects ?? []).map(\.lane).max() ?? -1) + 1)
                if case let .fx(id, _, 0, _, _, _, _) = drag, id == image.id { lanes += 1 }
                for l in 0..<lanes { add(.imageEffects(image.id, l), laneH) }
            }
        }
        add(.header("sound"), Self.headerHeight)
        if !editor.folded.contains("sound") {
            for l in 0..<e.soundLanes + (dragged == Edits.soundSpace ? 1 : 0) { add(.lane(Edits.soundSpace, l), laneH) }
        }
        add(.header("frame"), Self.headerHeight)
        if !editor.folded.contains("frame") {
            for l in 0..<e.frameLanes + (dragged == 3 ? 1 : 0) { add(.lane(3, l), laneH) }
        }
        return out
    }
    private func row(_ kind: Kind) -> Row? { rows.first { $0.kind == kind } }
    /// The row under `y`, counting the gaps between rows as half each neighbour's.
    private func row(at y: CGFloat) -> Row? { rows.first { y >= $0.y - Self.laneGap / 2 && y < $0.maxY + Self.laneGap / 2 } }
    /// The row a top-level segment is drawn on.
    private func row(of s: Segment) -> Row? { row(s.kind == "image" ? .image(s.id) : .lane(s.space, s.lane)) }
    /// Whether a lane exists in the edits, not only as a place to drop on.
    private func real(_ space: Int, _ lane: Int) -> Bool { lane < (editor?.edits.laneCount(space: space) ?? 1) }

    func attach(_ editor: Editor?) {
        if let old = self.editor, old !== editor { old.unlisten(self) }
        if let p = observedPlayer, let o = timeObserver { p.removeTimeObserver(o) }
        timeObserver = nil
        self.editor = editor
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
    private var extra = CGFloat(UserDefaults.standard.double(forKey: "ExactStudio.timelineExtra"))
    private var scrollY: CGFloat = 0
    private static let minimum: CGFloat = 120, grip: CGFloat = 8
    private var contentHeight: CGFloat { (rows.last?.maxY ?? Self.height(lanes: 1)) + 8 }
    private var resizing: (start: CGFloat, extra: CGFloat)?

    private func changed() {
        needsDisplay = true
        let h = contentHeight
        scrollY = min(max(scrollY, 0), max(0, contentHeight - bounds.height))
        if h != lastHeight { lastHeight = h; onHeight(h) }
    }

    /// A mouse event's point in the content, which scrolls under the view.
    private func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: p.y + scrollY)
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
    /// Whether a row has a + that adds to it: the Position rows, the first lane of the video's
    /// effects, the groups' headers, and an image's first effects row.
    private func hasPlus(_ r: Row) -> Bool {
        switch r.kind {
        case .position, .header, .imagePosition, .lane(0, 0), .imageEffects(_, 0): return true
        default: return false
        }
    }
    /// At the end of the row's label, every row's in one column just left of the track.
    private func plusRect(_ r: Row) -> CGRect {
        return CGRect(x: Self.labelWidth - 28, y: r.y + r.height / 2 - 9, width: 18, height: 18)
    }
    /// The three lane sizes, in the corner above the labels.
    private func sizeRect(_ i: Int) -> CGRect { CGRect(x: Self.pad + CGFloat(i) * 24, y: Self.rulerTop, width: 22, height: 18) }

    private func removeRect(_ r: Row) -> CGRect { CGRect(x: trackRect.maxX - 22, y: r.y + 7, width: 14, height: 14) }
    /// An empty lane can go, but one effect lane always stays.
    private func removable(_ r: Row) -> Bool {
        guard let e = editor?.edits, case let .lane(space, lane) = r.kind, real(space, lane) else { return false }
        if space == Edits.soundSpace { return !e.sounds.contains { $0.lane == lane } }
        return !e.segments.contains { $0.space == space && $0.lane == lane } && (space != 0 || e.lanes > 1)
    }
    private func diamond(_ t: Double, in r: Row) -> CGRect { CGRect(x: x(t) - 7, y: r.y + r.height / 2 - 7, width: 14, height: 14) }

    /// The lane a dragged top-level segment would drop on at `y`: one of its own kind, or one past
    /// the last; for an image, the row among the images it would take.
    private func lane(at y: CGFloat, for s: Segment) -> Int {
        guard let e = editor?.edits else { return 0 }
        if s.kind == "image" {
            // Each image's rows, its own and its children's, count as that image's place.
            var place = 0
            for r in rows {
                if case let .image(id) = r.kind, let other = e.images.first(where: { $0.id == id }), y >= r.y - Self.laneGap / 2 { place = other.lane }
            }
            return place
        }
        return lane(at: y, space: s.space)
    }

    /// The lane of a space a dragged block would drop on at `y`, or one past the last.
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
    static let soundColor = NSColor(srgbRed: 0.73, green: 0.51, blue: 0.18, alpha: 1)

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
                let track = bounds.height - 24, k = bounds.height / contentHeight
                NSColor(white: 1, alpha: 0.2).setFill()
                NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 6, y: 12 + scrollY * k * track / bounds.height, width: 3, height: max(16, track * k)), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        guard let editor else { return }
        // The view's height is the person's (the handle above it): keep the scroll inside the content.
        scrollY = min(max(scrollY, 0), max(0, contentHeight - bounds.height))
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: -scrollY)
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
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: trackClip).addClip()
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

        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        // The lane sizes: three bars, thin to thick; the chosen one lit.
        for i in 0..<3 {
            let b = sizeRect(i)
            NSColor(white: 1, alpha: i == size ? 0.16 : 0.05).setFill()
            NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
            NSColor(white: 1, alpha: i == size ? 0.9 : 0.45).setFill()
            let h = CGFloat(3 + i * 3)
            NSBezierPath(roundedRect: CGRect(x: b.minX + 5, y: b.midY - h / 2, width: b.width - 10, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        drawLabel("Clip", symbol: "film", y: clipTop, height: clipHeight, attrs: label, tint: NSColor(white: 1, alpha: 0.7), open: editor.videoOpen)
        // From here to the playhead, labels and +s wait in `labelQueue` and are drawn after, unclipped.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: trackClip).addClip()
        labelQueue = []

        // The clip: each part its own rounded block of filmstrip, a clear gap between parts,
        // a scissors pin over each split; a removed part dark and hatched.
        let gap: CGFloat = 4
        let amber = NSColor(srgbRed: 0.93, green: 0.63, blue: 0.22, alpha: 1)
        for piece in editor.pieces {
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
                amber.withAlphaComponent(0.22).setFill()
                r.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            (piece.removed ? NSColor(white: 1, alpha: 0.12) : amber.withAlphaComponent(0.9)).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            if piece.removed { title("Removed", in: r) }
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
        func block(_ r: CGRect, _ color: NSColor, _ text: String, selected: Bool, dark: Bool = false, inside: ((CGRect) -> Void)? = nil) {
            color.withAlphaComponent(selected ? 0.95 : 0.78).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            inside?(r)
            stroke(r, selected: selected)
            // Zoomed, a block's name stays in the part of it that shows.
            let from = max(r.minX, trackRect.minX), to = min(r.maxX, trackRect.maxX)
            title(text, in: CGRect(x: from, y: r.minY, width: max(0, to - from), height: r.height), dark: dark)
            NSColor(white: 1, alpha: 0.55).setFill()
            if r.width > 24 {
                NSBezierPath(roundedRect: CGRect(x: r.minX + 3, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
            }
        }
        for r in shown {
            switch r.kind {
            case let .header(group):
                let isFolded = editor.folded.contains(group)
                drawLabel(group == "top" ? "ON TOP" : group == "sound" ? "SOUND" : "WHOLE FRAME", symbol: "", y: r.y, height: r.height, attrs: caption, tint: .clear, open: !isFolded, plus: true)
                // What the group holds, as spans in recording time, in row order.
                typealias Item = (start: Double, end: Double, order: Int, color: NSColor)
                let items: [Item] = group == "sound"
                    ? editor.edits.sounds.map { ($0.start, $0.end(editor.map), $0.lane, Self.soundColor) }
                    : segments.filter({ group == "top" ? $0.isOverlay : $0.space == 3 }).map { ($0.start, $0.end, $0.kind == "image" ? 1000 + $0.lane : $0.lane, Self.color($0)) }
                if isFolded {
                    // Folded, the group still shows where its things are: slim bars in the track, in row
                    // order, each on the first of up to three sub-lines where it overlaps nothing, so
                    // things at the same time stay apart. Touching ones of a colour join into one bar.
                    let overlap = { (a: Item, b: Item) in a.start < b.end - 0.0001 && b.start < a.end - 0.0001 }
                    var lines: [[Item]] = [[]]
                    for item in items.sorted(by: { ($0.order, $0.start) < ($1.order, $1.start) }) {
                        if let i = lines.firstIndex(where: { !$0.contains { overlap($0, item) } }) { lines[i].append(item) }
                        else if lines.count < 3 { lines.append([item]) }
                        else { lines[2].append(item) }
                    }
                    let bar: CGFloat = 3, step: CGFloat = 5, top = r.y + r.height / 2 - (CGFloat(lines.count - 1) * step + bar) / 2
                    for (i, line) in lines.enumerated() {
                        var runs: [(from: CGFloat, to: CGFloat, color: NSColor)] = []
                        for item in line.sorted(by: { $0.start < $1.start }) {
                            let from = x(item.start), to = max(from + 3, x(item.end)), color = item.color
                            if let last = runs.last, last.color == color, from <= last.to + 2 { runs[runs.count - 1].to = max(last.to, to) }
                            else { runs.append((from, to, color)) }
                        }
                        for run in runs {
                            run.color.withAlphaComponent(0.6).setFill()
                            NSBezierPath(roundedRect: CGRect(x: run.from, y: top + CGFloat(i) * step, width: run.to - run.from, height: bar), xRadius: 1.5, yRadius: 1.5).fill()
                        }
                    }
                } else if items.isEmpty, editor.edits.laneCount(space: group == "top" ? 1 : group == "sound" ? Edits.soundSpace : 3) == 0 {
                    ((group == "top" ? "Press + to put a text or an image on top of the video."
                        : group == "sound" ? "Press + to add music or another sound."
                        : "Press + to blur the whole picture, or make it black and white.") as NSString)
                        .draw(at: CGPoint(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7), withAttributes: hint)
                }
            case .sound:
                // The recorded sound across the recording, its removed parts dimmed as the clip's are.
                let selected = editor.selected == Editor.recordedSound
                drawLabel("Sound", symbol: "waveform", y: r.y, height: r.height, attrs: label, tint: NSColor(white: 1, alpha: 0.5))
                bed(r, alpha: selected ? 0.1 : 0.05)
                if let wave = Waveform.of(editor.asset.url, ready: { [weak self] in self?.needsDisplay = true }) {
                    drawWave(wave, in: CGRect(x: trackRect.minX, y: r.y + 3, width: trackRect.width, height: r.height - 6),
                             alpha: editor.edits.volume <= 0.001 ? 0.14 : 0.42) { t in t }
                }
                for piece in editor.pieces where piece.removed {
                    NSColor(calibratedWhite: 0.085, alpha: 0.78).setFill()
                    CGRect(x: x(piece.start), y: r.y, width: x(piece.end) - x(piece.start), height: r.height).fill()
                }
                if selected { stroke(CGRect(x: trackRect.minX, y: r.y, width: trackRect.width, height: r.height), selected: true) }
            case .position:
                drawLabel("Position", symbol: "arrow.up.and.down.and.arrow.left.and.right", y: r.y, height: r.height, attrs: label, tint: .systemTeal, plus: true)
                bed(r)
                if editor.edits.moves.isEmpty {
                    ("Drag the video in the preview to place it. Press + to add a move that animates it." as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7), withAttributes: hint)
                }
                for m in editor.edits.moves.sorted(by: { $0.t < $1.t }) { draw(move: m, in: r, selected: editor.selected == "m:" + m.id, threeD: m.angles != nil) }
            case let .lane(space, lane):
                let name = space == 1 ? "Text" : space == 3 ? "Whole Frame" : space == Edits.soundSpace ? "Sound" : "Effects"
                drawLabel("\(name) \(lane + 1)", symbol: space == 1 ? "textformat" : space == 3 ? "rectangle.inset.filled" : space == Edits.soundSpace ? "music.note" : "wand.and.stars",
                          y: r.y, height: r.height, attrs: label, tint: NSColor(white: 1, alpha: 0.5), plus: hasPlus(r))
                bed(r, alpha: real(space, lane) ? 0.05 : 0.025)
                if removable(r) {
                    // An empty lane's ×, which removes it.
                    let xr = removeRect(r)
                    NSColor(white: 1, alpha: 0.12).setFill()
                    NSBezierPath(ovalIn: xr).fill()
                    ("×" as NSString).draw(at: CGPoint(x: xr.minX + 3.5, y: xr.minY - 1), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.7)])
                }
                let empty = space == Edits.soundSpace ? editor.edits.sounds.isEmpty : !segments.contains(where: { $0.space == space })
                if lane == 0, real(space, lane), empty {
                    let words = space == 1 ? "Texts go here. They sit on top of the video."
                        : space == Edits.soundSpace ? "Press + to add music or another sound."
                        : space == 3 ? "A blur or black and white here covers the whole picture."
                        : "Press + to add an effect that changes the video: zoom, speed, blur and more."
                    (words as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7), withAttributes: hint)
                }
            case let .image(id):
                guard let image = images.first(where: { $0.id == id }) else { continue }
                drawLabel(URL(fileURLWithPath: image.file ?? "Image").deletingPathExtension().lastPathComponent, symbol: "photo", y: r.y, height: r.height,
                          attrs: label, tint: .systemGreen, open: editor.openImages.contains(id))
                bed(r)
            case let .imagePosition(id):
                guard let image = images.first(where: { $0.id == id }) else { continue }
                drawLabel("Position", symbol: "", y: r.y, height: r.height, attrs: child, tint: .clear, indent: 22, plus: true)
                bed(r, alpha: 0.035)
                if (image.moves ?? []).isEmpty {
                    ("Drag the image in the preview to place it. Press + to add a move that animates it." as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7), withAttributes: hint)
                }
                for m in (image.moves ?? []).sorted(by: { $0.t < $1.t }) {
                    draw(move: m, in: r, selected: editor.selected == Editor.childID("im", image: id, m.id), threeD: false)
                }
            case let .imageEffects(id, lane):
                guard let image = images.first(where: { $0.id == id }) else { continue }
                drawLabel(lane == 0 ? "Effects" : "", symbol: "", y: r.y, height: r.height, attrs: child, tint: .clear, indent: 22, plus: true)
                bed(r, alpha: 0.035)
                if lane == 0, (image.effects ?? []).isEmpty {
                    ("Press + to add an effect to this image only: blur, fade, pulse and more." as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: r.y + r.height / 2 - 7), withAttributes: hint)
                }
                for fx in image.effects ?? [] where fx.lane == lane {
                    let b = CGRect(x: x(fx.start), y: r.y + 2, width: max(4, x(fx.end) - x(fx.start)), height: r.height - 4)
                    block(b, Self.color(image: fx), Self.caption(image: fx), selected: editor.selected == Editor.childID("ie", image: id, fx.id))
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
        }
        for seg in segments {
            guard let r = row(of: seg) else { continue }
            let b = CGRect(x: x(seg.start), y: r.y + 2, width: max(4, x(seg.end) - x(seg.start)), height: r.height - 4)
            // An image stays lit while one of its own moves or effects is selected.
            let selected = editor.selected == seg.id || (seg.kind == "image" && editor.selectedImage?.id == seg.id)
            block(b, Self.color(seg), Self.caption(seg), selected: selected, dark: seg.kind == "highlight")
        }
        // The added sounds: each from its start for as long as it plays in the video, its file's
        // waveform inside, faint, at the moment of the file that plays there.
        let map = editor.map
        for snd in editor.edits.sounds {
            guard let r = row(.lane(Edits.soundSpace, snd.lane)) else { continue }
            let b = CGRect(x: x(snd.start), y: r.y + 2, width: max(4, x(snd.end(map)) - x(snd.start)), height: r.height - 4)
            let from = map.output(snd.start) - snd.offset
            block(b, Self.soundColor, URL(fileURLWithPath: snd.file).lastPathComponent, selected: editor.selected == Editor.soundID(snd.id)) { box in
                guard let wave = Waveform.of(editor.folder.appendingPathComponent(snd.file), ready: { [weak self] in self?.needsDisplay = true }) else { return }
                self.drawWave(wave, in: box.insetBy(dx: 6, dy: max(3, box.height * 0.2)), alpha: 0.3) { t in map.output(t) - from }
            }
        }

        // The playhead.
        let ph = x(editor.playhead)
        NSColor.systemRed.setFill()
        NSRect(x: ph - 1, y: rulerTop + 4, width: 2, height: bounds.height - rulerTop - 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        let labels = labelQueue ?? []
        labelQueue = nil
        labels.forEach { $0() }
        // Zoomed in, a slim bar along the bottom shows which part of the recording is in view.
        if editor.zoomed, let b = panBar, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: scrollY)
            NSColor(white: 1, alpha: 0.2).setFill()
            NSBezierPath(roundedRect: b, xRadius: 1.5, yRadius: 1.5).fill()
            ctx.restoreGState()
        }
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
        let room = Self.labelWidth - at - (plus ? 32 : 8)
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

    /// A move on a Position row: its travel as a bar, ending in a diamond where it lands.
    private func draw(move m: Move, in r: Row, selected: Bool, threeD: Bool) {
        let bar = CGRect(x: x(m.t - m.duration), y: r.y + 7, width: max(2, x(m.t) - x(m.t - m.duration)), height: r.height - 14)
        NSColor.systemTeal.withAlphaComponent(selected ? 0.85 : 0.45).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        if selected { stroke(bar.insetBy(dx: -2, dy: -3), selected: true) }
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
    }

    private func stroke(_ r: CGRect, selected: Bool) {
        guard selected else { return }
        NSColor.white.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        p.lineWidth = 2
        p.stroke()
    }

    private func title(_ text: String, in r: CGRect, dark: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: dark ? NSColor.black : NSColor.white]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        guard r.width > size.width + 16 else { return }
        s.draw(at: CGPoint(x: r.minX + 10, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    static func caption(_ s: Segment) -> String {
        switch s.kind {
        case "zoom":
            let l = s.level ?? 2
            return l < 1 ? "Zoom out \(trim(l))×" : "Zoom in \(trim(l))×"
        case "speed":
            let r = s.rate ?? 1
            return r < 1 ? "Slow \(trim(r))×" : "Fast \(trim(r))×"
        case "spotlight": return "Spotlight"
        case "highlight": return "Cursor highlight"
        case "blur": return s.scope == "frame" ? "Blur · whole frame" : "Blur"
        case "mono": return s.scope == "frame" ? "Black & white · whole frame" : "Black & white"
        case "3d": return s.style == "orbit" ? "3D orbit" : "3D turn"
        case "text": return "“\(s.text ?? "")”"
        case "image":
            let moves = s.moves?.count ?? 0, effects = s.effects?.count ?? 0
            let name = URL(fileURLWithPath: s.file ?? "").lastPathComponent
            return name + (moves > 0 ? " · \(moves) move\(moves == 1 ? "" : "s")" : "") + (effects > 0 ? " · \(effects) effect\(effects == 1 ? "" : "s")" : "")
        default: return "Effect"
        }
    }

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
        case let .image(id): onRow = editor.edits.segments.filter { $0.id == id && near($0) }
        default: return nil
        }
        // The selected one first, then the shortest (a short segment over a long one stays reachable).
        return onRow.first { $0.id == editor.selected } ?? onRow.min { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    /// The move under the pointer on a Position row: its diamond, else its travel bar.
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

    /// A menu under a row's +: titles and what each does; a nil action is a caption, "-" a line.
    private func popUp(_ items: [(String, (() -> Void)?)], under r: CGRect) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in items {
            if title == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            item.representedObject = action.map(Act.init)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: r.minX, y: r.maxY - scrollY + 4), in: self)
    }

    /// What a row's + offers, at the playhead.
    private func showAdd(for r: Row) {
        guard let editor else { return }
        let at = plusRect(r)
        switch r.kind {
        case .position:
            popUp([("Add Move Here — then drag the video where it should go", { editor.addMove() }), ("-", nil),
                   ("Side to Side", { editor.pattern("side") }), ("Zoom Tour", { editor.pattern("tour") }), ("Entrance", { editor.pattern("entrance") }),
                   ("Bounce", { editor.pattern("bounce") }), ("Slow Push In", { editor.pattern("drift") }), ("-", nil),
                   ("3D Turntable", { editor.pattern("turntable") }), ("3D Orbit", { editor.pattern("orbit") }), ("3D Hero Reveal", { editor.pattern("reveal") }),
                   ("3D Flip In", { editor.pattern("flip") }), ("3D Float", { editor.pattern("float") })], under: at)
        case .lane(0, _):
            popUp([("Effects on the video", nil),
                   ("Zoom In", { editor.add("zoom-in") }), ("Zoom Out", { editor.add("zoom-out") }), ("Zoom on Clicks", { editor.autoZoom() }), ("-", nil),
                   ("Slow Down", { editor.add("slow") }), ("Speed Up", { editor.add("fast") }), ("-", nil),
                   ("Spotlight", { editor.add("spotlight") }), ("Cursor Highlight", { editor.add("highlight") }),
                   ("Blur", { editor.add("blur") }), ("Black & White", { editor.add("mono") }), ("-", nil),
                   ("3D Turn", { editor.add("3d") }), ("-", nil), ("New Effects Lane", { editor.addLane(space: 0) })], under: at)
        case .header("top"):
            popUp([("Text", { editor.add("text") }), ("Image…", { Pictures.pick { editor.addImage($0) } }), ("-", nil),
                   ("New Text Lane", { editor.addLane(space: 1) })], under: at)
        case .header("sound"):
            popUp([("Sound File…", { Sounds.pick { editor.addSound($0) } }), ("-", nil),
                   ("New Sound Lane", { editor.addLane(space: Edits.soundSpace) })], under: at)
        case .header:
            popUp([("Over the whole picture", nil), ("Blur", { editor.add("blur-frame") }), ("Black & White", { editor.add("mono-frame") }), ("-", nil),
                   ("New Whole-Frame Lane", { editor.addLane(space: 3) })], under: at)
        case let .imagePosition(id):
            editor.select(id)
            editor.addImageMove()
        case let .imageEffects(id, _):
            let add = { (kind: String) in { editor.select(id); editor.addImageEffect(kind) } }
            popUp([("Effects on this image", nil), ("Blur", add("blur")), ("Black & White", add("mono")), ("Fade", add("fade")), ("-", nil),
                   ("Pulse", add("pulse")), ("Float", add("float")), ("Wiggle", add("wiggle"))], under: at)
        default: break
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
        if p.y < Self.clipTop, p.x < Self.labelWidth {
            if let i = (0..<3).first(where: { sizeRect($0).insetBy(dx: -1, dy: -3).contains(p) }) {
                size = i
                UserDefaults.standard.set(i, forKey: "ExactStudio.laneSize")
                changed()
            }
            return
        }
        // The clip: its label folds the video's rows; a part of it is selected, and the playhead goes there.
        if p.y >= Self.clipTop, p.y <= Self.clipTop + Self.clipHeight {
            if p.x < Self.labelWidth { return editor.toggle(group: "video") }
            if let piece = editor.pieces.first(where: { t(p.x) >= $0.start && t(p.x) <= $0.end }) { editor.select(piece.id) }
            return scrub()
        }
        guard let r = row(at: p.y) else {
            if p.y > Self.clipTop + Self.clipHeight { editor.select("") }
            return scrub()
        }
        if hasPlus(r), plusRect(r).insetBy(dx: -4, dy: -4).contains(p) { return showAdd(for: r) }
        switch r.kind {
        case let .header(group):
            if p.x < Self.labelWidth { editor.toggle(group: group) } else { scrub() }
        case .sound:
            editor.select(Editor.recordedSound)
            if p.x >= Self.labelWidth { scrub() }
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
            guard let image = editor.edits.images.first(where: { $0.id == id }) else { return }
            let on = (image.effects ?? []).filter { $0.lane == lane && p.x >= trackRect.minX - 4 && p.x >= x($0.start) - 4 && p.x <= x($0.end) + 4 }
            guard let fx = on.min(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return scrub() }
            editor.select(Editor.childID("ie", image: id, fx.id))
            let edge: CGFloat = 7, wide = x(fx.end) - x(fx.start) > edge * 2
            let mode = wide && p.x - x(fx.start) < edge ? -1 : wide && x(fx.end) - p.x < edge ? 1 : 0
            drag = .fx(id, fx.id, mode, fx.start, fx.end, fx.lane, t(p.x))
        case .lane, .image:
            if removable(r), removeRect(r).insetBy(dx: -3, dy: -3).contains(p), case let .lane(space, lane) = r.kind {
                return editor.removeLane(lane, space: space)
            }
            // An image's label folds its rows, and selects it.
            if case let .image(id) = r.kind, p.x < Self.labelWidth {
                let wasOpen = editor.openImages.contains(id), wasSelected = editor.selectedImage?.id == id
                editor.select(id)
                if wasOpen == editor.openImages.contains(id) || wasSelected { editor.toggleImage(id) }
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
                guard let span = editor.edits.images.first(where: { $0.id == image }) else { return }
                let len = end - s
                let start = min(max(s + now - grab, span.start), span.end - len)
                editor.dragImageEffect(image, id, start: start, end: start + len, lane: fxLane(at: p.y, image: image))
            }
        case let .move(id, s, end, grab):
            guard let seg = editor.edits.segments.first(where: { $0.id == id }) else { return }
            let len = end - s
            let start = min(max(s + now - grab, 0), editor.duration - len)
            editor.drag(id, start: start, end: start + len, lane: lane(at: p.y, for: seg))
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
            UserDefaults.standard.set(Double(extra), forKey: "ExactStudio.timelineExtra")
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
            default: editor.endDrag()
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
        case 1: editor.splitClip()                        // S
        case 123: editor.seek(source: editor.playhead - (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        case 124: editor.seek(source: editor.playhead + (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        default: super.keyDown(with: e)
        }
    }
}

/// The view Exact places; its height follows the lanes.
final class Timeline: ExactNativeInstance {
    private let strip = TimelineView()
    private let studio: Studio
    private var clip = ""

    init(_ studio: Studio, _ props: [String: String], _ events: ExactNativeEvents) {
        self.studio = studio
        super.init(events: events)
        strip.onHeight = { h in events.intrinsicSize(CGSize(width: 800, height: h)) }
        events.intrinsicSize(CGSize(width: 800, height: TimelineView.height(lanes: 1)))
        try? setProps(props)
    }

    override var view: ExactNativeView { strip }

    override func setProps(_ props: [String: String]) throws {
        let next = props["clip"] ?? ""
        guard next != clip else { return }
        clip = next
        strip.attach(studio.editor(next))
    }

    override func destroy() { strip.detach() }
}
#endif
