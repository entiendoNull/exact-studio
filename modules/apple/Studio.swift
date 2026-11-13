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
//          {op: "start", source}                → {ok, error}   source "area" or "pick-window" opens a picker
//          {op: "stop"}                         → {ok, error, id}
//          {op: "recordings"}                   → {items: [{id, name, kind, created, duration}]}
//          {op: "edit", id, do, track?, number?, kind?}  → {ok}
//                 do: add (track: a kind, or zoom-in, zoom-out, slow, fast), set (number | kind),
//                     delete, split, auto, clear, play, split-clip, remove, join-prev, join-next,
//                     add-lane, start / end (kind: the typed time)
//          {op: "export", id, quality, to}      → {ok, error, path, copied}  quality best|1080p|720p|small; to movies|choose|clipboard
//          {op: "delete", id}                   → {ok, error}
//          {op: "reveal", path}                 → {ok}
//          {op: "crop", id, edge, by}           → {ok}  nudges a recording's crop by `by` (unit) at an edge
#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    /// The area or window picker while it is open.
    private var picker: AnyObject?
    private var statusItem: NSStatusItem?
    private var editors: [String: Editor] = [:]
    private var keys: Any?
    /// The recording the preview shows: Space plays and pauses it.
    var active = ""

    override func destroy() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    required init(context: ExactModuleContext) {
        super.init(context: context)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText), let editor = self.editors[self.active] else { return e }
            editor.togglePlay()
            return nil
        }
        if context.agent {
            Library.scratch = context.data.appendingPathComponent("Exact Studio", isDirectory: true)
            Pictures.mayAsk = false
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
        "rotation": 0, "moveStyle": "", "duration": 0, "scale": 0, "tilt": 0, "turn": 0, "roll": 0, "hasAngles": false, "scope": "video", "problem": "",
        "file": "", "opacity": 100, "radius": 0, "shadow": false, "fx": "",
    ]
    private static let emptySummary: [String: Any] = [
        "parts": 1, "removed": 0, "effects": 0, "lanes": 1, "images": 0, "moves": 0, "length": 0, "source": 0, "playing": false,
        "device": false, "found": false, "cursorDrawn": false, "baseScale": 100, "canUndoTemplate": false,
        "threeOn": false, "tilt": 0, "turn": 0, "roll": 0, "angleMove": "", "thickness": 5, "edge": "metal",
    ]

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status":
            return ["recording": recorder != nil, "name": recorder?.name ?? "", "kind": recorder?.kind.rawValue ?? ""]
        case "selection":
            return editor(request["id"] as? String ?? "")?.selection ?? Self.emptySelection
        case "look":
            return editor(request["id"] as? String ?? "")?.lookInfo ?? Editor.defaultLook
        case "summary":
            return editor(request["id"] as? String ?? "")?.summary ?? Self.emptySummary
        default:
            throw ExactNativeRefusal("studio answers status, selection and summary")
        }
    }

    /// File ▸ Open Recording…: pick a recording folder (the one holding meta.json).
    /// One in the library is selected; one from elsewhere is copied in first.
    func openRecording(reply: ExactReply) {
        let none: [String: Any] = ["ok": false, "error": "", "id": ""]
        if context.agent { return reply.send(none) }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            panel.message = "Choose a recording folder."
            try? FileManager.default.createDirectory(at: Library.recordings, withIntermediateDirectories: true)
            panel.directoryURL = Library.recordings
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let picked = panel.url?.standardizedFileURL else { return reply.send(none) }
            guard let data = try? Data(contentsOf: picked.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(RecordingMeta.self, from: data), !meta.id.contains("/") else {
                return reply.send(["ok": false, "error": "That folder is not an Exact Studio recording.", "id": ""])
            }
            let home = Library.recordings.appendingPathComponent(meta.id).standardizedFileURL
            if picked.path != home.path && !FileManager.default.fileExists(atPath: home.path) {
                do { try FileManager.default.copyItem(at: picked, to: home) }
                catch { return reply.send(["ok": false, "error": "Could not copy it into the library.", "id": ""]) }
                self.context.changed("recordings")
            }
            reply.send(["ok": true, "error": "", "id": meta.id])
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
            start(request["source"] as? String ?? "", sound: request["sound"] as? Bool ?? true, reply: reply)
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
            export(id: request["id"] as? String ?? "", quality: request["quality"] as? String ?? "best",
                   to: request["to"] as? String ?? "movies", reply: reply)
        case "delete":
            let id = request["id"] as? String ?? ""
            guard !id.isEmpty, !id.contains("/") else { return reply.send(["ok": false, "error": "No such recording."]) }
            if let e = editors.removeValue(forKey: id) { e.player.pause(); e.player.replaceCurrentItem(with: nil) }
            try? FileManager.default.removeItem(at: Library.recordings.appendingPathComponent(id))
            context.changed("recordings")
            reply.send(["ok": true, "error": ""])
        case "open":
            openRecording(reply: reply)
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

    /// A picture file for an image: the one at `path`, else one the person picks in a panel.
    private func pickPicture(_ path: String?, then: @escaping (URL) -> Void) {
        if let path, !path.isEmpty { return then(URL(fileURLWithPath: path)) }
        Pictures.pick(then: then)
    }

    private func edit(_ r: [String: Any]) {
        guard let e = editor(r["id"] as? String ?? "") else { return }
        switch r["do"] as? String {
        case "add":
            // An image starts from a picture file: `kind` names one, else the person picks it.
            if r["track"] as? String == "image" { pickPicture(r["kind"] as? String) { e.addImage($0) } } else { e.add(r["track"] as? String ?? "zoom-in") }
        case "image":
            // The selected image: its picture, one of its fields, a new effect or move of its own, or one of theirs.
            let field = r["track"] as? String ?? "", value = r["kind"] as? String ?? ""
            switch field {
            case "replace": pickPicture(value) { e.replaceImage($0) }
            case "add-effect": e.addImageEffect(value)
            case "add-move": e.addImageMove()
            case "move-style", "move-duration", "move-scale": e.setImageMove(String(field.dropFirst(5)), value)
            case "effect-level": e.setImageEffect("level", value)
            default: e.setImage(field, value)
            }
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
        case "deselect": e.select("")
        case "seg": e.setSegment(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "template": e.applyTemplate(r["kind"] as? String ?? "")
        case "undo-template": e.undoTemplate()
        case "look": e.setLookField(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "three": e.setThree(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "volume": e.setVolume((r["number"] as? Double ?? 100) / 100)
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

    private func start(_ source: String, sound: Bool, reply: ExactReply) {
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
                self?.begin(source, area: area, sound: sound, reply: reply)
            }
        } else if source == "pick-window" {
            let picker = WindowPicker()
            self.picker = picker
            picker.pick { [weak self] id in
                self?.picker = nil
                guard let id else { return reply.send(["ok": false, "error": ""]) }
                self?.begin("window:\(id)", area: nil, sound: sound, reply: reply)
            }
        } else {
            begin(source, area: nil, sound: sound, reply: reply)
        }
    }

    private func begin(_ source: String, area: (NSScreen, CGRect)?, sound: Bool, reply: ExactReply) {
        starting = true
        let id = Self.newID()
        let folder = Library.recordings.appendingPathComponent(id, isDirectory: true)
        Task { @MainActor in
            defer { starting = false }
            do {
                let r = try await Recorder.make(source: source, area: area, folder: folder, id: id, sound: sound)
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

    private func export(id: String, quality: String, to: String, reply: ExactReply) {
        func fail(_ why: String) { reply.send(["ok": false, "error": why, "path": "", "copied": false]) }
        guard let e = editor(id) else { return fail("No such recording.") }
        let made: (AVAsset, AVMutableVideoComposition, AVAudioMix?)
        do { made = try e.exportable(look: e.look) } catch { return fail("\(error)") }
        let safe = e.meta.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let tag = quality == "best" ? "" : " \(quality)"

        func run(_ out: URL) {
            guard let session = ExportQuality.session(made.0, made.1, audio: made.2, quality: quality, to: out) else { return fail("This Mac can’t export that.") }
            session.exportAsynchronously {
                guard session.status == .completed else { return fail(session.error?.localizedDescription ?? "The export stopped.") }
                guard to == "clipboard" else { return reply.send(["ok": true, "error": "", "path": out.path, "copied": false]) }
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([out as NSURL])
                    reply.send(["ok": true, "error": "", "path": out.path, "copied": true])
                }
            }
        }

        // Where it goes: the Movies folder, a place the person picks, or a file behind the clipboard.
        let out: URL
        switch to {
        case "choose":
            // The save panel is modal and needs the main thread; the export goes on from there.
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.nameFieldStringValue = "\(safe)\(tag).mp4"
                panel.directoryURL = Library.root
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let picked = panel.url else {
                    return reply.send(["ok": false, "error": "", "path": "", "copied": false])
                }
                try? FileManager.default.removeItem(at: picked)
                run(picked)
            }
            return
        case "clipboard":
            // A real file, kept until the next copy, so apps that paste files (Slack, Messages, Finder) get the video.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exact Studio Clipboard")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            out = dir.appendingPathComponent("\(safe)\(tag).mp4")
        default:
            try? FileManager.default.createDirectory(at: Library.root, withIntermediateDirectories: true)
            var url = Library.root.appendingPathComponent("\(safe) \(id)\(tag).mp4")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) { url = Library.root.appendingPathComponent("\(safe) \(id)\(tag) \(n).mp4"); n += 1 }
            out = url
        }

        run(out)
    }
}
let exactModule: ExactModule.Type = Studio.self

/// `<studio-preview clip=… look=…>`: the open recording's player, with the look applied.
/// Drag the video to place it (snapping to the centre lines), scroll or pinch to
/// resize it; drag a text or an image to move it; drop a picture file on it to add an image.
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
        studio.active = next
        host.cropping = props["cropping"] == "true"
        // The look is the recording's own (look.json); the view only shows and sets it.
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
    /// Whether the pointer moved since the press: a plain click places nothing.
    private var dragged = false
    private var ticking: Any?
    private weak var watched: AVPlayer?

    // MARK: Crop mode
    // @ref LLP 0005#crop-on-the-picture — the whole recording, a grid, and handles to drag
    /// While on, the view shows the whole recorded frame at the playhead, uncropped,
    /// with the crop as a lit rectangle over it: a thirds grid inside, the rest dimmed,
    /// a handle at each corner and edge. Drag a handle to move that side (a corner moves
    /// two), or inside to move the crop. Letting go saves it.
    var cropping = false {
        didSet {
            guard cropping != oldValue else { return }
            if cropping { editor?.player.pause(); loadFrame() } else { rawFrame.contents = nil; cropDrag = nil }
            layoutCrop()
            drawOverlay()
        }
    }
    private let rawFrame = CALayer()
    private let cropShade = CAShapeLayer()
    private let cropLines = CAShapeLayer()
    private let cropGrid = CAShapeLayer()
    private let cropHandles = CAShapeLayer()
    private enum CropDrag { case edges(left: Bool, right: Bool, top: Bool, bottom: Bool, from: CGPoint, start: UnitRect), move(CGPoint, UnitRect) }
    private var cropDrag: CropDrag?
    /// The crop while it is dragged, before it is saved.
    private var cropLive: UnitRect?
    /// The smallest crop, as a share of each side.
    private static let cropMinimum = 0.05

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
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

        rawFrame.contentsGravity = .resize
        rawFrame.isHidden = true
        rawFrame.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        cropShade.fillColor = NSColor(white: 0, alpha: 0.6).cgColor
        cropShade.fillRule = .evenOdd
        cropLines.fillColor = nil
        cropLines.strokeColor = NSColor.white.cgColor
        cropLines.lineWidth = 1.5
        cropGrid.fillColor = nil
        cropGrid.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        cropGrid.lineWidth = 1
        cropHandles.fillColor = nil
        cropHandles.strokeColor = NSColor.white.cgColor
        cropHandles.lineWidth = 4
        cropHandles.lineCap = .round
        cropHandles.shadowColor = NSColor.black.cgColor
        cropHandles.shadowOpacity = 0.5
        cropHandles.shadowRadius = 2
        cropHandles.shadowOffset = .zero
        for l in [rawFrame, cropShade, cropGrid, cropLines, cropHandles] { l.isHidden = true; layer?.addSublayer(l) }
    }

    /// The recorded frame at the playhead, as captured.
    private func loadFrame() {
        guard let editor else { return }
        let generator = AVAssetImageGenerator(asset: editor.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let at = CMTime(seconds: editor.playhead, preferredTimescale: 6000)
        generator.generateCGImageAsynchronously(for: at) { [weak self] image, _, _ in
            DispatchQueue.main.async {
                guard let self, self.cropping, let image else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.rawFrame.contents = image
                CATransaction.commit()
            }
        }
    }

    /// Where the whole frame is drawn while cropping: fitted into the view with a margin for the handles.
    private var frameRect: CGRect {
        guard let m = editor?.meta, m.width > 0, m.height > 0 else { return bounds.insetBy(dx: 24, dy: 24) }
        return AVMakeRect(aspectRatio: CGSize(width: m.width, height: m.height), insideRect: bounds.insetBy(dx: 24, dy: 24))
    }
    private var cropNow: UnitRect { cropLive ?? editor?.meta.crop ?? .full }
    /// A unit rectangle of the frame (origin top-left) in this view (origin bottom-left).
    private func onFrame(_ u: UnitRect) -> CGRect {
        let f = frameRect
        return CGRect(x: f.minX + u.x * f.width, y: f.minY + (1 - u.y - u.h) * f.height, width: u.w * f.width, height: u.h * f.height)
    }

    private func layoutCrop() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for l in [rawFrame, cropShade, cropGrid, cropLines, cropHandles] { l.isHidden = !cropping }
        for l in [player, still, outline, guides] as [CALayer] { l.opacity = cropping ? 0 : 1 }
        guard cropping else { return }
        let f = frameRect
        rawFrame.frame = f
        let r = onFrame(cropNow)
        let shade = CGMutablePath()
        shade.addRect(f)
        shade.addRect(r)
        cropShade.path = shade
        cropLines.path = CGPath(rect: r, transform: nil)
        let grid = CGMutablePath()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        cropGrid.path = grid
        // An L at each corner, a short bar at each edge's middle.
        let k = min(18, r.width / 4, r.height / 4), b = min(12, r.width / 6, r.height / 6)
        let h = CGMutablePath()
        for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            h.move(to: CGPoint(x: c.x + dx * k, y: c.y)); h.addLine(to: c); h.addLine(to: CGPoint(x: c.x, y: c.y + dy * k))
        }
        h.move(to: CGPoint(x: r.midX - b, y: r.minY)); h.addLine(to: CGPoint(x: r.midX + b, y: r.minY))
        h.move(to: CGPoint(x: r.midX - b, y: r.maxY)); h.addLine(to: CGPoint(x: r.midX + b, y: r.maxY))
        h.move(to: CGPoint(x: r.minX, y: r.midY - b)); h.addLine(to: CGPoint(x: r.minX, y: r.midY + b))
        h.move(to: CGPoint(x: r.maxX, y: r.midY - b)); h.addLine(to: CGPoint(x: r.maxX, y: r.midY + b))
        cropHandles.path = h
    }

    private func cropDown(_ p: CGPoint) {
        let r = onFrame(cropNow), f = frameRect
        let u = CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
        // Within reach of a side: that side moves; of two sides (a corner): both.
        let reach: CGFloat = 14
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) <= reach }
        let inY = p.y >= r.minY - reach && p.y <= r.maxY + reach, inX = p.x >= r.minX - reach && p.x <= r.maxX + reach
        let left = near(p.x, r.minX) && inY, right = near(p.x, r.maxX) && inY && !left
        let bottom = near(p.y, r.minY) && inX, top = near(p.y, r.maxY) && inX && !bottom
        if left || right || top || bottom {
            cropDrag = .edges(left: left, right: right, top: top, bottom: bottom, from: u, start: cropNow)
        } else if r.contains(p) {
            cropDrag = .move(u, cropNow)
        } else {
            cropDrag = nil
        }
    }

    private func cropDragged(_ p: CGPoint) {
        guard let cropDrag else { return }
        let f = frameRect
        let u = CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
        let m = Self.cropMinimum
        var c: UnitRect
        switch cropDrag {
        case let .move(from, start):
            c = start
            c.x = min(max(start.x + u.x - from.x, 0), 1 - start.w)
            c.y = min(max(start.y + u.y - from.y, 0), 1 - start.h)
        case let .edges(left, right, top, bottom, from, start):
            var x0 = start.x, x1 = start.x + start.w, y0 = start.y, y1 = start.y + start.h
            let dx = u.x - from.x, dy = u.y - from.y
            if left { x0 = min(max(start.x + dx, 0), x1 - m) }
            if right { x1 = max(min(start.x + start.w + dx, 1), x0 + m) }
            if top { y0 = min(max(start.y + dy, 0), y1 - m) }
            if bottom { y1 = max(min(start.y + start.h + dy, 1), y0 + m) }
            c = UnitRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
        cropLive = c
        layoutCrop()
    }

    private func cropUp() {
        if let c = cropLive { editor?.setCrop(c) }
        cropLive = nil
        cropDrag = nil
        layoutCrop()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The last frame, held over the player while a rebuild replaces the playback.
    private let still = CALayer()

    func attach(_ editor: Editor?) {
        self.editor?.unlisten(self)
        if let p = watched, let o = ticking { p.removeTimeObserver(o) }
        ticking = nil
        self.editor = editor
        player.player = editor?.player
        // An image moves as time passes, so its outline follows the playhead.
        watched = editor?.player
        ticking = editor?.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            guard let self, self.editor?.selectedImage != nil, self.drag == nil else { return }
            self.drawOverlay()
        }
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
        for l in [cropShade, cropGrid, cropLines, cropHandles] { l.frame = bounds }
        CATransaction.commit()
        layoutCrop()
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
        if cropping { layoutCrop(); return }
        let f = editor.framing
        if let s = editor.selectedSegment, s.kind == "text" {
            outline.path = CGPath(roundedRect: rect(f.textFrame(s)), cornerWidth: 6, cornerHeight: 6, transform: nil)
        } else if let s = editor.selectedImage, editor.playhead >= s.start, editor.playhead <= s.end {
            // The image, or the image a selected move or effect belongs to, where it is now.
            outline.path = CGPath(roundedRect: rect(f.imageFrame(s, at: editor.playhead)), cornerWidth: 6, cornerHeight: 6, transform: nil)
        } else if case .subject = drag {
            outline.path = CGPath(rect: rect(f.subjectFrame(at: editor.playhead)), transform: nil)
        } else {
            outline.path = nil
        }
        if drag == nil { guides.path = nil }
    }

    override func mouseDown(with e: NSEvent) {
        guard let editor else { return }
        if cropping { return cropDown(convert(e.locationInWindow, from: nil)) }
        dragged = false
        let u = unit(convert(e.locationInWindow, from: nil))
        let f = editor.framing
        let t = editor.playhead
        // A text or an image showing now: the selected one first, then the one in front.
        let over = Array(editor.edits.overlays(at: t).reversed())
        let frame = { (s: Segment) in s.kind == "image" ? f.imageFrame(s, at: t) : f.textFrame(s) }
        let held = editor.selectedImage?.id ?? editor.selected
        if let s = (over.filter { $0.id == held } + over).first(where: { contains(frame($0), u) }) {
            // An image keeps its selected move selected, so the drag sets where that move lands.
            if s.id != held { editor.select(s.id) }
            let box = frame(s)
            drag = .text(s.id, u, CGPoint(x: box.x + box.w / 2, y: box.y + box.h / 2))
        } else if contains(f.subjectFrame(at: t), u) {
            if editor.selectedSegment?.isOverlay == true { editor.select("") }
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
        if cropping { return cropDragged(convert(e.locationInWindow, from: nil)) }
        guard let editor, let drag else { return }
        dragged = true
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
            if editor.edits.segments.first(where: { $0.id == id })?.kind == "image" { editor.placeImage(id, x: x, y: y, live: true) }
            else { editor.dragText(id, x: x, y: y, live: true) }
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
        if cropping { return cropUp() }
        guard let editor, let drag else { return }
        switch drag {
        case .subject: editor.endPlace()
        case .turn:
            let a = editor.framing.pose(at: editor.selectedMove?.t ?? editor.playhead).angles
            editor.setThree("turn", String(a.turn))
        case let .text(id, _, _):
            if let s = editor.edits.segments.first(where: { $0.id == id }) {
                if s.kind == "image" { if dragged { editor.placeImage(id, live: false) } } else { editor.dragText(id, x: s.x ?? 0.5, y: s.y ?? 0.5, live: false) }
            }
        }
        self.drag = nil
        guides.path = nil
        drawOverlay()
    }

    /// Resize the selected text or image, else the video.
    private func resize(by factor: Double) {
        guard let editor else { return }
        if let s = editor.selectedImage {
            editor.placeImage(s.id, factor: factor, live: false)
            return
        }
        if let s = editor.selectedSegment, s.kind == "text" {
            editor.setText("size", String((s.size ?? 0.08) * factor * 100))
            return
        }
        var p = editor.placementNow
        p.scale = min(max(p.scale * factor, 0.2), 4)
        editor.place(p)
    }

    override func scrollWheel(with e: NSEvent) {
        if cropping { return }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        guard abs(dy) > 0.1 else { return }
        resize(by: 1 + Double(dy) * 0.004)
    }

    override func magnify(with e: NSEvent) { if cropping { return }; resize(by: 1 + Double(e.magnification)) }

    // MARK: Dropping a picture

    private func picture(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { Pictures.types.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        editor != nil && !cropping && picture(sender) != nil ? .copy : []
    }

    /// A picture file dropped on the preview becomes an image at the playhead, where it was dropped.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let editor, !cropping, let url = picture(sender) else { return false }
        let u = unit(convert(sender.draggingLocation, from: nil))
        editor.addImage(url, at: CGPoint(x: min(max(u.x, 0), 1), y: min(max(u.y, 0), 1)))
        return true
    }
}
#else
final class Studio: ExactModule {}
let exactModule: ExactModule.Type = Studio.self
#endif
