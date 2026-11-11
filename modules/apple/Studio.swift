// Exact Studio's native module: what app.ts asks (`native.call` / `later`)
// and the `studio-preview` view. Topics app.ts watches: "status" (recording
// or not) and "recordings" (the library changed).
//
//   call   {op: "status"}                       → {recording, name, kind}
//   later  {op: "sources"}                      → {items: [{id, name, app, kind}], allowed}
//          {op: "start", source}                → {ok, error}   source "area" opens the picker
//          {op: "stop"}                         → {ok, error, id}
//          {op: "recordings"}                   → {items: [{id, name, kind, created, duration}]}
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
        ["studio-preview": ExactNativeFactory(for: Studio.self) { _, props, events in Preview(props, events) }]
    }

    private var recorder: Recorder?
    private var starting = false
    private var picker: AreaPicker?
    private var statusItem: NSStatusItem?

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status":
            return ["recording": recorder != nil, "name": recorder?.name ?? "", "kind": recorder?.kind.rawValue ?? ""]
        default:
            throw ExactNativeRefusal("studio answers status")
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
        case "export":
            export(id: request["id"] as? String ?? "", look: Look.parse(request["look"] as? String ?? "{}"), reply: reply)
        case "delete":
            let id = request["id"] as? String ?? ""
            guard !id.isEmpty, !id.contains("/") else { return reply.send(["ok": false, "error": "No such recording."]) }
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
        context.changed("recordings")
        Preview.changed(id)
    }

    private func export(id: String, look: Look, reply: ExactReply) {
        guard let meta = Library.meta(id) else { return reply.send(["ok": false, "error": "No such recording.", "path": ""]) }
        let asset = AVURLAsset(url: Library.recordings.appendingPathComponent(id).appendingPathComponent("capture.mov"))
        let composition = Composition.make(asset: asset, meta: meta, cursor: Library.cursor(id), look: look)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return reply.send(["ok": false, "error": "This Mac can’t export that.", "path": ""])
        }
        let safe = meta.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var out = Library.root.appendingPathComponent("\(safe) \(id).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = Library.root.appendingPathComponent("\(safe) \(id) \(n).mp4"); n += 1 }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = composition
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

/// `<studio-preview clip=… look=…>`: the recording, played with the look applied.
final class Preview: ExactNativeInstance {
    private static var live: [ObjectIdentifier: Preview] = [:]
    static func changed(_ id: String) { live.values.filter { $0.clip == id }.forEach { $0.rebuild(force: true) } }

    private let player = AVPlayer()
    private let host = AVPlayerView()
    private var clip = ""
    private var lookJSON = ""
    private var asset: AVURLAsset?

    init(_ props: [String: String], _ events: ExactNativeEvents) {
        super.init(events: events)
        host.player = player
        host.controlsStyle = .floating
        host.showsFullScreenToggleButton = false
        host.videoGravity = .resizeAspect
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        Preview.live[ObjectIdentifier(self)] = self
        try? setProps(props)
        events.intrinsicSize(CGSize(width: 640, height: 360))
    }

    override var view: ExactNativeView { host }

    override func setProps(_ props: [String: String]) throws {
        let newClip = props["clip"] ?? "", newLook = props["look"] ?? "{}"
        let clipChanged = newClip != clip
        guard clipChanged || newLook != lookJSON else { return }
        clip = newClip
        lookJSON = newLook
        rebuild(force: clipChanged)
    }

    fileprivate func rebuild(force: Bool) {
        guard !clip.isEmpty, let meta = Library.meta(clip) else {
            player.replaceCurrentItem(with: nil); asset = nil; return
        }
        if force || asset == nil {
            let a = AVURLAsset(url: Library.recordings.appendingPathComponent(clip).appendingPathComponent("capture.mov"))
            asset = a
            let item = AVPlayerItem(asset: a)
            item.videoComposition = Composition.make(asset: a, meta: meta, cursor: Library.cursor(clip), look: Look.parse(lookJSON))
            player.replaceCurrentItem(with: item)
        } else if let a = asset, let item = player.currentItem {
            // Same clip, new look: keep the playhead where it is.
            item.videoComposition = Composition.make(asset: a, meta: meta, cursor: Library.cursor(clip), look: Look.parse(lookJSON))
            if player.rate == 0 { item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
        }
    }

    override func destroy() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        Preview.live[ObjectIdentifier(self)] = nil
    }
}
#else
final class Studio: ExactModule {}
let exactModule: ExactModule.Type = Studio.self
#endif
