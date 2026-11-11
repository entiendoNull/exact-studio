// Exact Studio's native module: what app.ts asks (`native.call` / `later`)
// and its views, `studio-preview` and `studio-timeline`. Topics app.ts
// watches: "status" (recording or not), "recordings" (the library changed)
// and "edits" (a recording's edits or selection changed).
//
//   call   {op: "status"}                       → {recording, name, kind}
//          {op: "selection", id}                → {id, kind ("clip" for a part of the clip), level, rate, start, end,
//                                                   startText, endText, removed, first, last, problem}
//          {op: "summary", id}                  → {parts, removed, effects, lanes, length, source}
//   later  {op: "sources"}                      → {items: [{id, name, app, kind}], allowed}
//          {op: "start", source}                → {ok, error}   source "area" opens the picker
//          {op: "stop"}                         → {ok, error, id}
//          {op: "recordings"}                   → {items: [{id, name, kind, created, duration}]}
//          {op: "edit", id, do, track?, number?, kind?}  → {ok}
//                 do: add (track: a kind, or zoom-in, zoom-out, slow, fast), set (number | kind),
//                     delete, split, auto, clear, play, split-clip, remove, join-prev, join-next,
//                     add-lane, start / end (kind: the typed time)
//          {op: "export", id, look}             → {ok, error, path}
//          {op: "delete", id}                   → {ok, error}
//          {op: "reveal", path}                 → {ok}
//          {op: "crop", id, edge, by}           → {ok}  nudges a recording's crop by `by` (unit) at an edge
#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import ScreenCaptureKit

final class Studio: ExactModule {
    override class var views: [String: ExactNativeFactory] {
        [
            "studio-preview": ExactNativeFactory(for: Studio.self) { studio, props, events in Preview(studio, props, events) },
            "studio-timeline": ExactNativeFactory(for: Studio.self) { studio, props, events in Timeline(studio, props, events) },
            "studio-color": ExactNativeFactory(for: Studio.self) { _, props, events in ColorWell(props, events) },
        ]
    }

    private var recorder: Recorder?
    private var starting = false
    private var picker: AreaPicker?
    private var statusItem: NSStatusItem?
    private var editors: [String: Editor] = [:]

    required init(context: ExactModuleContext) {
        super.init(context: context)
        if context.agent {
            Library.scratch = context.data.appendingPathComponent("Exact Studio", isDirectory: true)
            print("exact-studio library: \(Library.root.path)")
        }
    }

    /// The open recording's editor, made on first use.
    func editor(_ id: String) -> Editor? {
        guard !id.isEmpty, !id.contains("/") else { return nil }
        if let e = editors[id] { return e }
        guard let e = Editor(id: id) else { return nil }
        e.onChange = { [weak self] in self?.context.changed("edits") }
        editors[id] = e
        return e
    }

    private static let emptySelection: [String: Any] = [
        "id": "", "kind": "", "level": 0, "rate": 0, "start": 0, "end": 0, "startText": "", "endText": "", "removed": false, "first": false,
        "last": false, "transition": "cut", "text": "", "size": 0, "color": "", "weight": "", "style": "", "animIn": "", "animOut": "", "loop": "",
        "rotation": 0, "moveStyle": "", "duration": 0, "scale": 0, "tilt": 0, "turn": 0, "roll": 0, "hasAngles": false, "problem": "",
    ]
    private static let emptySummary: [String: Any] = [
        "parts": 1, "removed": 0, "effects": 0, "lanes": 1, "moves": 0, "length": 0, "source": 0, "playing": false,
        "device": false, "found": false, "cursorDrawn": false, "baseScale": 100,
        "threeOn": false, "tilt": 0, "turn": 0, "roll": 0, "thickness": 5, "edge": "metal",
    ]

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status":
            return ["recording": recorder != nil, "name": recorder?.name ?? "", "kind": recorder?.kind.rawValue ?? ""]
        case "selection":
            return editor(request["id"] as? String ?? "")?.selection ?? Self.emptySelection
        case "summary":
            return editor(request["id"] as? String ?? "")?.summary ?? Self.emptySummary
        default:
            throw ExactNativeRefusal("studio answers status, selection and summary")
        }
    }

    override func later(_ request: [String: Any], reply: ExactReply) {
        let op = request["op"] as? String ?? ""
        switch op {
        case "sources":
            let allowed = CGPreflightScreenCaptureAccess()
            if !allowed && !context.agent { CGRequestScreenCaptureAccess() }
            Task {
                do { reply.send(["items": try await Sources.list(), "allowed": allowed]) }
                catch { reply.send(["items": [], "allowed": false]) }
            }
        case "start":
            start(request["source"] as? String ?? "", reply: reply)
        case "stop":
            stop(reply: reply)
        case "recordings":
            let items: [[String: Any]] = Library.all().map {
                ["id": $0.id, "name": $0.name, "kind": $0.kind, "created": $0.created, "duration": $0.duration]
            }
            reply.send(["items": items])
        case "edit":
            edit(request)
            reply.send(["ok": true])
        case "export":
            export(id: request["id"] as? String ?? "", look: Look.parse(request["look"] as? String ?? "{}"), reply: reply)
        case "delete":
            let id = request["id"] as? String ?? ""
            guard !id.isEmpty, !id.contains("/") else { return reply.send(["ok": false, "error": "No such recording."]) }
            if let e = editors.removeValue(forKey: id) { e.player.pause(); e.player.replaceCurrentItem(with: nil) }
            try? FileManager.default.removeItem(at: Library.recordings.appendingPathComponent(id))
            context.changed("recordings")
            reply.send(["ok": true, "error": ""])
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: request["path"] as? String ?? Library.root.path)])
            reply.send(["ok": true])
        case "crop":
            nudge(id: request["id"] as? String ?? "", edge: request["edge"] as? String ?? "", by: request["by"] as? Double ?? 0)
            reply.send(["ok": true])
        default:
            reply.fail("studio answers no \(op)")
        }
    }

    /// "1.25", "0:01.25" or "1:02" as seconds; nil when it is none of those.
    static func seconds(_ text: String?) -> Double? {
        let t = (text ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "s", with: "")
        let parts = t.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1! }
    }

    private func edit(_ r: [String: Any]) {
        guard let e = editor(r["id"] as? String ?? "") else { return }
        switch r["do"] as? String {
        case "add": e.add(r["track"] as? String ?? "zoom-in")
        case "set": e.setValue(number: r["number"] as? Double, kind: r["kind"] as? String)
        case "delete": e.deleteSelected()
        case "split": e.splitSelected()
        case "auto": e.autoZoom()
        case "clear": e.clearAll()
        case "play": e.togglePlay()
        case "split-clip": e.splitClip()
        case "remove": e.toggleRemoved()
        case "join-prev": e.join(-1)
        case "join-next": e.join(1)
        case "add-lane": e.addLane()
        case "transition": e.setTransition(r["kind"] as? String ?? "cut")
        case "text": e.setText(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "move": e.setMoveField(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "place": e.placePreset(r["kind"] as? String ?? "")
        case "three": e.setThree(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "add-move": e.addMove()
        case "pattern": e.pattern(r["kind"] as? String ?? "")
        case "find-device": e.findDevice()
        case "forget-device": e.forgetDevice()
        case "start": e.setTimes(start: Self.seconds(r["kind"] as? String), end: nil)
        case "end": e.setTimes(start: nil, end: Self.seconds(r["kind"] as? String))
        default: break
        }
    }

    // MARK: Recording

    private func start(_ source: String, reply: ExactReply) {
        guard recorder == nil, !starting else { return reply.send(["ok": false, "error": "Already recording."]) }
        guard CGPreflightScreenCaptureAccess() else {
            if !context.agent { CGRequestScreenCaptureAccess() }
            return reply.send(["ok": false, "error": "Allow Exact Studio in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen it."])
        }
        if source == "area" {
            let picker = AreaPicker()
            self.picker = picker
            picker.pick { [weak self] area in
                self?.picker = nil
                guard let area else { return reply.send(["ok": false, "error": ""]) }
                self?.begin(source, area: area, reply: reply)
            }
        } else {
            begin(source, area: nil, reply: reply)
        }
    }

    private func begin(_ source: String, area: (NSScreen, CGRect)?, reply: ExactReply) {
        starting = true
        let id = Self.newID()
        let folder = Library.recordings.appendingPathComponent(id, isDirectory: true)
        Task { @MainActor in
            defer { starting = false }
            do {
                let r = try await Recorder.make(source: source, area: area, folder: folder, id: id)
                try await r.start()
                recorder = r
                showStatusItem()
                context.changed("status")
                reply.send(["ok": true, "error": ""])
            } catch {
                try? FileManager.default.removeItem(at: folder)
                reply.send(["ok": false, "error": "Couldn’t start recording: \(error)"])
            }
        }
    }

    private func stop(reply: ExactReply?) {
        guard let r = recorder else { reply?.send(["ok": false, "error": "Not recording.", "id": ""]); return }
        recorder = nil
        hideStatusItem()
        context.changed("status")
        Task { @MainActor in
            do {
                let meta = try await r.stop()
                context.changed("recordings")
                reply?.send(["ok": true, "error": "", "id": meta.id])
            } catch {
                try? FileManager.default.removeItem(at: r.folder)
                context.changed("recordings")
                reply?.send(["ok": false, "error": "\(error)", "id": ""])
            }
        }
    }

    private static func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// While recording, a menu bar item stops it, so the app's window can stay out of the shot.
    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        item.button?.title = " Stop"
        item.button?.imagePosition = .imageLeading
        item.button?.contentTintColor = .systemRed
        item.button?.target = self
        item.button?.action = #selector(stopFromMenuBar)
        statusItem = item
    }

    private func hideStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func stopFromMenuBar() {
        stop(reply: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Editing and export

    private func nudge(id: String, edge: String, by: Double) {
        guard var meta = Library.meta(id) else { return }
        var c = meta.crop
        switch edge {
        case "top": c.y += by; c.h -= by
        case "bottom": c.h -= by
        case "left": c.x += by; c.w -= by
        case "right": c.w -= by
        case "reset": c = .full
        default: return
        }
        guard c.w > 0.1, c.h > 0.1, c.x >= 0, c.y >= 0, c.x + c.w <= 1.0001, c.y + c.h <= 1.0001 else { return }
        meta.crop = c
        try? Library.save(meta)
        editors[id]?.setCrop(c)
        context.changed("recordings")
    }

    private func export(id: String, look: Look, reply: ExactReply) {
        guard let e = editor(id) else { return reply.send(["ok": false, "error": "No such recording.", "path": ""]) }
        let made: (AVAsset, AVMutableVideoComposition)
        do { made = try e.exportable(look: look) } catch { return reply.send(["ok": false, "error": "\(error)", "path": ""]) }
        guard let session = AVAssetExportSession(asset: made.0, presetName: AVAssetExportPresetHighestQuality) else {
            return reply.send(["ok": false, "error": "This Mac can’t export that.", "path": ""])
        }
        let safe = e.meta.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: Library.root, withIntermediateDirectories: true)
        var out = Library.root.appendingPathComponent("\(safe) \(id).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = Library.root.appendingPathComponent("\(safe) \(id) \(n).mp4"); n += 1 }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = made.1
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            if session.status == .completed {
                reply.send(["ok": true, "error": "", "path": out.path])
            } else {
                reply.send(["ok": false, "error": session.error?.localizedDescription ?? "The export stopped.", "path": ""])
            }
        }
    }
}
let exactModule: ExactModule.Type = Studio.self

/// `<studio-preview clip=… look=…>`: the open recording's player, with the look applied.
/// Drag the video to place it (snapping to the centre lines), scroll or pinch to
/// resize it; drag a text to move it.
final class Preview: ExactNativeInstance {
    private let studio: Studio
    private let host = PlayerHost()
    private var clip = ""

    init(_ studio: Studio, _ props: [String: String], _ events: ExactNativeEvents) {
        self.studio = studio
        super.init(events: events)
        try? setProps(props)
        events.intrinsicSize(CGSize(width: 640, height: 360))
    }

    override var view: ExactNativeView { host }

    override func setProps(_ props: [String: String]) throws {
        let next = props["clip"] ?? ""
        let editor = studio.editor(next)
        if next != clip {
            clip = next
            host.attach(editor)
        }
        editor?.setLook(Look.parse(props["look"] ?? "{}"))
    }

    override func destroy() {
        studio.editor(clip)?.player.pause()
        host.attach(nil)
    }
}

final class PlayerHost: NSView {
    let player = AVPlayerLayer()
    private let outline = CAShapeLayer()
    private let guides = CAShapeLayer()
    private weak var editor: Editor?
    private enum Drag { case subject(CGPoint, Placement), text(String, CGPoint, CGPoint), turn(CGPoint, Double, Double) }
    private var drag: Drag?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        player.videoGravity = .resizeAspect
        player.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(player)
        still.contentsGravity = .resizeAspect
        still.isHidden = true
        layer?.addSublayer(still)
        for l in [outline, guides] {
            l.fillColor = nil
            l.lineWidth = 1.5
            layer?.addSublayer(l)
        }
        outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineDashPattern = [6, 4]
        guides.strokeColor = NSColor.systemPink.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The last frame, held over the player while a rebuild replaces the playback.
    private let still = CALayer()

    func attach(_ editor: Editor?) {
        self.editor?.unlisten(self)
        self.editor = editor
        player.player = editor?.player
        editor?.freeze = { [weak self] image in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.still.contents = image
            self.still.frame = self.player.videoRect.width > 0 ? self.player.videoRect : self.bounds
            self.still.isHidden = false
            CATransaction.commit()
        }
        editor?.thaw = { [weak self] in
            CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
            self?.still.isHidden = true
            self?.still.contents = nil
            CATransaction.commit()
        }
        editor?.listen(self) { [weak self] in self?.drawOverlay() }
        drawOverlay()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.frame = bounds
        outline.frame = bounds
        guides.frame = bounds
        CATransaction.commit()
        drawOverlay()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The video's rectangle in this view (AppKit, origin bottom-left).
    private var video: CGRect {
        let r = player.videoRect
        return r.width > 0 ? r : bounds
    }
    /// A view point in canvas units (origin top-left).
    private func unit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - video.minX) / video.width, y: 1 - (p.y - video.minY) / video.height)
    }
    private func rect(_ u: UnitRect) -> CGRect {
        CGRect(x: video.minX + u.x * video.width, y: video.minY + (1 - u.y - u.h) * video.height, width: u.w * video.width, height: u.h * video.height)
    }
    private func contains(_ u: UnitRect, _ p: CGPoint) -> Bool { p.x >= u.x && p.x <= u.x + u.w && p.y >= u.y && p.y <= u.y + u.h }

    /// The selected text's box, or the video's while it is dragged.
    private func drawOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let editor else { outline.path = nil; guides.path = nil; return }
        let f = editor.framing
        if let s = editor.selectedSegment, s.kind == "text" {
            outline.path = CGPath(roundedRect: rect(f.textFrame(s)), cornerWidth: 6, cornerHeight: 6, transform: nil)
        } else if case .subject = drag {
            outline.path = CGPath(rect: rect(f.subjectFrame(at: editor.playhead)), transform: nil)
        } else {
            outline.path = nil
        }
        if drag == nil { guides.path = nil }
    }

    override func mouseDown(with e: NSEvent) {
        guard let editor else { return }
        let u = unit(convert(e.locationInWindow, from: nil))
        let f = editor.framing
        let t = editor.playhead
        // A text showing now, the selected one first.
        let texts = editor.edits.texts.filter { t >= $0.start && t < $0.end }
            .sorted { a, _ in a.id == editor.selected }
        if let s = texts.first(where: { contains(f.textFrame($0), u) }) {
            editor.select(s.id)
            drag = .text(s.id, u, CGPoint(x: s.x ?? 0.5, y: s.y ?? 0.5))
        } else if contains(f.subjectFrame(at: t), u) {
            if editor.selectedSegment?.kind == "text" { editor.select("") }
            // ⌥-drag turns it in 3D (switching 3D on); a plain drag moves it.
            if e.modifierFlags.contains(.option) {
                if !editor.edits.three.on { editor.setThree("on", "true", live: true) }
                // From the angle it shows now (the selected move's while one is selected).
                let a = editor.framing.pose(at: editor.selectedMove?.t ?? editor.playhead).angles
                drag = .turn(u, a.tilt, a.turn)
            } else {
                drag = .subject(u, editor.placementNow)
            }
        } else {
            editor.select("")
            drag = nil
        }
        drawOverlay()
    }

    /// Within this distance of a centre line, a drag snaps to it.
    private static let snap = 0.012

    override func mouseDragged(with e: NSEvent) {
        guard let editor, let drag else { return }
        let u = unit(convert(e.locationInWindow, from: nil))
        var lines: [CGFloat] = [], rows: [CGFloat] = []
        func snapped(_ v: Double, _ hit: inout [CGFloat]) -> Double {
            if abs(v - 0.5) < Self.snap { hit.append(0.5); return 0.5 }
            return v
        }
        switch drag {
        case let .subject(from, start):
            let x = snapped(start.x + u.x - from.x, &lines), y = snapped(start.y + u.y - from.y, &rows)
            editor.place(Placement(x: x, y: y, scale: start.scale), live: true)
        case let .text(id, from, start):
            let x = snapped(start.x + u.x - from.x, &lines), y = snapped(start.y + u.y - from.y, &rows)
            editor.dragText(id, x: x, y: y, live: true)
        case let .turn(from, tilt, turn):
            // Like turning an object in the hand: drag right and the right side comes toward you; drag down and the top leans away.
            var nt = turn - Double(u.x - from.x) * 160, nl = tilt + Double(u.y - from.y) * 160
            if abs(nt) < 2 { nt = 0 }
            if abs(nl) < 2 { nl = 0 }
            editor.setThree("turn", String(nt), live: true)
            editor.setThree("tilt", String(nl), live: true)
        }
        let path = CGMutablePath()
        for x in lines { path.move(to: CGPoint(x: video.minX + x * video.width, y: video.minY)); path.addLine(to: CGPoint(x: video.minX + x * video.width, y: video.maxY)) }
        for y in rows { path.move(to: CGPoint(x: video.minX, y: video.minY + y * video.height)); path.addLine(to: CGPoint(x: video.maxX, y: video.minY + y * video.height)) }
        guides.path = path
        drawOverlay()
    }

    override func mouseUp(with e: NSEvent) {
        guard let editor, let drag else { return }
        switch drag {
        case .subject: editor.endPlace()
        case .turn:
            let a = editor.framing.pose(at: editor.selectedMove?.t ?? editor.playhead).angles
            editor.setThree("turn", String(a.turn))
        case let .text(id, _, _):
            if let s = editor.edits.texts.first(where: { $0.id == id }) { editor.dragText(id, x: s.x ?? 0.5, y: s.y ?? 0.5, live: false) }
        }
        self.drag = nil
        guides.path = nil
        drawOverlay()
    }

    /// Resize the selected text, else the video.
    private func resize(by factor: Double) {
        guard let editor else { return }
        if let s = editor.selectedSegment, s.kind == "text" {
            editor.setText("size", String((s.size ?? 0.08) * factor * 100))
            return
        }
        var p = editor.placementNow
        p.scale = min(max(p.scale * factor, 0.2), 4)
        editor.place(p)
    }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        guard abs(dy) > 0.1 else { return }
        resize(by: 1 + Double(dy) * 0.004)
    }

    override func magnify(with e: NSEvent) { resize(by: 1 + Double(e.magnification)) }
}
#else
final class Studio: ExactModule {}
let exactModule: ExactModule.Type = Studio.self
#endif
