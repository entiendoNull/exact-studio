// exact-studio: read, check, template, preview and render recordings from the
// command line, with the app's own renderer (modules/apple/Compositor.swift and
// friends are compiled in), so a frame or an export here is the app's.
// Built and run by ../exact-studio; see docs/edits.md.
import AppKit
import AVFoundation

setvbuf(stdout, nil, _IOLBF, 0)
_ = NSApplication.shared
CursorArt.prepare()

let usage = """
exact-studio — edit Exact Studio recordings from the command line

  exact-studio list                         the recordings, newest first
  exact-studio show <id> [--json]           its length, clip parts, segments, sounds, moves and look
  exact-studio validate <id> [--since <old edits.json>]
                                            checks edits.json and look.json; exit 1 on a problem. A broken rule
                                            prints its id and two lines: what the rule is, then the other item and
                                            one way out. --since: a rule the old file broke too is a note, not a failure
  exact-studio frame <id> <time> [--out f.png] [--source] [--raw]
                                            renders one frame at <time> seconds of the video
                                            (--source: of the recording); default .exact/frame.png
                                            --raw: the full recorded frame there, before the crop, at its own pixel
                                            size, with no edits: a pixel at (px, py) is (px/width, py/height) in a
                                            mask's rect
  exact-studio strip <id> <from> <to> [--frames 5] [--width 960] [--out f.png] [--source]
                                            renders frames evenly from <from> to <to> seconds of the video (--source:
                                            of the recording) side by side in one PNG, to see a motion at a glance;
                                            default .exact/strip.png
  exact-studio export <id> [--out f.mp4] [--quality best|1080p|720p|small]
                                            renders the video; default ~/Movies/Exact Studio/<name>.mp4
  exact-studio template <id> <name>         replaces texts, effects, zooms and moves with a template fitted to the
                                            recording's length, clicks and look.json's frame; prints the lines to
                                            fill: a [bracketed] text is unfilled, and validate and export refuse it
  exact-studio template --list              the templates, each with what it is for
  exact-studio image <id> <picture> [--at <t>] [--for <seconds>]
                                            copies a picture into the recording's images/ folder and adds an
                                            image on top of the video at <t> seconds of the recording (default 0)
                                            for <seconds> (default 4), on the first image lane free then (else a
                                            new one); prints the new segment, ready to edit
  exact-studio sound <id> <audio file> [--at <t>] [--for <seconds>]
                                            copies a sound file (music, an effect) into the recording's sounds/
                                            folder and adds a sound from <t> seconds of the recording (default 0)
                                            playing <seconds> of the file (default all of it, or what fits);
                                            it plays straight through, not cut by the video's cuts; prints it
  exact-studio mask <id> --rect x,y,w,h [--at <t>] [--for <seconds>] [--style blur|pixels|solid] [--color '#000000']
                                            hides a part of the recording (an API key, an email, a name): x, y, w, h
                                            are 0–1 of the full recorded frame (before the crop; frame --raw shows
                                            it), origin top-left, so a later crop never moves it off the secret;
                                            from <t> seconds of the recording (default 0) for <seconds> (default 4), at
                                            full strength throughout; it follows the video through zooms, moves and 3D;
                                            on the first effect lane free then (else a new one); prints the new segment
  exact-studio split <id> <t> [<item>]      cuts at <t> seconds of the recording: the clip, or the segment or sound whose
                                            id is <item> (an image's or a text's effect: <item>:<effect>); its halves join, so the
                                            video looks and sounds the same; prints what it cut
  exact-studio split <id> <t> --all         Split All Lanes: the clip and every block under <t>; moves are never cut
  exact-studio schema                       prints where the docs and JSON Schemas are

  docs/edits.md is the file format; docs/effects.md says what each effect, move, animation, style and
  transition looks like on screen, its timing and limits, with a picture strip: read an entry before using it.

Recording, through the Exact Studio app (opened when it is not running):
  exact-studio sources [--no-launch]        what can be recorded now, one per line, each with the name record start takes
  exact-studio record start <source> [--sound on|off] [--max <seconds>] [--no-launch]
                                            starts recording at once, with no picker. <source> is a name from sources:
                                            display:1, window:Safari, simulator:iPhone 17 Pro, a part of a name, or
                                            area:x,y,w,h[@<display>] in points from the display's top-left. Refused when a
                                            recording is running, when nothing or more than one thing matches (the
                                            candidates are listed) or without the Screen Recording permission.
                                            --sound: the system's sound (default: the app's System Sound setting);
                                            --max: stops by itself after that many seconds
  exact-studio record status                recording or not; the source, how long, the id; the last recording that ended
  exact-studio record stop [--any]          stops the recording an agent started and prints its id and folder, ready
                                            to show, edit and export; --any also stops one a person started in the app
  Exit codes: 1 refused, 2 usage, 3 needs a person (the permission), 4 the app did not answer.
  EXACT_STUDIO_CONTROL names another control folder (then the app is never opened); EXACT_STUDIO_NO_LAUNCH=1
  (or --no-launch) never opens the app; EXACT_STUDIO_APP names the Exact Studio.app to open.

  <id> is a recording folder's name, a unique start of one, or "latest".
  --library <dir> (or EXACT_STUDIO_LIBRARY) names the Recordings folder;
  the default is ~/Movies/Exact Studio/Recordings.
  When edits.json or look.json can't be read, every verb but validate stops with exit 1 and never writes over it;
  validate lists why, and show --json gives the folder with the problems under "unreadable".
  The app watches these files: an edit made here shows in its open preview within a second.
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let library = URL(fileURLWithPath: option("--library") ?? ProcessInfo.processInfo.environment["EXACT_STUDIO_LIBRARY"]
    ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Exact Studio/Recordings").path)

struct Recording {
    let id: String, folder: URL, meta: RecordingMeta
    var edits: Edits, look: Look, cursor: [Point]
    var unreadable: [String]
}

func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func all() -> [(String, RecordingMeta)] {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
    return ids.compactMap { id in (try? decode(RecordingMeta.self, library.appendingPathComponent(id).appendingPathComponent("meta.json"))).map { (id, $0) } }
        .sorted { $0.1.created > $1.1.created }
}

// @ref LLP 0004#a-file-that-cannot-be-read
func open(_ ref: String, readable: Bool = true) -> Recording {
    let list = all()
    let id: String
    if ref == "latest", let first = list.first { id = first.0 }
    else if list.contains(where: { $0.0 == ref }) { id = ref }
    else {
        let hits = list.filter { $0.0.hasPrefix(ref) }
        guard hits.count == 1 else { fail(hits.isEmpty ? "no recording \(ref) in \(library.path)" : "\(ref) matches \(hits.map(\.0).joined(separator: ", "))") }
        id = hits[0].0
    }
    let folder = library.appendingPathComponent(id)
    let meta = list.first { $0.0 == id }!.1
    var unreadable: [String] = []
    func load<T: Decodable>(_ name: String, _ fallback: T) -> T {
        do { return try EditFile.read(T.self, folder.appendingPathComponent(name)) ?? fallback } catch {
            unreadable.append("\(name): \(EditFile.problem(error))")
            return fallback
        }
    }
    let edits = load("edits.json", Edits()), look = load("look.json", Look())
    let cursor = (try? decode([Point].self, folder.appendingPathComponent("cursor.json"))) ?? []
    if readable, !unreadable.isEmpty {
        fail((unreadable + ["\(id) can't be read, so nothing was done; the file is left as it is. Fix it (exact-studio validate \(id) lists the problems)."]).joined(separator: "\n"), code: 1)
    }
    return Recording(id: id, folder: folder, meta: meta, edits: edits, look: look, cursor: cursor, unreadable: unreadable)
}

func write<T: Encodable>(_ value: T, _ url: URL) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do { try e.encode(value).write(to: url) } catch { fail("couldn't write \(url.path): \(error)") }
}

func composition(_ r: Recording) -> (asset: AVAsset, video: AVMutableVideoComposition, map: TimeMap, sounds: [CMPersistentTrackID: String]) {
    let asset = AVURLAsset(url: r.folder.appendingPathComponent("capture.mov"))
    let state = RenderState(Framing(meta: r.meta, look: r.look, edits: r.edits, cursor: r.cursor, folder: r.folder))
    do { return try Composition.make(asset: asset, meta: r.meta, edits: r.edits, state: state) } catch { fail("\(error)") }
}

func stamp(_ s: Double) -> String { (s < 0 ? "-" : "") + String(format: "%d:%05.2f", Int(abs(s)) / 60, abs(s).truncatingRemainder(dividingBy: 60)) }

/// What is wrong with a mask's own fields; empty when nothing is.
func maskProblems(_ s: Segment) -> [String] {
    var out: [String] = []
    if let u = s.rect {
        if u.w <= 0 || u.h <= 0 { out.append("its rect needs a width and a height above 0") }
        if u.x < 0 || u.y < 0 || u.x + u.w > 1.0001 || u.y + u.h > 1.0001 {
            out.append("its rect must lie inside the frame: x, y, w, h are 0–1 of the full recorded frame (before the crop), with x + w and y + h at most 1")
        }
    } else {
        out.append("a mask needs its rect, {\"x\", \"y\", \"w\", \"h\"} in 0–1 of the full recorded frame (before the crop)")
    }
    if let style = s.style, !Segment.maskStyles.contains(style) { out.append("no mask style \(style); one of \(Segment.maskStyles.joined(separator: ", "))") }
    if Segment.maskHex(s.color) == nil { out.append("color \(s.color ?? "") is not \"#RRGGBB\" or a text colour (black, white, yellow, pink, blue, mint)") }
    if let r = s.radius, !(0...0.5).contains(r) { out.append("radius must be 0–0.5") }
    return out
}

func joinWords(_ before: String?, _ after: String?) -> String {
    [before.map { "  joined after \($0)" }, after.map { "  joined before \($0)" }].compactMap { $0 }.joined()
}

func joins(_ s: Segment, _ pool: [Segment]) -> String {
    joinWords(pool.first { $0.joins(s) }?.id, pool.first { s.joins($0) }?.id)
}

func describe(_ ref: ItemRef, _ e: Edits, map: TimeMap, short: Bool = false) -> String {
    switch ref.kind {
    case "move":
        let t = e.moves.first { $0.id == ref.id }.map { " at \(stamp($0.t))" } ?? ""
        return "move \(ref.id)" + (short ? "" : t)
    case "sound":
        guard !short, let s = e.sounds.first(where: { $0.id == ref.id }) else { return "sound \(ref.id)" }
        return "sound \(s.id) (\(stamp(s.start)), \(s.length)s of \(s.file))"
    case "image-move", "image-effect":
        let image = e.segments.first { $0.id == ref.image }
        let child = ref.kind == "image-move" ? "its move \(ref.id)" : "its \(image?.effects?.first { $0.id == ref.id }?.kind ?? "") effect \(ref.id)"
        guard !short, let image else { return child }
        return "\(image.kind) \(image.id) (\(stamp(image.start))–\(stamp(image.end))): \(child)"
    default:
        guard !short, let s = e.segments.first(where: { $0.id == ref.id }) else { return "\(ref.kind) \(ref.id)" }
        return "\(s.kind) \(s.id) (\(stamp(s.start))–\(stamp(s.end)))"
    }
}

// @ref LLP 0005#refusals — the same two lines as the app, with the rule's id and the items' ids
func report(_ c: Conflict, _ e: Edits, map: TimeMap) -> String {
    let with = c.other.map { ", with \(describe($0, e, map: map, short: true))" } ?? ""
    return "\(c.item.map { describe($0, e, map: map) } ?? "edit")\(with): \(c.rule): \(c.line1)\n  \(c.line2)"
}

struct Problem { var text: String; var key: String? }

func problems(_ r: Recording) -> [String] { findings(r).map(\.text) }

/// Problems with a recording's edits, each a line (a broken rule, two); empty when it is fine.
func findings(_ r: Recording) -> [Problem] {
    var out = r.unreadable.map { Problem(text: $0, key: nil) }
    func say(_ text: String) { out.append(Problem(text: text, key: nil)) }
    let folder = r.folder
    let d = r.meta.duration, e = r.edits
    let map = TimeMap(duration: d, edits: e)
    let broken = e.conflicts(map: map)
    func rules(_ ref: ItemRef) {
        for c in broken where c.item == ref || ((ref.kind == "image" || ref.kind == "text") && c.item?.image == ref.id) { out.append(Problem(text: report(c, e, map: map), key: c.key)) }
    }
    // Opening a file raises each lane count to fit, so the counts are checked as the file declares them.
    // A missing count is derived, as is `lanes` in an old file without `textLanes`: its lanes are renumbered.
    let raw = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("edits.json")))) as? [String: Any]) ?? [:]
    func count(_ key: String, _ fitted: Int) -> Int { key == "lanes" && raw["textLanes"] == nil ? fitted : (raw[key] as? Int) ?? fitted }
    for s in e.segments {
        let at = "\(s.kind) \(s.id) (\(stamp(s.start))–\(stamp(s.end)))"
        if !Segment.kinds.contains(s.kind) { say("\(at): unknown kind; one of \(Segment.kinds.joined(separator: ", "))") }
        if s.end - s.start < 0.1 { say(report(Rules.minLength(.of(s), duration: d), e, map: map)) }
        if s.start < 0 || s.end > d + 0.01 { say("\(at): outside the recording, 0:00–\(stamp(d))") }
        if case let key = ["lanes", "textLanes", "imageLanes", "frameLanes"][s.space], s.lane < 0 || s.lane >= count(key, e.laneCount(space: s.space)) {
            say("\(at): lane \(s.lane), but \(key) is \(count(key, e.laneCount(space: s.space)))")
        }
        if s.id.contains(":") { say("\(at): an id can't contain a colon") }
        if e.segments.filter({ $0.id == s.id }).count > 1 { say("\(at): another segment has the same id") }
        rules(.of(s))
        if s.kind == "zoom", (s.level ?? 0) <= 0 { say("\(at): a zoom needs a level above 0 (below 1 zooms out)") }
        if s.kind == "speed", (s.rate ?? 0) <= 0 { say("\(at): a speed change needs a rate above 0") }
        if s.kind == "text", (s.text ?? "").isEmpty { say("\(at): a text needs its words") }
        // @ref LLP 0003#templates
        if s.isPlaceholder { say("\(at): unfilled “\(s.text ?? "")”; write the line or delete the text") }
        if s.kind == "image" {
            if (s.file ?? "").isEmpty { say("\(at): an image needs its file, a path inside the recording's folder") }
            else if Pictures.image(s.file, in: folder) == nil { say("\(at): \(s.file!) is not a picture in \(folder.lastPathComponent)/ (\(Pictures.types.joined(separator: ", ")))") }
            if (s.size ?? 0.25) <= 0 { say("\(at): an image's size must be above 0") }
        } else if s.kind == "text", s.moves != nil {
            say("\(at): only an image has moves of its own")
        } else if !s.isOverlay, s.moves != nil || s.effects != nil {
            say("\(at): only an image has moves and effects of its own")
        }
        if s.isOverlay {
            for fx in s.effects ?? [] where fx.end - fx.start < 0.1 { say("\(at): its \(fx.kind) effect \(fx.id) is shorter than 0.1 s, or ends before it starts") }
            for m in s.moves ?? [] where m.to.scale <= 0 { say("\(at): its move \(m.id) needs a scale above 0 (1 keeps the image's size)") }
            let ids = (s.effects ?? []).map(\.id) + (s.moves ?? []).map(\.id)
            if Set(ids).count != ids.count { say("\(at): two of its moves or effects share an id") }
        }
        // @ref LLP 0002#where-an-effect-applies
        if let scope = s.scope {
            if s.kind != "blur" && s.kind != "mono" { say("\(at): only a blur or a black and white (mono) has a scope") }
            else if !Segment.scopes.contains(scope) { say("\(at): no scope \(scope); one of \(Segment.scopes.joined(separator: ", "))") }
        }
        // @ref LLP 0002#depth
        if let layer = s.layer {
            if !s.isOverlay { out.append("\(at): only a text or an image has a layer") }
            else if !Segment.layers.contains(layer) { out.append("\(at): no layer \(layer); one of \(Segment.layers.joined(separator: ", "))") }
        }
        if s.order != nil, !s.isOverlay { out.append("\(at): only a text or an image has an order") }
        if s.kind == "mask" {
            maskProblems(s).forEach { say("\(at): \($0)") }
        } else if s.rect != nil {
            say("\(at): only a mask has a rect")
        }
    }
    for s in e.sounds {
        let at = "sound \(s.id) (\(stamp(s.start)), \(s.length)s of \(s.file))"
        if s.id.isEmpty || s.id.contains(":") { say("\(at): an id must be non-empty and can't contain a colon") }
        if e.sounds.filter({ $0.id == s.id }).count > 1 { say("\(at): another sound has the same id") }
        if let whole = Sounds.length(s.file, in: folder) {
            if s.offset + s.length > whole + 0.01 { say("\(at): offset + length is \(s.offset + s.length)s, but the file holds \(String(format: "%.3f", whole))s") }
        } else {
            say("\(at): \(s.file) is not a readable sound file in \(folder.lastPathComponent)/ (\(Sounds.types.joined(separator: ", ")))")
        }
        if s.length <= 0 { say("\(at): length must be above 0") }
        if s.offset < 0 { say("\(at): offset can't be below 0") }
        if s.start < 0 || s.start >= d { say("\(at): starts outside the recording, 0:00–\(stamp(d))") }
        if s.lane < 0 || s.lane >= count("soundLanes", e.soundLanes) { say("\(at): lane \(s.lane), but soundLanes is \(count("soundLanes", e.soundLanes))") }
        if !(0...1).contains(s.volume) { say("\(at): volume must be 0–1") }
        if s.fadeIn < 0 || s.fadeOut < 0 { say("\(at): fades can't be below 0") }
        rules(.sound(s))
    }
    for m in e.moves.sorted(by: { $0.t < $1.t }) {
        if m.t < 0 || m.t > d + 0.01 { say("move \(m.id) at \(stamp(m.t)): outside the recording") }
        rules(.move(m))
    }
    for s in e.splits where s <= 0 || s >= d { say("split at \(stamp(s)): outside the recording") }
    for r in e.removed where !([0] + e.splits).contains(where: { Edits.same($0, r) }) { say("removed \(stamp(r)): not the start of a clip part (0 or a split)") }
    let ends = e.pieces(d).map { Edits.key($0.end) }
    for k in e.transitions.keys where !ends.contains(k) { say("transition at \(k) ms: not the end of a clip part") }
    if e.pieces(d).allSatisfy(\.removed) { say(report(Rules.keepAPart, e, map: map)) }
    // @ref LLP 0002#split
    e.looseJoins(map: map).forEach(say)
    return out
}



// MARK: Recording, through the app

// @ref LLP 0007#the-channel — the CLI asks the running app, which records; it never records by itself
let appID = "com.entiendonull.exactstudio"

/// Asks the app and returns its reply. Opens the app first when `launch` and it is not running.
func ask(_ request: [String: Any], timeout: Double, launch: Bool) -> [String: Any] {
    let root = Control.folder
    do { try Control.prepare(root) } catch { fail("The control folder is not safe to use: \(error)", code: 4) }
    if Control.runningApp(root) == nil {
        let env = ProcessInfo.processInfo.environment
        // An app opened by Launch Services serves the default folder, never an EXACT_STUDIO_CONTROL one.
        guard launch, env["EXACT_STUDIO_NO_LAUNCH"] != "1", (env["EXACT_STUDIO_CONTROL"] ?? "").isEmpty else {
            fail(launch ? "Exact Studio is not running (nothing answers in \(root.path)), and it is not opened here. Open it first."
                        : "Exact Studio is not running, so nothing is recording.", code: launch ? 4 : 1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // EXACT_STUDIO_APP names one build; else Launch Services picks the app by its id.
        let app = ProcessInfo.processInfo.environment["EXACT_STUDIO_APP"] ?? ""
        p.arguments = app.isEmpty ? ["-g", "-b", appID] : ["-g", "-a", app]
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch {}
        guard p.terminationStatus == 0 else { fail("Exact Studio is not installed. Build and open it once with `bun exact.mjs mac --run`.", code: 4) }
        FileHandle.standardError.write("opening Exact Studio…\n".data(using: .utf8)!)
        let until = Date().addingTimeInterval(30)
        while Control.runningApp(root) == nil {
            guard Date() < until else {
                fail("Exact Studio was opened but did not answer within 30 s. A build from before agent recording may be running: quit it and open a new build.", code: 4)
            }
            usleep(100_000)
        }
    }
    let id = UUID().uuidString
    let file = Control.requests(root).appendingPathComponent("\(id).json")
    let answer = Control.replies(root).appendingPathComponent("\(id).json")
    var body = request
    body["expires"] = Date().timeIntervalSince1970 + timeout
    do { try Control.put(body, file) } catch { fail("\(error)", code: 4) }
    let until = Date().addingTimeInterval(timeout)
    while Date() < until {
        if let reply = Control.read(answer) {
            unlink(answer.path)
            return reply
        }
        usleep(50_000)
    }
    // Taken back, so a late app never acts on it; the request also carries its expiry.
    let untouched = unlink(file.path) == 0
    fail(untouched ? "Exact Studio did not take the request within \(Int(timeout)) s. Is it busy or stuck?"
                   : "Exact Studio took the request but did not answer within \(Int(timeout)) s. Run `exact-studio record status`.", code: 4)
}

/// Fails with the app's refusal: exit 3 when a person must act, else 1.
func refused(_ reply: [String: Any]) -> Never {
    fail(reply["error"] as? String ?? "Exact Studio refused.", code: reply["code"] as? String == "permission" ? 3 : 1)
}

let permissionText = "Screen Recording is not allowed for Exact Studio. A person must allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Exact Studio."

/// The app's list of sources. `forStart`: no permission is a refusal (exit 3), not a warning,
/// since without it window names are missing and nothing can be recorded anyway.
func sourceList(launch: Bool, forStart: Bool = false) -> [SourceEntry] {
    let reply = ask(["op": "sources"], timeout: 15, launch: launch)
    guard reply["ok"] as? Bool == true else { refused(reply) }
    if reply["allowed"] as? Bool == false {
        if forStart { fail(permissionText, code: 3) }
        FileHandle.standardError.write("\(permissionText) Until then, window names may be missing.\n".data(using: .utf8)!)
    }
    return SourceEntry.named(((reply["items"] as? [[String: Any]]) ?? []).compactMap(SourceEntry.init))
}

/// The last recording that ended, as one or two lines; "" when none has this session.
func lastLines(_ reply: [String: Any]) -> String {
    guard let l = reply["last"] as? [String: Any], let id = l["id"] as? String, !id.isEmpty else { return "" }
    let by = ["menu": "from the menu bar", "app": "in the app", "agent": "by an agent", "max": "by itself at its --max limit"][l["stoppedBy"] as? String ?? ""] ?? ""
    return "last recording: \(id)  \((l["name"] as? String) ?? "") (\((l["kind"] as? String) ?? "")), \(String(format: "%.1f", (l["duration"] as? NSNumber)?.doubleValue ?? 0)) s, stopped \(by)\nfolder \((l["folder"] as? String) ?? "")"
}

func recordingLines(_ s: [String: Any]) -> String {
    let max = (s["max"] as? NSNumber)?.doubleValue ?? 0
    return "recording \((s["name"] as? String) ?? "") (\((s["kind"] as? String) ?? "")) for \(String(format: "%.1f", (s["elapsed"] as? NSNumber)?.doubleValue ?? 0)) s, started \(s["by"] as? String == "agent" ? "by an agent" : "in the app")"
        + (max > 0 ? ", stops by itself at \(Int(max)) s" : "") + "\nid \((s["id"] as? String) ?? "")  folder \((s["folder"] as? String) ?? "")"
}

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "list":
    let list = all()
    if list.isEmpty { print("no recordings in \(library.path)") }
    for (id, m) in list { print("\(id)  \(m.kind.padding(toLength: 9, withPad: " ", startingAt: 0))  \(stamp(m.duration))  \(m.name)") }

case "show":
    guard let ref = args.first else { fail(usage) }
    let json = flag("--json")
    let r = open(ref, readable: !json)
    if json, !r.unreadable.isEmpty {
        let out: [String: Any] = ["id": r.id, "name": r.meta.name, "kind": r.meta.kind, "folder": r.folder.path, "unreadable": r.unreadable]
        print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
        exit(1)
    }
    let map = TimeMap(duration: r.meta.duration, edits: r.edits)
    if json {
        let pieces = r.edits.pieces(r.meta.duration).map { ["start": $0.start, "end": $0.end, "removed": $0.removed] as [String: Any] }
        let out: [String: Any] = ["id": r.id, "name": r.meta.name, "kind": r.meta.kind, "recorded": r.meta.duration, "length": map.outputDuration,
                                  "folder": r.folder.path, "clicks": r.meta.clicks.map(\.t), "parts": pieces]
        print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
        break
    }
    print("\(r.meta.name)  (\(r.meta.kind), \(r.id))")
    print("recorded \(stamp(r.meta.duration)), plays as \(stamp(map.outputDuration)); \(r.meta.clicks.count) clicks; folder \(r.folder.path)")
    print("look: \(r.look.background) background, \(r.look.aspect), padding \(Int(r.look.padding))%, 3D \(r.edits.three.on ? "on" : "off")")
    print("clip parts:")
    for p in r.edits.pieces(r.meta.duration) {
        let t = r.edits.transitions[Edits.key(p.end)].map { " → \($0)" } ?? ""
        print("  \(stamp(p.start))–\(stamp(p.end))\(p.removed ? "  removed" : "")\(t)")
    }
    print("segments (row: kind, recording time; e is an effect lane, t a text lane, i an image lane (0 in front), f a whole-frame lane):")
    for s in r.edits.segments.sorted(by: { ($0.space, $0.lane, $0.start) < ($1.space, $1.lane, $1.start) }) {
        var what = s.kind
        switch s.kind {
        case "zoom": what += " \(s.level ?? 2)×"
        case "speed": what += " \(s.rate ?? 1)×"
        case "text": what += " “\(s.text ?? "")” \(s.style ?? "plain") in:\(s.animIn ?? "") out:\(s.animOut ?? "")\(s.isPlaceholder ? "  UNFILLED" : "")"
        case "image": what += " \(s.file ?? "") at x \(s.x ?? 0.5) y \(s.y ?? 0.5) size \(s.size ?? 0.25) in:\(s.animIn ?? "fade") out:\(s.animOut ?? "fade")"
        case "3d": what += " \(s.style ?? "hold") tilt \(s.tilt ?? 0) turn \(s.turn ?? 0)"
        case "mask":
            let u = s.rect
            what += " \(s.style ?? "blur")\(s.style == "solid" ? " \(s.color ?? "black")" : "") rect x \(u?.x ?? 0) y \(u?.y ?? 0) w \(u?.w ?? 0) h \(u?.h ?? 0) (full frame)"
            // A mask the crop leaves out hides nothing; say so, and say when only part of it shows.
            if let u {
                let c = r.meta.crop
                let ix = min(u.x + u.w, c.x + c.w) - max(u.x, c.x), iy = min(u.y + u.h, c.y + c.h) - max(u.y, c.y)
                if ix <= 0 || iy <= 0 { what += " — outside the crop: hides nothing now" }
                else if ix < u.w - 0.0001 || iy < u.h - 0.0001 { what += " — partly outside the crop" }
            }
        default: if s.coversFrame { what += " (\(Segment.reach(s.scope)))" }
        }
        if s.isOverlay, s.isBehind { what += "  behind the video" }
        if s.isOverlay, let n = s.order { what += "  order \(n)" }
        print("  \(["e", "t", "i", "f"][s.space])\(s.lane): \(stamp(s.start))–\(stamp(s.end))  \(what)  [\(s.id)]\(joins(s, r.edits.segments))")
        // An image's own moves and effects, or a text's own effects, under it.
        for m in (s.moves ?? []).sorted(by: { $0.t < $1.t }) {
            print("        move lands \(stamp(m.t)) after \(m.duration)s \(m.style): x \(m.to.x) y \(m.to.y) scale \(m.to.scale)  [\(m.id)]")
        }
        for fx in (s.effects ?? []).sorted(by: { $0.start < $1.start }) {
            let pool = Joins.whole(s, run: Joins.run(s, in: r.edits.segments)).effects ?? []
            print("        effect \(fx.kind)\(fx.kind == "fade" ? " to \(fx.level ?? 0.3)" : "") \(stamp(fx.start))–\(stamp(fx.end))  [\(fx.id)]\(joins(fx, pool))")
        }
    }
    if !r.edits.sounds.isEmpty { print("sounds (added over the video; each plays straight through from its start, not cut by the cuts):") }
    for s in r.edits.sounds.sorted(by: { ($0.lane, $0.start) < ($1.lane, $1.start) }) {
        let (a, b) = s.playing(map)
        let before = r.edits.sounds.first { $0.joins(s, map: map) }, after = r.edits.sounds.first { s.joins($0, map: map) }
        print("  s\(s.lane): from \(stamp(s.start)) for \(s.length)s (video \(stamp(a))–\(stamp(b)))  \(s.file) from \(s.offset)s  volume \(s.volume) fade in \(s.fadeIn)s out \(s.fadeOut)s  [\(s.id)]\(joinWords(before?.id, after?.id))")
    }
    if !r.edits.moves.isEmpty { print("moves:") }
    for m in r.edits.moves.sorted(by: { $0.t < $1.t }) {
        let a = m.angles.map { "  3D tilt \($0.tilt) turn \($0.turn) roll \($0.roll)" } ?? ""
        print("  lands \(stamp(m.t)) after \(m.duration)s \(m.style): x \(m.to.x) y \(m.to.y) scale \(m.to.scale)\(a)  [\(m.id)]")
    }

case "validate":
    let since = option("--since")
    guard let ref = args.first else { fail(usage) }
    let r = open(ref, readable: false)
    // @ref LLP 0005#refusals — a rule the file broke before this change is reported, never refused
    var before = Set<String>()
    if let since, let old = try? decode(Edits.self, URL(fileURLWithPath: since)) {
        before = Set(old.conflicts(map: TimeMap(duration: r.meta.duration, edits: old)).map(\.key))
    }
    let found = findings(r)
    let standing = found.filter { $0.key.map(before.contains) ?? false }, fresh = found.filter { !($0.key.map(before.contains) ?? false) }
    if fresh.isEmpty { print("ok") } else { fresh.forEach { print($0.text) } }
    standing.forEach { print("note: before this change: \($0.text)") }
    if !fresh.isEmpty { exit(1) }

case "frame":
    guard args.count >= 2, let at = Double(args[1]) else { fail(usage) }
    let source = flag("--source"), raw = flag("--raw")
    let out = URL(fileURLWithPath: option("--out") ?? ".exact/frame.png")
    let r = open(args[0])
    let (mix, comp, map, _) = composition(r)
    let t = source ? map.output(at) : min(max(at, 0), map.outputDuration - 0.02)
    if raw {
        // The full frame as captured at that moment, before the crop: the picture a mask's rect measures.
        // @ref LLP 0006#follows-the-video — a mask's coordinates are the full recorded frame's, not the crop's or the canvas's
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: r.folder.appendingPathComponent("capture.mov")))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let src = source ? min(max(at, 0), r.meta.duration) : map.source(t)
        final class Got: @unchecked Sendable { var image: CGImage?; var error: Error? }
        let got = Got(), done = DispatchSemaphore(value: 0)
        gen.generateCGImageAsynchronously(for: CMTime(seconds: src, preferredTimescale: 600)) { image, _, error in
            got.image = image; got.error = error; done.signal()
        }
        done.wait()
        do {
            guard let whole = got.image else { throw got.error ?? CocoaError(.fileReadUnknown) }
            let img = whole, c = r.meta.crop
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: out)
            func px(_ v: Double, _ n: Int) -> Int { Int((v * Double(n)).rounded()) }
            print("\(out.path)  \(img.width)×\(img.height)  the full recorded frame at \(stamp(src)) (video \(stamp(map.output(src)))), before the crop, no edits")
            print("a pixel at (px, py) is x = px/\(img.width), y = py/\(img.height) in a mask's rect; w and h likewise")
            print("the crop (what the video shows) is pixels x \(px(c.x, img.width))–\(px(c.x + c.w, img.width)), y \(px(c.y, img.height))–\(px(c.y + c.h, img.height)): rect x \(c.x) y \(c.y) w \(c.w) h \(c.h)")
        } catch { fail("couldn't read the frame: \(error)") }
        break
    }
    let gen = AVAssetImageGenerator(asset: mix)
    gen.videoComposition = comp
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    do {
        let img = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: out)
        print("\(out.path)  \(img.width)×\(img.height)  video \(stamp(t)) = recording \(stamp(map.source(t)))")
    } catch { fail("couldn't render the frame: \(error)") }

case "strip":
    let source = flag("--source")
    let count = Int(option("--frames") ?? "5") ?? 0
    let width = Int(option("--width") ?? "960") ?? 0
    let out = URL(fileURLWithPath: option("--out") ?? ".exact/strip.png")
    guard args.count >= 3, let a = Double(args[1]), let b = Double(args[2]), b > a else { fail(usage) }
    guard (2...12).contains(count) else { fail("--frames is 2–12") }
    guard (count * 32...4000).contains(width) else { fail("--width is \(count * 32)–4000 pixels") }
    let r = open(args[0])
    let (mix, comp, map, _) = composition(r)
    let gen = AVAssetImageGenerator(asset: mix)
    gen.videoComposition = comp
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let canvas = comp.renderSize
    let gap = 6, cellW = (width - gap * (count - 1)) / count, cellH = max(1, Int((Double(cellW) * canvas.height / canvas.width).rounded()))
    let total = cellW * count + gap * (count - 1)
    guard let ctx = CGContext(data: nil, width: total, height: cellH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("couldn't make the strip") }
    ctx.interpolationQuality = .high
    var times: [String] = []
    for i in 0..<count {
        let u = a + (b - a) * Double(i) / Double(count - 1)
        let t = min(max(source ? map.output(u) : u, 0), map.outputDuration - 0.02)
        do {
            let img = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
            ctx.draw(img, in: CGRect(x: i * (cellW + gap), y: 0, width: cellW, height: cellH))
        } catch { fail("couldn't render the frame at \(stamp(t)): \(error)") }
        times.append(source ? stamp(map.source(t)) : stamp(t))
    }
    do {
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
    } catch { fail("couldn't write \(out.path): \(error)") }
    print("\(out.path)  \(total)×\(cellH)  \(count) frames, left to right, at \(source ? "recording" : "video") \(times.joined(separator: ", "))")

case "export":
    guard let ref = args.first else { fail(usage) }
    let r = open(ref)
    if case let found = problems(r), !found.isEmpty { found.forEach { print($0) }; fail("fix these first (exact-studio validate \(r.id))", code: 1) }
    let safe = r.meta.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let out = URL(fileURLWithPath: option("--out") ?? library.deletingLastPathComponent().appendingPathComponent("\(safe) \(r.id).mp4").path)
    try? FileManager.default.removeItem(at: out)
    let (mix, comp, map, sounds) = composition(r)
    let quality = option("--quality") ?? "best"
    guard ExportQuality.names.contains(quality) else { fail("no quality \(quality); one of \(ExportQuality.names.joined(separator: ", "))") }
    guard let session = ExportQuality.session(mix, comp, audio: Composition.audioMix(mix, map: map, edits: r.edits, sounds: sounds), quality: quality, to: out) else { fail("this Mac can't export that") }
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    let start = Date()
    while done.wait(timeout: .now() + 2) == .timedOut {
        FileHandle.standardError.write(String(format: "\rexporting %3.0f%%", session.progress * 100).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\r".data(using: .utf8)!)
    guard session.status == .completed else { fail("the export stopped: \(session.error.map { "\($0)" } ?? "unknown")", code: 1) }
    print("\(out.path)  \(Int(comp.renderSize.width))×\(Int(comp.renderSize.height))  \(stamp(map.outputDuration))  in \(Int(Date().timeIntervalSince(start)))s")

case "template":
    if flag("--list") {
        for t in Templates.all {
            print("\(t.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(t.title): \(t.line)\(t.placeholders ? " (lines to fill)" : "")")
        }
        break
    }
    guard args.count >= 2 else { fail(usage) }
    var r = open(args[0])
    guard let info = Templates.info(args[1]) else { fail("no template \(args[1]); one of \(Templates.names.joined(separator: ", "))") }
    let map = TimeMap(duration: r.meta.duration, edits: r.edits)
    guard let made = Templates.make(info.name, map: map, meta: r.meta, look: r.look, keep: Templates.kept(r.edits)) else {
        fail("\(Templates.refusal(info, duration: map.outputDuration)) This one plays \(stamp(map.outputDuration)).", code: 1)
    }
    r.edits = Templates.apply(made, to: r.edits)
    write(r.edits, r.folder.appendingPathComponent("edits.json"))
    print("\(info.title) applied to \(r.id): \(r.edits.segments.count) segments, \(made.moves.count) moves (edits.json)")
    for s in r.edits.texts.filter(\.isPlaceholder).sorted(by: { $0.start < $1.start }) {
        print("  to fill: text \(s.id) “\(s.text ?? "")” \(stamp(s.start))–\(stamp(s.end))")
    }

case "image":
    let at = option("--at").flatMap(Double.init) ?? 0, length = option("--for").flatMap(Double.init) ?? 4
    guard args.count >= 2 else { fail(usage) }
    var r = open(args[0])
    let d = r.meta.duration
    guard at >= 0, at < d - 0.1, length >= 0.1 else { fail("--at must be inside the recording, 0–\(stamp(d)), and --for at least 0.1") }
    do {
        let file = try Pictures.bring(URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath), into: r.folder)
        var n = r.edits.images.count + 1
        while r.edits.segments.contains(where: { $0.id == "image\(n)" }) { n += 1 }
        let canvas = Framing(meta: r.meta, look: r.look, edits: r.edits, cursor: [], folder: r.folder).canvas
        var s = Pictures.segment(id: "image\(n)", file: file, in: r.folder, canvas: canvas, start: at, end: min(d, at + length))
        // On the first image lane free at that time, else a new one.
        s.lane = r.edits.freeLane(for: s)
        r.edits.segments.append(s)
        r.edits.fitLanes()
        write(r.edits, r.folder.appendingPathComponent("edits.json"))
        let made = r.edits.segments.first { $0.id == s.id }!
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print("added to \(r.id) (edits.json), picture copied to \(file):")
        print(String(data: try e.encode(made), encoding: .utf8)!)
    } catch let refused as Pictures.Refused { fail(refused.why) } catch { fail("\(error)") }

case "sound":
    let at = option("--at").flatMap(Double.init) ?? 0, length = option("--for").flatMap(Double.init)
    guard args.count >= 2 else { fail(usage) }
    var r = open(args[0])
    let d = r.meta.duration
    guard at >= 0, at < d - 0.1, (length ?? 1) >= 0.1 else { fail("--at must be inside the recording, 0–\(stamp(d)), and --for at least 0.1") }
    do {
        let file = try Sounds.bring(URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath), into: r.folder)
        var n = r.edits.sounds.count + 1
        while r.edits.sounds.contains(where: { $0.id == "sound\(n)" }) { n += 1 }
        let map = TimeMap(duration: d, edits: r.edits)
        guard var s = Sounds.make(id: "sound\(n)", file: file, in: r.folder, start: at, map: map) else { fail("no room for a sound at \(at)s: the video ends there") }
        if let length { s.length = min(s.length, length); s.fadeOut = s.length > 2 ? 0.5 : 0 }
        s.lane = r.edits.freeLane(for: s, map: map)
        r.edits.sounds.append(s)
        r.edits.fitLanes()
        write(r.edits, r.folder.appendingPathComponent("edits.json"))
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print("added to \(r.id) (edits.json), sound copied to \(file):")
        print(String(data: try e.encode(s), encoding: .utf8)!)
    } catch let refused as Sounds.Refused { fail(refused.why) } catch { fail("\(error)") }

case "mask":
    let at = option("--at").flatMap(Double.init) ?? 0, length = option("--for").flatMap(Double.init) ?? 4
    let style = option("--style"), color = option("--color"), rectText = option("--rect")
    guard let ref = args.first else { fail(usage) }
    var r = open(ref)
    let d = r.meta.duration
    guard at >= 0, at < d - 0.1, length >= 0.1 else { fail("--at must be inside the recording, 0–\(stamp(d)), and --for at least 0.1") }
    let parts = (rectText ?? "").split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else {
        fail("--rect x,y,w,h is needed: 0–1 of the full recorded frame (before the crop), origin top-left (frame <id> <t> --raw shows that picture)")
    }
    var n = r.edits.masks.count + 1
    while r.edits.segments.contains(where: { $0.id == "mask\(n)" }) { n += 1 }
    var s = Segment(id: "mask\(n)", kind: "mask", start: at, end: min(d, at + length))
    s.rect = UnitRect(x: parts[0]!, y: parts[1]!, w: parts[2]!, h: parts[3]!)
    s.style = style ?? "blur"
    if s.style == "solid" { s.color = color ?? "#000000" } else if let color { s.color = color }
    if case let found = maskProblems(s), !found.isEmpty { fail(found.joined(separator: "\n")) }
    // On the first effect lane free at that time, else a new one.
    s.lane = r.edits.freeLane(for: s)
    r.edits.segments.append(s)
    r.edits.fitLanes()
    write(r.edits, r.folder.appendingPathComponent("edits.json"))
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print("added to \(r.id) (edits.json):")
    print(String(data: try! e.encode(s), encoding: .utf8)!)

case "sources":
    let list = sourceList(launch: !flag("--no-launch"))
    if list.isEmpty { print("nothing to record now") }
    for e in list { print(e.line) }

case "record":
    let verb = args.first ?? ""
    args = Array(args.dropFirst())
    switch verb {
    case "start":
        let soundText = option("--sound"), maxText = option("--max")
        guard soundText == nil || ["on", "off"].contains(soundText!) else { fail("--sound is on or off") }
        let limit = maxText.flatMap(Double.init)
        guard maxText == nil || (limit != nil && limit! > 0) else { fail("--max is a number of seconds above 0") }
        let launch = !flag("--no-launch")
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { fail("record start needs a source. `exact-studio sources` lists them; `exact-studio` alone prints the help.") }
        var request: [String: Any] = ["op": "start"]
        if let soundText { request["sound"] = soundText }
        if let limit { request["max"] = limit }
        let ref: String
        switch SourceMatch.pick(query, in: sourceList(launch: launch, forStart: true)) {
        case let .problem(why): fail(why, code: 1)
        case let .source(e): request["source"] = e.id; ref = e.ref
        case let .area(d, x, y, w, h): request["source"] = d.id; request["area"] = [x, y, w, h]; ref = "area:\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h)) of \(d.ref)"
        }
        let reply = ask(request, timeout: 30, launch: false)
        guard reply["ok"] as? Bool == true else { refused(reply) }
        print("started \(ref)")
        print(recordingLines(reply))
        print("Everything on that source is recorded. Stop with: exact-studio record stop")
    case "status":
        guard Control.runningApp(Control.folder) != nil else { print("not recording (Exact Studio is not running)"); break }
        let reply = ask(["op": "status"], timeout: 10, launch: false)
        guard reply["ok"] as? Bool == true else { refused(reply) }
        if reply["recording"] as? Bool == true { print(recordingLines(reply)) }
        else { print(reply["starting"] as? Bool == true ? "starting a recording" : "not recording") }
        if case let l = lastLines(reply), !l.isEmpty { print(l) }
    case "stop":
        let any = flag("--any")
        let reply = ask(["op": "stop", "any": any], timeout: 60, launch: false)
        guard reply["ok"] as? Bool == true, let l = reply["last"] as? [String: Any], let id = l["id"] as? String, !id.isEmpty else { refused(reply) }
        print("stopped \(id)  \((l["name"] as? String) ?? "") (\((l["kind"] as? String) ?? "")), \(String(format: "%.1f", (l["duration"] as? NSNumber)?.doubleValue ?? 0)) s")
        print("folder \((l["folder"] as? String) ?? "")")
        let folder = URL(fileURLWithPath: (l["folder"] as? String) ?? "")
        if folder.deletingLastPathComponent().standardizedFileURL.path != library.standardizedFileURL.path {
            print("note: it is in \(folder.deletingLastPathComponent().path), not in \(library.path); pass --library \(folder.deletingLastPathComponent().path)")
        }
        print("next: exact-studio show \(id), then validate, frame, edit and export it as usual")
    default:
        fail("record takes start, status or stop. `exact-studio` alone prints the help.")
    }

case "split":
    let every = flag("--all")
    guard args.count >= 2, let t = Double(args[1]) else { fail(usage) }
    var r = open(args[0])
    let d = r.meta.duration, map = TimeMap(duration: d, edits: r.edits)
    do {
        if every {
            let cut = try r.edits.splitAll(at: t, duration: d, map: map)
            write(r.edits, r.folder.appendingPathComponent("edits.json"))
            print("split all lanes of \(r.id) at \(stamp(t)) (edits.json):")
            cut.forEach { print("  \($0)") }
        } else if args.count < 3 {
            try r.edits.splitClip(at: t, duration: d)
            write(r.edits, r.folder.appendingPathComponent("edits.json"))
            print("split the clip of \(r.id) at \(stamp(t)) (edits.json)")
        } else {
            let item = args[2], parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            let made: String
            if parts.count == 2 { made = parts[0] + ":" + (try r.edits.splitImageEffect(image: parts[0], effect: parts[1], at: t)) }
            else if r.edits.segments.contains(where: { $0.id == item }) { made = try r.edits.splitSegment(item, at: t) }
            else if r.edits.sounds.contains(where: { $0.id == item }) { made = try r.edits.splitSound(item, at: t, map: map) }
            else { fail("no segment, sound or image effect \(item) in \(r.id)", code: 1) }
            write(r.edits, r.folder.appendingPathComponent("edits.json"))
            print("split \(item) of \(r.id) at \(stamp(t)) (edits.json): \(item) → \(made), joined")
        }
    } catch let refused as SplitRefused { fail(refused.why, code: 1) } catch { fail("\(error)") }

case "schema":
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    print("docs/edits.md, schema/edits.schema.json and schema/look.schema.json in the exact-studio repository (\(root.path))")
    print("docs/effects.md: what each effect, move, text animation, style and transition looks like, its timing and limits")

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n" + usage)
}
