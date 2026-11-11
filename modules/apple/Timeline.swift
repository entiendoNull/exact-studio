// `<studio-timeline clip=…>`: the recording's timeline, in source time.
// A ruler; the clip as a filmstrip, its cuts hatched over it; then a track
// each for zooms, speed and effects. Click to seek, click a segment to
// select it, drag it to move, drag an edge to resize; Delete removes the
// selection, Space plays.
#if os(macOS)
import AppKit
import AVFoundation

final class TimelineView: NSView {
    weak var editor: Editor?
    private var thumbs: [CGImage] = []
    private var thumbsFor = ""
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?

    private enum Drag { case scrub, move(String, String, Double, Double, Double), left(String, String, Double, Double), right(String, String, Double, Double) }
    private var drag: Drag?
    private var moved = false

    // Geometry, top-down (the view is flipped).
    private let labelWidth: CGFloat = 86, pad: CGFloat = 14
    private let rulerTop: CGFloat = 10, rulerHeight: CGFloat = 20
    private let clipTop: CGFloat = 34, clipHeight: CGFloat = 56
    private let laneHeight: CGFloat = 28, laneGap: CGFloat = 8
    private static let lanes: [(track: String, label: String, symbol: String, color: NSColor)] = [
        ("zoom", "Zoom", "plus.magnifyingglass", .systemBlue),
        ("speed", "Speed", "gauge.with.dots.needle.67percent", .systemOrange),
        ("effect", "Effects", "sparkles", .systemPurple),
    ]
    static var height: CGFloat { 34 + 56 + 8 + CGFloat(lanes.count) * (28 + 8) + 8 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ editor: Editor?) {
        if let old = self.editor, old !== editor { old.unlisten(self) }
        if let p = observedPlayer, let o = timeObserver { p.removeTimeObserver(o) }
        timeObserver = nil
        self.editor = editor
        guard let editor else { needsDisplay = true; return }
        editor.listen(self) { [weak self] in self?.needsDisplay = true }
        observedPlayer = editor.player
        timeObserver = editor.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        loadThumbs(editor)
        needsDisplay = true
    }

    func detach() { attach(nil) }

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

    private var trackRect: CGRect { CGRect(x: labelWidth, y: 0, width: max(1, bounds.width - labelWidth - pad), height: bounds.height) }
    private func x(_ t: Double) -> CGFloat {
        guard let d = editor?.duration, d > 0 else { return trackRect.minX }
        return trackRect.minX + CGFloat(t / d) * trackRect.width
    }
    private func t(_ x: CGFloat) -> Double {
        guard let d = editor?.duration, d > 0 else { return 0 }
        return Double(min(max((x - trackRect.minX) / trackRect.width, 0), 1)) * d
    }
    private func laneY(_ i: Int) -> CGFloat { clipTop + clipHeight + laneGap + CGFloat(i) * (laneHeight + laneGap) }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.085, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        guard let editor else { return }
        let d = editor.duration

        // The ruler: a tick a second (or every 5 or 10 on long clips), labelled.
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

        // Track labels.
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        drawLabel("Clip", symbol: "film", y: clipTop, height: clipHeight, attrs: label, tint: NSColor(white: 1, alpha: 0.7))
        for (i, lane) in Self.lanes.enumerated() {
            drawLabel(lane.label, symbol: lane.symbol, y: laneY(i), height: laneHeight, attrs: label, tint: lane.color)
        }

        // The clip: a filmstrip.
        let clipRect = CGRect(x: trackRect.minX, y: clipTop, width: trackRect.width, height: clipHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: clipRect, xRadius: 8, yRadius: 8).addClip()
        NSColor(white: 1, alpha: 0.08).setFill()
        clipRect.fill()
        if !thumbs.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            let slot = clipRect.width / CGFloat(thumbs.count)
            for (i, img) in thumbs.enumerated() {
                let cell = CGRect(x: clipRect.minX + CGFloat(i) * slot, y: clipRect.minY, width: slot, height: clipRect.height)
                let k = max(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
                ctx.saveGState()
                ctx.clip(to: cell)
                // The view is flipped: draw the image upright.
                ctx.translateBy(x: cell.midX, y: cell.midY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            NSColor(white: 0, alpha: 0.25).setFill()
            clipRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Cuts over the clip: hatched red.
        for c in editor.edits.cuts {
            let r = CGRect(x: x(c.start), y: clipTop, width: max(2, x(c.end) - x(c.start)), height: clipHeight)
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            path.addClip()
            NSColor.systemRed.withAlphaComponent(0.42).setFill()
            r.fill()
            NSColor(white: 0, alpha: 0.3).setStroke()
            var hx = r.minX - r.height
            while hx < r.maxX {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: hx, y: r.maxY)); line.line(to: CGPoint(x: hx + r.height, y: r.minY))
                line.lineWidth = 3
                line.stroke()
                hx += 10
            }
            NSGraphicsContext.restoreGraphicsState()
            stroke(r, selected: editor.selected == ("cut", c.id), color: .systemRed)
            title("Cut", in: r)
        }

        // The lanes and their segments.
        for (i, lane) in Self.lanes.enumerated() {
            let y = laneY(i)
            NSColor(white: 1, alpha: 0.05).setFill()
            NSBezierPath(roundedRect: CGRect(x: trackRect.minX, y: y, width: trackRect.width, height: laneHeight), xRadius: 7, yRadius: 7).fill()
            for seg in editor.edits[lane.track] {
                let r = CGRect(x: x(seg.start), y: y + 2, width: max(4, x(seg.end) - x(seg.start)), height: laneHeight - 4)
                let selected = editor.selected == (lane.track, seg.id)
                lane.color.withAlphaComponent(selected ? 0.95 : 0.75).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                stroke(r, selected: selected, color: lane.color)
                title(Self.caption(lane.track, seg), in: r)
                // Grips at the edges.
                NSColor(white: 1, alpha: 0.55).setFill()
                if r.width > 24 {
                    NSBezierPath(roundedRect: CGRect(x: r.minX + 3, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
                    NSBezierPath(roundedRect: CGRect(x: r.maxX - 5, y: r.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
                }
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
            tinted.draw(in: CGRect(x: pad, y: y + height / 2 - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (text as NSString).draw(at: CGPoint(x: pad + 20, y: y + height / 2 - 7), withAttributes: attrs)
    }

    private func stroke(_ r: CGRect, selected: Bool, color: NSColor) {
        guard selected else { return }
        NSColor.white.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        p.lineWidth = 2
        p.stroke()
    }

    private func title(_ text: String, in r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        guard r.width > size.width + 16 else { return }
        s.draw(at: CGPoint(x: r.minX + 10, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    static func caption(_ track: String, _ s: Segment) -> String {
        switch track {
        case "zoom":
            let l = s.level ?? 2
            return l < 1 ? "Zoom out \(trim(l))×" : "Zoom \(trim(l))×"
        case "speed":
            let r = s.rate ?? 1
            return r < 1 ? "Slow \(trim(r))×" : "Fast \(trim(r))×"
        case "effect":
            return ["blur": "Blur", "mono": "Black & white", "spotlight": "Spotlight", "highlight": "Cursor highlight"][s.kind ?? ""] ?? "Effect"
        default:
            return "Cut"
        }
    }

    private static func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

    static func clock(_ s: Double, tenths: Bool) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return tenths ? String(format: "%d:%02d.%d", m, sec, Int((s - floor(s)) * 10)) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Interaction

    private func hit(_ p: CGPoint) -> (String, Segment)? {
        guard let editor else { return nil }
        if p.y >= clipTop, p.y <= clipTop + clipHeight {
            if let c = editor.edits.cuts.last(where: { p.x >= x($0.start) - 3 && p.x <= x($0.end) + 3 }) { return ("cut", c) }
            return nil
        }
        for (i, lane) in Self.lanes.enumerated() where p.y >= laneY(i) && p.y <= laneY(i) + laneHeight {
            if let s = editor.edits[lane.track].last(where: { p.x >= x($0.start) - 3 && p.x <= x($0.end) + 3 }) { return (lane.track, s) }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor else { return }
        let p = convert(e.locationInWindow, from: nil)
        moved = false
        if let (track, s) = hit(p) {
            editor.select(track, s.id)
            let edge: CGFloat = 7
            if p.x - x(s.start) < edge && x(s.end) - x(s.start) > edge * 2 { drag = .left(track, s.id, s.start, s.end) }
            else if x(s.end) - p.x < edge && x(s.end) - x(s.start) > edge * 2 { drag = .right(track, s.id, s.start, s.end) }
            else { drag = .move(track, s.id, s.start, s.end, t(p.x)) }
        } else {
            if p.y > clipTop { editor.select("", "") }
            drag = .scrub
            editor.seek(source: t(p.x))
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let editor, let drag else { return }
        let p = convert(e.locationInWindow, from: nil), now = t(p.x)
        moved = true
        switch drag {
        case .scrub:
            editor.seek(source: now)
        case let .move(track, id, s, end, grab):
            let len = end - s
            let start = min(max(s + now - grab, 0), editor.duration - len)
            editor.set(track, id, start: start, end: start + len, commit: false)
        case let .left(track, id, _, end):
            editor.set(track, id, start: min(now, end - 0.1), end: end, commit: false)
        case let .right(track, id, s, _):
            editor.set(track, id, start: s, end: max(now, s + 0.1), commit: false)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let drag, moved, let editor {
            if case .scrub = drag {} else { editor.commitDrag() }
        }
        drag = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func keyDown(with e: NSEvent) {
        guard let editor else { return super.keyDown(with: e) }
        switch e.keyCode {
        case 51, 117: editor.deleteSelected()            // Delete, Forward Delete
        case 49: editor.togglePlay()                      // Space
        case 123: editor.seek(source: editor.playhead - (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        case 124: editor.seek(source: editor.playhead + (e.modifierFlags.contains(.shift) ? 1 : 1.0 / 30))
        default: super.keyDown(with: e)
        }
    }
}

/// The view Exact places.
final class Timeline: ExactNativeInstance {
    private let strip = TimelineView()
    private let studio: Studio
    private var clip = ""

    init(_ studio: Studio, _ props: [String: String], _ events: ExactNativeEvents) {
        self.studio = studio
        super.init(events: events)
        try? setProps(props)
        events.intrinsicSize(CGSize(width: 800, height: TimelineView.height))
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
