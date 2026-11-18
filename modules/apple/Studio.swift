// Exact Studio's native module: what app.ts asks (`native.call` / `later`)
// and its views, `studio-preview` and `studio-timeline`. Topics app.ts
// watches: "status" (recording or not), "recordings" (the library changed)
// and "edits" (a recording's edits or selection changed).
//
//   call   {op: "status"}                       → {recording, name, kind, sound, error, finished}  error: the last start's, from here or the menu bar;
//                                                   finished: the id of the last recording that stopped, from either
//          {op: "selection", id}                → {id, kind ("clip" for a part of the clip), level, rate, start, end,
//                                                   startText, endText, removed, first, last, problem}
//          {op: "summary", id}                  → {parts, removed, effects, lanes, length, source}
//   later  {op: "sources"}                      → {items: [{id, name, app, kind}], allowed}
//          {op: "start", source}                → {ok, error}   source "pick-display", "pick-window", "area" or
//                                                   "pick-simulator" opens a picker; else a listed source's id
//          {op: "stop"}                         → {ok, error, id}
//          {op: "sound", on}                    → {ok}  system sound for new recordings (status.sound)
//          {op: "recordings"}                   → {items: [{id, name, kind, created, duration}]}
//          {op: "edit", id, do, track?, number?, kind?}  → {ok}
//                 do: add (track: a kind, or zoom-in, zoom-out, slow, fast), set (number | kind),
//                     delete, split (the selection, else the clip), split-all, auto, clear, play, split-clip, remove, join-prev, join-next,
//                     add-lane, start / end (kind: the typed time)
//          {op: "export", id, quality, to}      → {ok, error, path, copied}  quality best|1080p|720p|small; to movies|choose|clipboard
//          {op: "delete", id}                   → {ok, error}
//          {op: "reveal", path}                 → {ok}
//          {op: "crop", id, edge, by}           → {ok}  nudges a recording's crop by `by` (unit) at an edge
//   Agents reach the recorder through Control.swift's folder, not through these ops: see `serve`.
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
            "studio-clock": ExactNativeFactory(for: Studio.self) { studio, props, events in PlayClock(studio, props, events) },
        ]
    }

    private var recorder: Recorder?
    private var starting = false
    /// The picker while it is open.
    private var picker: AnyObject?
    private var curtain = Curtain()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var soundItem: NSMenuItem?
    private var clock: Timer?
    private var recordingSince = Date()
    /// System sound for new recordings. The module owns it, so the sidebar's switch and the
    /// menu bar's item are one setting. Kept in `Settings.store`.
    private var sound = true
    private static let soundKey = "ExactStudio.recordSound"
    /// Why the last start failed ("" when it did not), wherever it was asked from; the sidebar shows it.
    private var lastError = ""
    /// The last recording that finished, wherever it was stopped; the view selects it when this changes.
    private var finished = ""
    private var editors: [String: Editor] = [:]
    private var keys: Any?
    /// The recording the preview shows: Space plays and pauses it.
    var active = ""
    /// Who started the recording running now: "app" (the sidebar or the menu bar) or "agent".
    private var recordingBy = "app"
    private var maxTimer: Timer?
    private var maxSeconds = 0.0
    /// Whether the running recording takes the system's sound.
    private var recordingSound = false
    /// The last recording that ended, for an agent that asks after it stopped: id, folder, name, kind, duration, by, stoppedBy.
    private var last: [String: Any] = [:]
    /// Answers agents' requests (Control.swift).
    private var control: ControlServer?

    override func destroy() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        clock?.invalidate()
        clock = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        maxTimer?.invalidate()
        maxTimer = nil
        control?.stop()
        control = nil
    }

    required init(context: ExactModuleContext) {
        super.init(context: context)
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 49 || e.keyCode == 1, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText), let editor = self.editors[self.active] else { return e }
            // @ref LLP 0005#split — S splits the selection, ⇧S every lane
            if e.keyCode == 1 { e.modifierFlags.contains(.shift) ? editor.splitAll() : editor.split() } else { editor.togglePlay() }
            return nil
        }
        if context.agent {
            Library.scratch = context.data.appendingPathComponent("Exact Studio", isDirectory: true)
            // @ref LLP 0001#out-of-the-way — a drive's window is off screen, and the drive ends when it goes
            curtain = Curtain(windows: { [] })
            Pictures.mayAsk = false
            Settings.isolate(in: context.data)
            if let f = ProcessInfo.processInfo.environment["EXACT_STUDIO_FIXTURES"], let ids = try? FileManager.default.contentsOfDirectory(atPath: f) {
                try? FileManager.default.createDirectory(at: Library.recordings, withIntermediateDirectories: true)
                for id in ids { try? FileManager.default.copyItem(at: URL(fileURLWithPath: f).appendingPathComponent(id), to: Library.recordings.appendingPathComponent(id)) }
            }
            print("exact-studio library: \(Library.root.path)")
        } else {
            // An automated run gets no menu bar item: it would outlive nothing and only clutter the bar.
            DispatchQueue.main.async { [weak self] in self?.installStatusItem() }
        }
        sound = Settings.store.object(forKey: Self.soundKey) as? Bool ?? true
        // Under the agent, the control folder is the scratch library's, so a drive never answers the person's tools.
        let root = context.agent ? Library.root.appendingPathComponent("control", isDirectory: true) : Control.folder
        DispatchQueue.main.async { [weak self] in self?.serve(root) }
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
        "file": "", "opacity": 100, "radius": 0, "shadow": false, "fx": "", "volume": 100, "fadeIn": 0, "fadeOut": 0,
    ]
    private static let emptySummary: [String: Any] = [
        "parts": 1, "removed": 0, "effects": 0, "lanes": 1, "images": 0, "moves": 0, "length": 0, "source": 0, "playing": false,
        "device": false, "found": false, "cursorDrawn": false, "baseScale": 100, "undoName": "", "redoName": "",
        "threeOn": false, "tilt": 0, "turn": 0, "roll": 0, "angleMove": "", "thickness": 5, "edge": "metal",
        "zoomed": false, "wheelZoom": true,
        "splitLabel": "Split Clip", "canSplit": false, "splitWhy": "", "canSplitAll": false, "splitAllWhy": "",
    ]

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status":
            return ["recording": recorder != nil, "name": recorder?.name ?? "", "kind": recorder?.kind.rawValue ?? "", "sound": sound, "error": lastError, "finished": finished]
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
            start(request["source"] as? String ?? "", reply: reply)
        case "sound":
            setSound(request["on"] as? Bool ?? true)
            reply.send(["ok": true])
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

    /// A sound file for a sound: the one at `path`, else one the person picks in a panel.
    private func pickSound(_ path: String?, then: @escaping (URL) -> Void) {
        if let path, !path.isEmpty { return then(URL(fileURLWithPath: path)) }
        Sounds.pick(then: then)
    }

    private func edit(_ r: [String: Any]) {
        guard let e = editor(r["id"] as? String ?? "") else { return }
        switch r["do"] as? String {
        case "add":
            // An image starts from a picture file: `kind` names one, else the person picks it.
            // A sound likewise starts from a sound file.
            switch r["track"] as? String {
            case "image": pickPicture(r["kind"] as? String) { e.addImage($0) }
            case "sound": pickSound(r["kind"] as? String) { e.addSound($0) }
            case let track: e.add(track ?? "zoom-in")
            }
        case "sound":
            // The selected sound (its file, volume or fades), or the recorded sound's volume.
            let field = r["track"] as? String ?? "", value = r["kind"] as? String ?? ""
            if field == "replace" { pickSound(value) { e.replaceSound($0) } } else { e.setSound(field, value) }
        case "image":
            // The selected image: its picture, one of its fields, a new effect or move of its own, or one of theirs.
            let field = r["track"] as? String ?? "", value = r["kind"] as? String ?? ""
            switch field {
            case "replace": pickPicture(value) { e.replaceImage($0) }
            case "add-effect": e.addItemEffect(value)
            case "add-move": e.addImageMove()
            case "move-style", "move-duration", "move-scale": e.setImageMove(String(field.dropFirst(5)), value)
            case "effect-level": e.setItemEffect("level", value)
            default: e.setImage(field, value)
            }
        case "set": e.setValue(number: r["number"] as? Double, kind: r["kind"] as? String)
        case "delete": e.deleteSelected()
        case "split": e.split()
        case "split-all": e.splitAll()
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
        case "undo": e.undo()
        case "redo": e.redo()
        case "look": e.setLookField(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "three": e.setThree(r["track"] as? String ?? "", r["kind"] as? String ?? "")
        case "volume": e.setVolume((r["number"] as? Double ?? 100) / 100)
        case "add-move": e.addMove()
        case "pattern": e.pattern(r["kind"] as? String ?? "")
        case "find-device": e.findDevice()
        case "forget-device": e.forgetDevice()
        case "start": e.setTimes(start: Self.seconds(r["kind"] as? String), end: nil)
        case "end": e.setTimes(start: nil, end: Self.seconds(r["kind"] as? String))
        case "timeline":
            // The zoom buttons: view state only, nothing in the edit changes.
            switch r["track"] as? String {
            case "zoom-in": e.zoomStep(1.5)
            case "zoom-out": e.zoomStep(1 / 1.5)
            case "zoom-fit": e.setZoom(1, start: 0)
            case "wheel": e.setWheelZoom(!e.wheelZoom)
            default: break
            }
        default: break
        }
    }

    // MARK: Recording

    /// Starts a recording of `source`, or opens its picker first. `reply` is nil when the
    /// menu bar asked: then a failure brings the window forward, where the sidebar shows it.
    private func start(_ source: String, reply: ExactReply?) {
        // A second picker would open over the first; the first one is answered when it closes.
        if picker != nil { reply?.send(["ok": false, "error": ""]); return }
        guard recorder == nil, !starting else { return started("Already recording.", reply) }
        guard CGPreflightScreenCaptureAccess() else {
            if !context.agent { CGRequestScreenCaptureAccess() }
            return started("Allow Exact Studio in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen it.", reply)
        }
        let picks: [String: SourcePicker.Kind] = ["pick-display": .display, "pick-window": .window, "pick-simulator": .simulator]
        if source == "area" {
            let picker = AreaPicker()
            self.picker = picker
            curtain.close()
            picker.pick { [weak self] area in
                self?.picker = nil
                guard let area else { self?.curtain.open(); self?.started("", reply); return }
                self?.begin(source, area: area, reply: reply)
            }
        } else if let kind = picks[source] {
            let found = SourcePicker.candidates(kind)
            guard !found.isEmpty else {
                // @ref LLP 0001#sources — no empty overlay; the card says what to do
                return started(kind == .simulator ? "Open a Simulator or an emulator first." : "There is nothing to record on the screen.", reply)
            }
            let picker = SourcePicker(kind)
            self.picker = picker
            curtain.close()
            picker.pick(found) { [weak self] picked in
                self?.picker = nil
                guard let picked else { self?.curtain.open(); self?.started("", reply); return }
                self?.begin(picked, area: nil, reply: reply)
            }
        } else {
            begin(source, area: nil, reply: reply)
        }
    }

    /// The end of a start: `error` is "" when it worked or was cancelled.
    /// `then` is an agent's: it gets the error ("" when it started), and no window comes forward.
    private func started(_ error: String, _ reply: ExactReply?, _ then: ((String) -> Void)? = nil) {
        if error != lastError {
            lastError = error
            context.changed("status")
        }
        reply?.send(["ok": error.isEmpty && recorder != nil, "error": error])
        then?(error)
        if reply == nil && then == nil && !error.isEmpty { showMainWindow() }
    }

    private func begin(_ source: String, area: (NSScreen, CGRect)?, reply: ExactReply?, sound: Bool? = nil, by: String = "app",
                       then: ((String) -> Void)? = nil) {
        starting = true
        // @ref LLP 0001#out-of-the-way — the app stays out of the way while it records, an agent's start too
        curtain.close()
        let id = Self.newID()
        let folder = Library.recordings.appendingPathComponent(id, isDirectory: true)
        let sound = sound ?? self.sound
        Task { @MainActor in
            defer { starting = false }
            do {
                let r = try await Recorder.make(source: source, area: area, folder: folder, id: id, sound: sound)
                try await r.start()
                recorder = r
                recordingBy = by
                recordingSound = sound
                recordingSince = Date()
                updateStatusItem()
                context.changed("status")
                started("", reply, then)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                curtain.open()
                started("Couldn’t start recording: \(error)", reply, then)
            }
        }
    }

    private func setSound(_ on: Bool) {
        guard on != sound else { return }
        sound = on
        Settings.store.set(on, forKey: Self.soundKey)
        soundItem?.state = on ? .on : .off
        context.changed("status")
    }

    /// `stoppedBy`: "app", "menu", "agent" or "max". `then` is an agent's: the finished recording, or the error.
    private func stop(reply: ExactReply?, stoppedBy: String = "app", then: ((RecordingMeta?, String) -> Void)? = nil) {
        guard let r = recorder else {
            reply?.send(["ok": false, "error": "Not recording.", "id": ""])
            then?(nil, "Not recording.")
            return
        }
        recorder = nil
        curtain.open()
        maxTimer?.invalidate()
        maxTimer = nil
        let by = recordingBy
        updateStatusItem()
        context.changed("status")
        Task { @MainActor in
            do {
                let meta = try await r.stop()
                last = ["id": meta.id, "folder": r.folder.path, "name": meta.name, "kind": meta.kind, "duration": meta.duration,
                        "by": by, "stoppedBy": stoppedBy]
                finished = meta.id
                context.changed("recordings")
                context.changed("status")
                reply?.send(["ok": true, "error": "", "id": meta.id])
                then?(meta, "")
            } catch {
                try? FileManager.default.removeItem(at: r.folder)
                last = ["id": "", "folder": "", "name": r.name, "kind": r.kind.rawValue, "duration": 0, "by": by, "stoppedBy": stoppedBy,
                        "error": "\(error)"]
                context.changed("recordings")
                reply?.send(["ok": false, "error": "\(error)", "id": ""])
                then?(nil, "\(error)")
            }
        }
    }

    private static func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Agents

    /// Answers agents' requests from the control folder: sources, start, status, stop.
    // @ref LLP 0007#the-channel — the app records for the agent, so the permission and the menu bar mark are the app's
    private func serve(_ root: URL) {
        let server = ControlServer(root: root) { [weak self] request, reply in
            guard let self else { return reply(["ok": false, "code": "failed", "error": "Exact Studio is closing."]) }
            self.agentRequest(request, reply: reply)
        }
        do {
            try server.start()
            control = server
        } catch {
            NSLog("exact-studio: agents can't record: \(error)")
        }
    }

    private func agentRequest(_ r: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        func refuse(_ code: String, _ error: String) { reply(["ok": false, "code": code, "error": error, "last": last]) }
        let permission = "Screen Recording is not allowed for Exact Studio. A person must allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Exact Studio."
        switch r["op"] as? String ?? "" {
        case "sources":
            let allowed = CGPreflightScreenCaptureAccess()
            if !allowed && !context.agent { CGRequestScreenCaptureAccess() }
            reply(["ok": true, "allowed": allowed, "items": agentSources().map(\.json)])
        case "status":
            reply(agentStatus())
        case "start":
            let source = r["source"] as? String ?? ""
            guard source.hasPrefix("window:") || source.hasPrefix("display:") else { return refuse("nomatch", "No source \(source).") }
            // @ref LLP 0007#never-take-over — a running recording, or a picker the person has open, is theirs
            if let rec = recorder {
                return refuse("busy", "Already recording \(rec.name) (\(rec.kind.rawValue)), started \(recordingBy == "agent" ? "by an agent" : "in the app") \(Int(Date().timeIntervalSince(recordingSince))) s ago. It was left running; stop it first if it is yours.")
            }
            if starting { return refuse("busy", "A recording is starting in Exact Studio now. It was left alone.") }
            if picker != nil { return refuse("busy", "A person has a recording picker open in Exact Studio. It was left alone; try again when it is closed.") }
            guard CGPreflightScreenCaptureAccess() else {
                if !context.agent { CGRequestScreenCaptureAccess() }
                return refuse("permission", permission)
            }
            var area: (NSScreen, CGRect)?
            if let a = r["area"] as? [NSNumber], a.count == 4 {
                let did = UInt32(source.dropFirst(8))
                guard source.hasPrefix("display:"),
                      let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == did }) else {
                    return refuse("nomatch", "That display is gone.")
                }
                let rect = CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
                guard rect.width >= 40, rect.height >= 40, CGRect(origin: .zero, size: screen.frame.size).contains(rect) else {
                    return refuse("nomatch", "That area is not inside the display.")
                }
                area = (screen, rect)
            }
            let sound = (r["sound"] as? String).flatMap { ["on": true, "off": false][$0] }
            let limit = (r["max"] as? NSNumber)?.doubleValue ?? 0
            begin(source, area: area, reply: nil, sound: sound, by: "agent") { [weak self] error in
                guard let self else { return }
                guard error.isEmpty, let rec = self.recorder else {
                    let gone = error.contains("gone") ? "That window or display is gone; list the sources again. " : ""
                    return refuse(CGPreflightScreenCaptureAccess() ? "failed" : "permission", gone + (CGPreflightScreenCaptureAccess() ? error : permission))
                }
                self.maxSeconds = limit
                if limit > 0 {
                    self.maxTimer = Timer.scheduledTimer(withTimeInterval: limit, repeats: false) { [weak self, weak rec] _ in
                        guard let self, let rec, self.recorder === rec else { return }
                        self.stop(reply: nil, stoppedBy: "max")
                    }
                }
                reply(self.agentStatus())
            }
        case "stop":
            guard let rec = recorder else {
                if starting { return refuse("busy", "A recording is starting; ask again in a moment.") }
                let ended = (last["id"] as? String).map { $0.isEmpty ? "" : " The last recording, \($0), was stopped \(Self.stopper(last["stoppedBy"] as? String ?? ""))." } ?? ""
                return refuse("notrecording", "Not recording." + ended)
            }
            if recordingBy != "agent" && (r["any"] as? Bool) != true {
                return refuse("notyours", "The recording running now (\(rec.name), \(Int(Date().timeIntervalSince(recordingSince))) s) was started in the app, not by an agent. It was left running. Stop it only if the person asked you to (any: true, or --any).")
            }
            stop(reply: nil, stoppedBy: "agent") { [weak self] meta, error in
                guard let self else { return }
                guard meta != nil else { return refuse("failed", error) }
                reply(["ok": true, "recording": false, "last": self.last])
            }
        default:
            refuse("unknown", "Exact Studio answers sources, status, start and stop.")
        }
    }

    private static func stopper(_ by: String) -> String {
        ["menu": "from the menu bar", "app": "in the app", "agent": "by an agent", "max": "by itself at its --max limit"][by] ?? "in the app"
    }

    private func agentStatus() -> [String: Any] {
        guard let rec = recorder else {
            return ["ok": true, "recording": false, "starting": starting, "sound": sound, "last": last]
        }
        return ["ok": true, "recording": true, "starting": false, "id": rec.id, "folder": rec.folder.path, "name": rec.name, "kind": rec.kind.rawValue,
                "by": recordingBy, "elapsed": Date().timeIntervalSince(recordingSince), "max": recordingBy == "agent" ? maxSeconds : 0,
                "sound": recordingSound, "last": last]
    }

    /// What an agent can name: the displays, the other apps' windows and the Simulators, as the pickers list them.
    // @ref LLP 0007#names — the same lists the pickers end in, so a Simulator is cropped to the phone and a window keeps its shape
    private func agentSources() -> [SourceEntry] {
        let displays = SourcePicker.candidates(.display).map { c in
            SourceEntry(id: c.source, kind: "display", name: c.title, width: Int(c.frame.width), height: Int(c.frame.height))
        }
        let windows = SourcePicker.candidates(.window).map { c in
            SourceEntry(id: c.source, kind: "window", name: c.title.isEmpty || c.title == c.app ? c.app : "\(c.app) — \(c.title)",
                        app: c.app, title: c.title, width: Int(c.frame.width), height: Int(c.frame.height))
        }
        let devices = SourcePicker.candidates(.simulator).map { c in
            SourceEntry(id: c.source, kind: c.sourceKind.rawValue, name: c.name, app: c.sourceKind == .emulator ? "Android Emulator" : c.app,
                        title: c.title, width: Int(c.frame.width), height: Int(c.frame.height))
        }
        return SourceEntry.named(displays + devices + windows)
    }

    // MARK: Menu bar

    // @ref LLP 0001#menu-bar — always there; one click stops a recording
    /// One item in the menu bar while the app runs. Idle, it opens a menu that starts each
    /// picker; while recording, it turns red with the time, and one click stops.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, symbol, source) in [("Record Display", "display", "pick-display"), ("Record Window", "macwindow", "pick-window"),
                                        ("Record Area", "rectangle.dashed", "area"), ("Record Simulator", "iphone", "pick-simulator")] {
            let m = NSMenuItem(title: title, action: #selector(recordFromMenuBar(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = source
            m.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(m)
        }
        menu.addItem(.separator())
        let s = NSMenuItem(title: "System Sound", action: #selector(toggleSoundFromMenuBar), keyEquivalent: "")
        s.target = self
        s.state = sound ? .on : .off
        menu.addItem(s)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Exact Studio", action: #selector(openFromMenuBar), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Exact Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem = item
        statusMenu = menu
        soundItem = s
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let recording = recorder != nil
        button.image = Self.glyph(recording: recording)
        button.imagePosition = .imageLeading
        button.contentTintColor = recording ? .systemRed : nil
        button.toolTip = recording ? "Stop Recording" : "Exact Studio"
        clock?.invalidate()
        clock = nil
        if recording {
            // A click stops at once; the menu comes back when it has.
            item.menu = nil
            button.target = self
            button.action = #selector(stopFromMenuBar)
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed,
                                                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
            let tick = { [weak self, weak button] in
                guard let self else { return }
                let s = Int(Date().timeIntervalSince(self.recordingSince))
                button?.attributedTitle = NSAttributedString(string: String(format: " %d:%02d", s / 60, s % 60), attributes: attrs)
            }
            tick()
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.action = nil
            item.menu = statusMenu
        }
    }

    /// Our mark: a rounded frame around a dot (recording: around a stop square). A template,
    /// so it follows the menu bar's light or dark look; drawn per resolution, so it stays crisp.
    private static func glyph(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 3.5, width: 14, height: 11), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()
            if recording {
                NSBezierPath(roundedRect: NSRect(x: 6.5, y: 6.5, width: 5, height: 5), xRadius: 1, yRadius: 1).fill()
            } else {
                NSBezierPath(ovalIn: NSRect(x: 6.25, y: 6.25, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Stop Recording" : "Exact Studio"
        return image
    }

    @objc private func recordFromMenuBar(_ sender: NSMenuItem) {
        start(sender.representedObject as? String ?? "", reply: nil)
    }

    @objc private func toggleSoundFromMenuBar() { setSound(!sound) }

    @objc private func openFromMenuBar() { showMainWindow() }

    /// The app's own window, forward and unminimised.
    private func showMainWindow() {
        curtain.open()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let w = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func stopFromMenuBar() {
        stop(reply: nil, stoppedBy: "menu")
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
/// resize it; drag a text or an image to move it; drop a picture file on it to add an image, or a sound file to add a sound.
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
        host.showsPaths = props["paths"] != "false"
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
    private enum Drag { case subject(CGPoint, Placement), text(String, CGPoint, CGPoint), turn(CGPoint, Double, Double), landing(String, String?, CGPoint, CGPoint) }
    private var drag: Drag?
    /// Whether the pointer moved since the press: a plain click places nothing.
    private var dragged = false
    private var ticking: Any?
    private let motion = MotionPathLayer()
    var showsPaths = true {
        didSet { if showsPaths != oldValue { drawOverlay() } }
    }
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
    /// A rectangle being dragged by its sides (a corner moves two) or as a whole: the crop's, or a mask's.
    private enum RectDrag { case edges(left: Bool, right: Bool, top: Bool, bottom: Bool, from: CGPoint, start: UnitRect), move(CGPoint, UnitRect) }
    private var cropDrag: RectDrag?
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
        layer?.addSublayer(motion)
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
        // A selected mask: its rectangle and the crop's handles, on the video where it is now.
        maskLines.fillColor = nil
        maskLines.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        maskLines.lineWidth = 1.5
        maskHandles.fillColor = nil
        maskHandles.strokeColor = NSColor.white.cgColor
        maskHandles.lineWidth = 4
        maskHandles.lineCap = .round
        maskHandles.shadowColor = NSColor.black.cgColor
        maskHandles.shadowOpacity = 0.5
        maskHandles.shadowRadius = 2
        maskHandles.shadowOffset = .zero
        // Clipped to the video: a mask the zoom pushes past the edge shows only its part on the video.
        maskClip.masksToBounds = true
        for l in [maskLines, maskHandles] { maskClip.addSublayer(l) }
        layer?.addSublayer(maskClip)
    }

    // MARK: Masks
    // @ref LLP 0006#follows-the-video — the box sits on the video as it is placed and zoomed now

    private let maskClip = CALayer()
    private let maskLines = CAShapeLayer()
    private let maskHandles = CAShapeLayer()
    /// A mask's rectangle being dragged, and the view transform it was grabbed in.
    private var maskDrag: (id: String, grab: RectDrag, view: CGAffineTransform)?

    /// Where the full recorded frame's unit coordinates (origin top-left, before the crop), a mask's
    /// rect, are in this view at the playhead: nil while the video is turned in 3D or spun, where a flat
    /// box cannot follow it.
    private var recordingInView: CGAffineTransform? {
        guard let editor, let m = editor.framing.frameToCanvas(at: editor.playhead) else { return nil }
        let c = editor.framing.canvas
        let t = m.concatenating(CGAffineTransform(scaleX: video.width / c.width, y: video.height / c.height))
            .concatenating(CGAffineTransform(translationX: video.minX, y: video.minY))
        return abs(t.b) < 1e-6 && abs(t.c) < 1e-6 ? t : nil
    }

    private static func box(_ u: UnitRect) -> CGRect { CGRect(x: u.x, y: u.y, width: u.w, height: u.h) }

    /// What a press at `p` takes hold of a rectangle drawn at `r` (both in this view): a side, or two
    /// near a corner; else the inside, to move it; else nothing. `u` is the press in the rectangle's units.
    /// A side is held from up to 14 points outside it, and from inside only up to a quarter of the box,
    /// so a small box still moves when pressed in its middle.
    private static func grab(_ p: CGPoint, _ r: CGRect, unit u: CGPoint, start: UnitRect) -> RectDrag? {
        let reach: CGFloat = 14, inX = min(reach, r.width / 4), inY = min(reach, r.height / 4)
        let spanY = p.y >= r.minY - reach && p.y <= r.maxY + reach, spanX = p.x >= r.minX - reach && p.x <= r.maxX + reach
        let left = p.x >= r.minX - reach && p.x <= r.minX + inX && spanY
        let right = p.x >= r.maxX - inX && p.x <= r.maxX + reach && spanY && !left
        let bottom = p.y >= r.minY - reach && p.y <= r.minY + inY && spanX
        let top = p.y >= r.maxY - inY && p.y <= r.maxY + reach && spanX && !bottom
        if left || right || top || bottom { return .edges(left: left, right: right, top: top, bottom: bottom, from: u, start: start) }
        return r.contains(p) ? .move(u, start) : nil
    }

    /// The rectangle a grab has been dragged to, at `u`: inside `bounds` (the whole frame for the crop,
    /// the visible video for a mask), at least `m` on each side.
    private static func dragged(_ d: RectDrag, to u: CGPoint, minimum m: Double, within bounds: UnitRect = .full) -> UnitRect {
        let bx0 = bounds.x, bx1 = bounds.x + bounds.w, by0 = bounds.y, by1 = bounds.y + bounds.h
        switch d {
        case let .move(from, start):
            var c = start
            c.x = min(max(start.x + u.x - from.x, bx0), max(bx0, bx1 - start.w))
            c.y = min(max(start.y + u.y - from.y, by0), max(by0, by1 - start.h))
            return c
        case let .edges(left, right, top, bottom, from, start):
            var x0 = start.x, x1 = start.x + start.w, y0 = start.y, y1 = start.y + start.h
            let dx = u.x - from.x, dy = u.y - from.y
            if left { x0 = min(max(start.x + dx, bx0), x1 - m) }
            if right { x1 = max(min(start.x + start.w + dx, bx1), x0 + m) }
            if top { y0 = min(max(start.y + dy, by0), y1 - m) }
            if bottom { y1 = max(min(start.y + start.h + dy, by1), y0 + m) }
            return UnitRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
    }

    /// An L at each corner, a short bar at the middle of each side long enough for one.
    private static func handles(_ r: CGRect) -> CGPath {
        let k = min(18, r.width / 4, r.height / 4), b = min(12, r.width / 6, r.height / 6)
        let h = CGMutablePath()
        for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            h.move(to: CGPoint(x: c.x + dx * k, y: c.y)); h.addLine(to: c); h.addLine(to: CGPoint(x: c.x, y: c.y + dy * k))
        }
        if r.width >= 60 {
            h.move(to: CGPoint(x: r.midX - b, y: r.minY)); h.addLine(to: CGPoint(x: r.midX + b, y: r.minY))
            h.move(to: CGPoint(x: r.midX - b, y: r.maxY)); h.addLine(to: CGPoint(x: r.midX + b, y: r.maxY))
        }
        if r.height >= 60 {
            h.move(to: CGPoint(x: r.minX, y: r.midY - b)); h.addLine(to: CGPoint(x: r.minX, y: r.midY + b))
            h.move(to: CGPoint(x: r.maxX, y: r.midY - b)); h.addLine(to: CGPoint(x: r.maxX, y: r.midY + b))
        }
        return h
    }

    /// The selected mask's box and handles, or none.
    private func drawMask() {
        guard !cropping, let s = editor?.selectedSegment, s.kind == "mask", let u = s.rect, let t = maskDrag?.view ?? recordingInView else {
            maskLines.path = nil; maskHandles.path = nil; return
        }
        maskClip.frame = video
        for l in [maskLines, maskHandles] { l.frame = maskClip.bounds }
        let r = Self.box(u).applying(t).offsetBy(dx: -video.minX, dy: -video.minY)
        maskLines.path = CGPath(rect: r, transform: nil)
        // Thinner on a small box, so the handles never hide what it covers.
        maskHandles.lineWidth = min(4, max(2, min(r.width, r.height) / 8))
        maskHandles.path = Self.handles(r)
    }

    /// A press on the selected mask's box, or on a mask showing now: hold it to move or resize it.
    private func maskDown(_ p: CGPoint) -> Bool {
        guard let editor, video.insetBy(dx: -14, dy: -14).contains(p), let t = recordingInView else { return false }
        let at = p.applying(t.inverted())
        if let s = editor.selectedSegment, s.kind == "mask", let u = s.rect, let g = Self.grab(p, Self.box(u).applying(t), unit: at, start: u) {
            maskDrag = (s.id, g, t)
            return true
        }
        let now = editor.playhead
        if let s = editor.edits.masks.last(where: { now >= $0.start && now < $0.end && $0.rect.map { Self.box($0).applying(t).contains(p) } == true }), let u = s.rect {
            editor.select(s.id)
            maskDrag = (s.id, .move(at, u), t)
            return true
        }
        return false
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
        for l in [player, still, outline, guides, maskClip] as [CALayer] { l.opacity = cropping ? 0 : 1 }
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
        cropHandles.path = Self.handles(r)
    }

    private func cropDown(_ p: CGPoint) {
        let f = frameRect
        let u = CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
        // Within reach of a side: that side moves; of two sides (a corner): both.
        cropDrag = Self.grab(p, onFrame(cropNow), unit: u, start: cropNow)
    }

    private func cropDragged(_ p: CGPoint) {
        guard let cropDrag else { return }
        let f = frameRect
        let u = CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
        cropLive = Self.dragged(cropDrag, to: u, minimum: Self.cropMinimum)
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
            // A mask's box follows the video as it moves.
            guard let self, self.editor?.selectedImage != nil || self.editor?.selectedSegment?.kind == "mask" || self.showsPaths, self.drag == nil, self.maskDrag == nil else { return }
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
        motion.frame = bounds
        for l in [cropShade, cropGrid, cropLines, cropHandles] { l.frame = bounds }
        CATransaction.commit()
        layoutCrop()
        drawOverlay()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Motion paths
    // @ref LLP 0005#show-what-moves

    private var motionShown: (path: MotionPath, image: String?)? {
        guard showsPaths, !cropping, let editor, !editor.isPlaying else { return nil }
        let f = editor.framing, t = editor.playhead
        if let s = editor.selectedImage { return f.motionPath(image: s, at: t).map { ($0, s.id) } }
        return f.motionPath(at: t).map { ($0, nil) }
    }

    private func drawMotion() {
        let shown = motionShown
        let selected = shown?.image == nil ? editor?.selectedMove?.id : editor?.selectedImageMove?.move.id
        motion.show(shown?.path, selected: selected, video: video, canvas: editor?.framing.canvas ?? .zero, scale: window?.backingScaleFactor ?? 2)
    }

    private func landingDown(_ p: CGPoint) -> Bool {
        guard let editor, let shown = motionShown, let id = motion.landing(at: p) else { return false }
        let moves = shown.image.flatMap { i in editor.edits.segments.first { $0.id == i }?.moves } ?? editor.edits.moves
        guard let m = moves.first(where: { $0.id == id }) else { return false }
        editor.select(shown.image.map { Editor.childID("im", image: $0, id) } ?? "m:" + id)
        drag = .landing(id, shown.image, unit(p), CGPoint(x: m.to.x, y: m.to.y))
        return true
    }

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
        drawMask()
        drawMotion()
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
        // The selected mask's box first: its handles reach a little outside it.
        if case let p = convert(e.locationInWindow, from: nil), editor.selectedSegment?.kind == "mask", maskDown(p) { drag = nil; return drawOverlay() }
        if landingDown(convert(e.locationInWindow, from: nil)) { return drawOverlay() }
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
        } else if maskDown(convert(e.locationInWindow, from: nil)) {
            drag = nil
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
        if let md = maskDrag, let editor {
            dragged = true
            let u = convert(e.locationInWindow, from: nil).applying(md.view.inverted())
            // Kept on the visible video: a mask is placed where it can be seen.
            let c = editor.meta.crop
            editor.setMaskRect(md.id, Self.dragged(md.grab, to: u, minimum: 0.02 * min(c.w, c.h), within: c), live: true)
            return drawOverlay()
        }
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
        case let .landing(id, image, from, start):
            let x = snapped(start.x + u.x - from.x, &lines), y = snapped(start.y + u.y - from.y, &rows)
            editor.setLanding(id, image: image, x: x, y: y, live: true)
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
        if let md = maskDrag {
            maskDrag = nil
            if dragged, let u = editor?.edits.segments.first(where: { $0.id == md.id })?.rect { editor?.setMaskRect(md.id, u, live: false) }
            return drawOverlay()
        }
        guard let editor, let drag else { return }
        switch drag {
        case .subject: editor.endPlace()
        case let .landing(id, image, _, _):
            let moves = image.flatMap { i in editor.edits.segments.first { $0.id == i }?.moves } ?? editor.edits.moves
            if dragged, let m = moves.first(where: { $0.id == id }) { editor.setLanding(id, image: image, x: m.to.x, y: m.to.y, live: false) }
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

    // MARK: Dropping a picture or a sound

    private func picture(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { (Pictures.types + Sounds.types).contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        editor != nil && !cropping && picture(sender) != nil ? .copy : []
    }

    /// A picture file dropped on the preview becomes an image at the playhead, where it was dropped;
    /// a sound file, a sound at the playhead.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let editor, !cropping, let url = picture(sender) else { return false }
        if Sounds.types.contains(url.pathExtension.lowercased()) { editor.addSound(url); return true }
        let u = unit(convert(sender.draggingLocation, from: nil))
        editor.addImage(url, at: CGPoint(x: min(max(u.x, 0), 1), y: min(max(u.y, 0), 1)))
        return true
    }
}

final class PlayClock: ExactNativeInstance {
    private let label = NSTextField(labelWithString: "")
    private let studio: Studio
    private var clip = ""
    private weak var editor: Editor?
    private weak var player: AVPlayer?
    private var observer: Any?

    init(_ studio: Studio, _ props: [String: String], _ events: ExactNativeEvents) {
        self.studio = studio
        super.init(events: events)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        events.intrinsicSize(CGSize(width: 112, height: 20))
        try? setProps(props)
    }

    override var view: ExactNativeView { label }

    override func setProps(_ props: [String: String]) throws {
        let next = props["clip"] ?? ""
        guard next != clip else { return }
        clip = next
        attach(studio.editor(next))
    }

    private func attach(_ next: Editor?) {
        editor?.unlisten(self)
        if let player, let observer { player.removeTimeObserver(observer) }
        observer = nil
        editor = next
        player = next?.player
        guard let next else { label.stringValue = ""; return }
        next.listen(self) { [weak self] in self?.show() }
        observer = next.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in self?.show() }
        show()
    }

    private func show() {
        guard let editor else { return }
        let map = editor.map, total = map.outputDuration
        label.stringValue = "\(TimelineMenus.clock(min(map.output(editor.playhead), total))) / \(TimelineView.clock(total, tenths: false))"
    }

    override func destroy() { attach(nil) }
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
        strip.clipsToBounds = true
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
#else
final class Studio: ExactModule {}
let exactModule: ExactModule.Type = Studio.self
#endif
