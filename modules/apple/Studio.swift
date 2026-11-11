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

    private static let emptySelection: [String: Any] = ["id": "", "kind": "", "level": 0, "rate": 0, "start": 0, "end": 0, "startText": "", "endText": "",
                                                        "removed": false, "first": false, "last": false, "problem": ""]

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status":
            return ["recording": recorder != nil, "name": recorder?.name ?? "", "kind": recorder?.kind.rawValue ?? ""]
        case "selection":
            return editor(request["id"] as? String ?? "")?.selection ?? Self.emptySelection
        case "summary":
            return editor(request["id"] as? String ?? "")?.summary ?? ["parts": 1, "removed": 0, "effects": 0, "lanes": 1, "length": 0, "source": 0]
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
/// A bare player layer, so the stage's colour shows around the video rather than black bars.
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
            host.player.player = editor?.player
        }
        editor?.setLook(Look.parse(props["look"] ?? "{}"))
    }

    override func destroy() {
        studio.editor(clip)?.player.pause()
        host.player.player = nil
    }
}

final class PlayerHost: NSView {
    let player = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        player.videoGravity = .resizeAspect
        player.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(player)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.frame = bounds
        CATransaction.commit()
    }
}
#else
final class Studio: ExactModule {}
let exactModule: ExactModule.Type = Studio.self
#endif
