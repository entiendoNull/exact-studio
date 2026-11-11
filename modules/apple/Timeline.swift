// `<studio-timeline clip=…>`: the recording's timeline, in source time.
// A ruler; the clip as a filmstrip with its cuts hatched over it; then as
// many lanes as the effects need. Any effect sits on any lane, and effects
// may overlap in time across lanes unless they clash (two zooms, two speed
// changes, two of one visual effect). Click to seek, click a segment to
// select it, drag it to move it (across lanes too: below the last opens a
// new one), drag an edge to resize; Delete removes the selection, Space
// plays, the arrow keys step a frame (Shift: a second).
#if os(macOS)
import AppKit
import AVFoundation

final class TimelineView: NSView {
    weak var editor: Editor?
    var onHeight: (CGFloat) -> Void = { _ in }
    private var thumbs: [CGImage] = []
    private var thumbsFor = ""
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var lastHeight: CGFloat = 0

    private enum Drag { case scrub, move(String, Double, Double, Double), left(String, Double, Double, Int), right(String, Double, Double, Int), retime(String, Double) }
    private var drag: Drag?
    private var moved = false

    // Geometry, top-down (the view is flipped).
    private static let labelWidth: CGFloat = 86, pad: CGFloat = 14
    private static let rulerTop: CGFloat = 10, rulerHeight: CGFloat = 20
    private static let clipTop: CGFloat = 34, clipHeight: CGFloat = 56
    private static let laneHeight: CGFloat = 28, laneGap: CGFloat = 8
    private static let motionTop: CGFloat = clipTop + clipHeight + laneGap, motionHeight: CGFloat = 26
    static func height(lanes: Int) -> CGFloat { motionTop + motionHeight + laneGap + CGFloat(lanes + 1) * (laneHeight + laneGap) + 4 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lanes shown: those in use, and while a segment is dragged, one more to drop it on.
    private var lanesShown: Int {
        guard let editor else { return 1 }
        if case .move = drag { return editor.edits.lanes + 1 }
        return editor.edits.lanes
    }

    func attach(_ editor: Editor?) {
        if let old = self.editor, old !== editor { old.unlisten(self) }
        if let p = observedPlayer, let o = timeObserver { p.removeTimeObserver(o) }
        timeObserver = nil
        self.editor = editor
        guard let editor else { needsDisplay = true; return }
        editor.listen(self) { [weak self] in self?.changed() }
        observedPlayer = editor.player
        timeObserver = editor.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        loadThumbs(editor)
        changed()
    }

    func detach() { attach(nil) }

    /// How much taller (or, negative, shorter) than its content the person made the timeline,
    /// by dragging its top edge; kept between launches. Shorter than its content, it scrolls.
    private var extra = CGFloat(UserDefaults.standard.double(forKey: "ExactStudio.timelineExtra"))
    private var scrollY: CGFloat = 0
    private static let minimum: CGFloat = 120, grip: CGFloat = 8
    private var contentHeight: CGFloat { Self.height(lanes: editor?.edits.lanes ?? 1) }
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

    override func scrollWheel(with e: NSEvent) {
        let room = contentHeight - bounds.height
        guard room > 0 else { return super.scrollWheel(with: e) }
        scrollY = min(max(scrollY - e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8), 0), room)
        needsDisplay = true
    }



    private func loadThumbs(_ editor: Editor) {
        guard thumbsFor != editor.id else { return }
        thumbsFor = editor.id
        thumbs = []
        let generator = AVAssetImageGenerator(asset: editor.asset)
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let n = 14, d = editor.duration, crop = editor.meta.crop, id = editor.id
        let times = (0..<n).map { NSValue(time: CMTime(seconds: d * (Double($0) + 0.5) / Double(n), preferredTimescale: 600)) }
        var got: [Int: CGImage] = [:]
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            guard let image, let i = times.firstIndex(of: NSValue(time: requested)) else { return }
            let r = CGRect(x: crop.x * Double(image.width), y: crop.y * Double(image.height),
                           width: crop.w * Double(image.width), height: crop.h * Double(image.height)).integral
            let cropped = image.cropping(to: r) ?? image
            DispatchQueue.main.async {
                guard let self, self.thumbsFor == id else { return }
                got[i] = cropped
                self.thumbs = (0..<n).compactMap { got[$0] }
                self.needsDisplay = true
            }
        }
    }

    // MARK: Mapping

    private var trackRect: CGRect { CGRect(x: Self.labelWidth, y: 0, width: max(1, bounds.width - Self.labelWidth - Self.pad), height: bounds.height) }
    private func x(_ t: Double) -> CGFloat {
        guard let d = editor?.duration, d > 0 else { return trackRect.minX }
        return trackRect.minX + CGFloat(t / d) * trackRect.width
    }
    private func t(_ x: CGFloat) -> Double {
        guard let d = editor?.duration, d > 0 else { return 0 }
        return Double(min(max((x - trackRect.minX) / trackRect.width, 0), 1)) * d
    }
    private var addLaneRect: CGRect { CGRect(x: trackRect.minX, y: laneY(lanesShown), width: min(trackRect.width, 180), height: Self.laneHeight) }
    private func removeRect(_ lane: Int) -> CGRect { CGRect(x: trackRect.maxX - 22, y: laneY(lane) + 7, width: 14, height: 14) }
    private func laneY(_ i: Int) -> CGFloat { Self.motionTop + Self.motionHeight + Self.laneGap + CGFloat(i) * (Self.laneHeight + Self.laneGap) }
    private func diamond(_ t: Double) -> CGRect { CGRect(x: x(t) - 7, y: Self.motionTop + Self.motionHeight / 2 - 7, width: 14, height: 14) }
    private func lane(at y: CGFloat) -> Int { max(0, Int((y - laneY(0)) / (Self.laneHeight + Self.laneGap))) }

    static func color(_ s: Segment) -> NSColor {
        switch s.kind {
        case "zoom": return (s.level ?? 2) < 1 ? .systemTeal : .systemBlue
        case "speed": return .systemOrange
        case "spotlight": return .systemPurple
        case "highlight": return .systemYellow
        case "blur": return .systemIndigo
        case "mono": return .systemGray
        case "text": return .systemPink
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

        // The ruler: a tick a second (or every 2, 5 or 10 on long clips), labelled.
        let step: Double = d > 120 ? 10 : d > 40 ? 5 : d > 12 ? 2 : 1
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.45)]
        var s = 0.0
        while s <= d + 0.001 {
            let px = x(s)
            NSColor(white: 1, alpha: 0.18).setFill()
            NSRect(x: px, y: rulerTop + rulerHeight - 6, width: 1, height: 6).fill()
            (Self.clock(s, tenths: false) as NSString).draw(at: CGPoint(x: px + 3, y: rulerTop + 2), withAttributes: small)
            s += step
        }

        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        drawLabel("Clip", symbol: "film", y: clipTop, height: clipHeight, attrs: label, tint: NSColor(white: 1, alpha: 0.7))

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
            if !thumbs.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
                // The filmstrip runs across the whole clip; each block shows its own stretch of it.
                let slot = trackRect.width / CGFloat(thumbs.count)
                for (i, img) in thumbs.enumerated() {
                    let cell = CGRect(x: trackRect.minX + CGFloat(i) * slot, y: clipTop, width: slot, height: clipHeight)
                    guard cell.intersects(r) else { continue }
                    let k = max(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                    let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
                    ctx.saveGState()
                    ctx.clip(to: cell)
                    ctx.translateBy(x: cell.midX, y: cell.midY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    ctx.restoreGState()
                }
            }
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

        // The position track: each move's travel, ending in a diamond where it lands.
        let my = Self.motionTop, mh = Self.motionHeight
        drawLabel("Position", symbol: "arrow.up.and.down.and.arrow.left.and.right", y: my, height: mh, attrs: label, tint: .systemTeal)
        NSColor(white: 1, alpha: 0.05).setFill()
        NSBezierPath(roundedRect: CGRect(x: trackRect.minX, y: my, width: trackRect.width, height: mh), xRadius: 7, yRadius: 7).fill()
        if editor.edits.moves.isEmpty {
            let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.35)]
            ("Drag the video in the preview to place it. Add a move to animate it." as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: my + 6), withAttributes: hint)
        }
        for m in editor.edits.moves.sorted(by: { $0.t < $1.t }) {
            let selected = editor.selected == "m:" + m.id
            let bar = CGRect(x: x(m.t - m.duration), y: my + 7, width: max(2, x(m.t) - x(m.t - m.duration)), height: mh - 14)
            NSColor.systemTeal.withAlphaComponent(selected ? 0.85 : 0.45).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
            if selected { stroke(bar.insetBy(dx: -2, dy: -3), selected: true) }
            let name = (["smooth": "Smooth", "linear": "Linear", "spring": "Spring", "zoom": "Zoom through", "swipe": "Swipe",
                         "fade": "Fade", "spin": "Spin", "pop": "Pop"][m.style] ?? m.style) + (m.angles != nil ? " · 3D" : "") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            if bar.width > name.size(withAttributes: attrs).width + 16 { name.draw(at: CGPoint(x: bar.minX + 6, y: bar.minY - 1), withAttributes: attrs) }
            let d = diamond(m.t)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: d.midX, y: d.minY)); path.line(to: CGPoint(x: d.maxX, y: d.midY))
            path.line(to: CGPoint(x: d.midX, y: d.maxY)); path.line(to: CGPoint(x: d.minX, y: d.midY)); path.close()
            (selected ? NSColor.white : NSColor.systemTeal).setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.4).setStroke()
            path.stroke()
        }

        // The lanes.
        let effects = editor.edits.segments
        for i in 0..<lanesShown {
            let y = laneY(i)
            let empty = !effects.contains { $0.lane == i }
            drawLabel("Lane \(i + 1)", symbol: "square.stack", y: y, height: Self.laneHeight, attrs: label, tint: NSColor(white: 1, alpha: 0.5))
            NSColor(white: 1, alpha: i < editor.edits.lanes ? 0.05 : 0.025).setFill()
            NSBezierPath(roundedRect: CGRect(x: trackRect.minX, y: y, width: trackRect.width, height: Self.laneHeight), xRadius: 7, yRadius: 7).fill()
            if empty && editor.edits.lanes > 1 && i < editor.edits.lanes {
                // An empty lane's ×, which removes it.
                let xr = removeRect(i)
                NSColor(white: 1, alpha: 0.12).setFill()
                NSBezierPath(ovalIn: xr).fill()
                ("×" as NSString).draw(at: CGPoint(x: xr.minX + 3.5, y: xr.minY - 1), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.7)])
            }
        }
        // The row that adds a lane.
        let add = addLaneRect
        let addAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
        NSColor(white: 1, alpha: 0.03).setFill()
        let addPath = NSBezierPath(roundedRect: add, xRadius: 7, yRadius: 7)
        addPath.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        addPath.setLineDash([4, 3], count: 2, phase: 0)
        addPath.stroke()
        ("+  Add effect lane" as NSString).draw(at: CGPoint(x: add.minX + 12, y: add.midY - 7), withAttributes: addAttrs)
        if effects.isEmpty {
            let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.35)]
            ("No effects yet. Add one with the Add button above." as NSString).draw(at: CGPoint(x: trackRect.minX + 12, y: laneY(0) + 7), withAttributes: hint)
        }
        for seg in effects {
            let r = CGRect(x: x(seg.start), y: laneY(seg.lane) + 2, width: max(4, x(seg.end) - x(seg.start)), height: Self.laneHeight - 4)
            let selected = editor.selected == seg.id
            Self.color(seg).withAlphaComponent(selected ? 0.95 : 0.78).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            stroke(r, selected: selected)
            title(Self.caption(seg), in: r, dark: seg.kind == "highlight")
            NSColor(white: 1, alpha: 0.55).setFill()
            if r.width > 24 {
                NSBezierPath(roundedRect: CGRect(x: r.minX + 3, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
            }
        }

        // The playhead.
        let ph = x(editor.playhead)
        NSColor.systemRed.setFill()
        NSRect(x: ph - 1, y: rulerTop + 4, width: 2, height: bounds.height - rulerTop - 10).fill()
        let tag = Self.clock(editor.playhead, tenths: true) as NSString
        let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
        let size = tag.size(withAttributes: tagAttrs)
        let pill = CGRect(x: min(max(ph - size.width / 2 - 6, trackRect.minX - 6), bounds.width - size.width - 14), y: rulerTop - 2, width: size.width + 12, height: 17)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8.5, yRadius: 8.5).fill()
        tag.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: tagAttrs)
    }

    private func drawLabel(_ text: String, symbol: String, y: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any], tint: NSColor) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus()
            tint.set()
            CGRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: CGRect(x: Self.pad, y: y + height / 2 - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (text as NSString).draw(at: CGPoint(x: Self.pad + 20, y: y + height / 2 - 7), withAttributes: attrs)
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
        default: return "Effect"
        }
    }

    private static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

    static func clock(_ s: Double, tenths: Bool) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return tenths ? String(format: "%d:%02d.%d", m, sec, Int((s - floor(s)) * 10)) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Interaction

    private func hit(_ p: CGPoint) -> Segment? {
        guard let editor else { return nil }
        let near = { (s: Segment) in p.x >= self.x(s.start) - 4 && p.x <= self.x(s.end) + 4 }
        // The lane under the pointer, counting the gaps between lanes as half each neighbour's.
        guard p.y >= laneY(0) - Self.laneGap / 2 else { return nil }
        let l = min(max(0, Int(((p.y - laneY(0) + Self.laneGap / 2) / (Self.laneHeight + Self.laneGap)).rounded(.down))), lanesShown - 1)
        let onLane = editor.edits.segments.filter { $0.lane == l && near($0) }
        // The selected one first, then the shortest (a short segment over a long one stays reachable).
        return onLane.first { $0.id == editor.selected } ?? onLane.min { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    /// The move under the pointer on the motion track: its diamond, else its travel bar.
    private func moveHit(_ p: CGPoint) -> Move? {
        guard let editor else { return nil }
        if let m = editor.edits.moves.first(where: { diamond($0.t).insetBy(dx: -5, dy: -6).contains(p) }) { return m }
        let at = t(p.x)
        let slop = Double(6 / max(trackRect.width, 1)) * editor.duration
        return editor.edits.moves.filter { at >= $0.t - $0.duration - slop && at <= $0.t + slop }.min { abs($0.t - at) < abs($1.t - at) }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor else { return }
        // The top edge resizes the timeline (and so the preview above it); a double click resets it.
        let p = local(e)
        moved = false
        if addLaneRect.contains(p) { editor.addLane(); return }
        if p.y >= Self.motionTop - Self.laneGap / 2, p.y <= Self.motionTop + Self.motionHeight + Self.laneGap / 2 {
            if let m = moveHit(p) {
                editor.select("m:" + m.id)
                editor.seek(source: m.t)
                // Keep where in the move it was grabbed, so a drag slides it from there.
                drag = .retime(m.id, m.t - t(p.x))
            } else {
                drag = .scrub
                editor.seek(source: t(p.x))
            }
            return
        }
        if let i = (0..<editor.edits.lanes).first(where: { removeRect($0).insetBy(dx: -3, dy: -3).contains(p) }) { editor.removeLane(i); return }
        if p.y >= Self.clipTop, p.y <= Self.clipTop + Self.clipHeight, let piece = editor.pieces.first(where: { t(p.x) >= $0.start && t(p.x) <= $0.end }) {
            // A part of the clip: select it, and seek there.
            editor.select(piece.id)
            drag = .scrub
            editor.seek(source: t(p.x))
            return
        }
        if let s = hit(p) {
            editor.select(s.id)
            let edge: CGFloat = 7, wide = x(s.end) - x(s.start) > edge * 2
            if wide && p.x - x(s.start) < edge { drag = .left(s.id, s.start, s.end, s.lane) }
            else if wide && x(s.end) - p.x < edge { drag = .right(s.id, s.start, s.end, s.lane) }
            else { drag = .move(s.id, s.start, s.end, t(p.x)) }
        } else {
            if p.y > Self.clipTop + Self.clipHeight { editor.select("") }
            drag = .scrub
            editor.seek(source: t(p.x))
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
        switch drag {
        case .scrub:
            editor.seek(source: now)
        case let .retime(id, grab):
            let to = now + grab
            editor.moveTime(id, to: to, live: true)
            editor.seek(source: to)
        case let .move(id, s, end, grab):
            let len = end - s
            let start = min(max(s + now - grab, 0), editor.duration - len)
            editor.drag(id, start: start, end: start + len, lane: min(lane(at: p.y), editor.edits.lanes))
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
        if let drag, moved, let editor {
            switch drag {
            case .scrub: break
            case let .retime(id, _): if let m = editor.edits.moves.first(where: { $0.id == id }) { editor.moveTime(id, to: m.t, live: false) }
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
