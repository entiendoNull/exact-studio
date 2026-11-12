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
  exact-studio show <id> [--json]           its length, clip parts, segments, moves and look
  exact-studio validate <id>                checks edits.json and look.json; exit 1 on a problem
  exact-studio frame <id> <time> [--out f.png] [--source]
                                            renders one frame at <time> seconds of the video
                                            (--source: of the recording); default .exact/frame.png
  exact-studio export <id> [--out f.mp4] [--quality best|1080p|720p|small]
                                            renders the video; default ~/Movies/Exact Studio/<name>.mp4
  exact-studio template <id> <name>         replaces texts, effects and moves with a template:
                                            launch, hero, tour, teaser (laid out for look.json's aspect)
  exact-studio schema                       prints where the docs and JSON Schemas are

  <id> is a recording folder's name, a unique start of one, or "latest".
  --library <dir> (or EXACT_STUDIO_LIBRARY) names the Recordings folder;
  the default is ~/Movies/Exact Studio/Recordings.
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
}

func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func all() -> [(String, RecordingMeta)] {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
    return ids.compactMap { id in (try? decode(RecordingMeta.self, library.appendingPathComponent(id).appendingPathComponent("meta.json"))).map { (id, $0) } }
        .sorted { $0.1.created > $1.1.created }
}

func open(_ ref: String) -> Recording {
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
    let edits = (try? decode(Edits.self, folder.appendingPathComponent("edits.json"))) ?? Edits()
    let look = (try? decode(Look.self, folder.appendingPathComponent("look.json"))) ?? Look()
    let cursor = (try? decode([Point].self, folder.appendingPathComponent("cursor.json"))) ?? []
    return Recording(id: id, folder: folder, meta: meta, edits: edits, look: look, cursor: cursor)
}

func write<T: Encodable>(_ value: T, _ url: URL) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try e.encode(value).write(to: url) } catch { fail("couldn't write \(url.path): \(error)") }
}

func composition(_ r: Recording) -> (AVAsset, AVMutableVideoComposition, TimeMap) {
    let asset = AVURLAsset(url: r.folder.appendingPathComponent("capture.mov"))
    let state = RenderState(Framing(meta: r.meta, look: r.look, edits: r.edits, cursor: r.cursor, folder: r.folder))
    do { return try Composition.make(asset: asset, meta: r.meta, edits: r.edits, state: state) } catch { fail("\(error)") }
}

func stamp(_ s: Double) -> String { String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

/// Problems with a recording's edits, each a line; empty when it is fine.
func problems(_ r: Recording) -> [String] {
    var out: [String] = []
    let folder = r.folder
    for name in ["edits.json", "look.json"] {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
            if name == "edits.json" { _ = try decode(Edits.self, url) } else { _ = try decode(Look.self, url) }
        } catch let DecodingError.typeMismatch(_, c), let DecodingError.valueNotFound(_, c) {
            out.append("\(name): \(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)")
        } catch let DecodingError.keyNotFound(k, c) {
            out.append("\(name): \(c.codingPath.map(\.stringValue).joined(separator: ".")): missing \(k.stringValue)")
        } catch {
            out.append("\(name): \(error)")
        }
    }
    let d = r.meta.duration, e = r.edits
    for s in e.segments {
        let at = "\(s.kind) \(s.id) (\(stamp(s.start))–\(stamp(s.end)))"
        if !Segment.kinds.contains(s.kind) { out.append("\(at): unknown kind; one of \(Segment.kinds.joined(separator: ", "))") }
        if s.end - s.start < 0.1 { out.append("\(at): shorter than 0.1 s, or ends before it starts") }
        if s.start < 0 || s.end > d + 0.01 { out.append("\(at): outside the recording, 0:00–\(stamp(d))") }
        if s.lane < 0 || s.lane >= e.lanes { out.append("\(at): lane \(s.lane), but lanes is \(e.lanes)") }
        if let why = e.conflict(s) { out.append("\(at): \(why)") }
        if s.kind == "zoom", (s.level ?? 0) <= 0 { out.append("\(at): a zoom needs a level above 0 (below 1 zooms out)") }
        if s.kind == "speed", (s.rate ?? 0) <= 0 { out.append("\(at): a speed change needs a rate above 0") }
        if s.kind == "text", (s.text ?? "").isEmpty { out.append("\(at): a text needs its words") }
    }
    for m in e.moves where m.t < 0 || m.t > d + 0.01 { out.append("move \(m.id) at \(stamp(m.t)): outside the recording") }
    for s in e.splits where s <= 0 || s >= d { out.append("split at \(stamp(s)): outside the recording") }
    for r in e.removed where !([0] + e.splits).contains(where: { Edits.same($0, r) }) { out.append("removed \(stamp(r)): not the start of a clip part (0 or a split)") }
    let ends = e.pieces(d).map { Edits.key($0.end) }
    for k in e.transitions.keys where !ends.contains(k) { out.append("transition at \(k) ms: not the end of a clip part") }
    if e.pieces(d).allSatisfy(\.removed) { out.append("every clip part is removed") }
    return out
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
    let r = open(ref)
    let map = TimeMap(duration: r.meta.duration, edits: r.edits)
    if flag("--json") {
        let pieces = r.edits.pieces(r.meta.duration).map { ["start": $0.start, "end": $0.end, "removed": $0.removed] as [String: Any] }
        let out: [String: Any] = ["id": r.id, "name": r.meta.name, "kind": r.meta.kind, "recorded": r.meta.duration, "length": map.outputDuration,
                                  "folder": r.folder.path, "clicks": r.meta.clicks.map(\.t), "parts": pieces]
        print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
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
    print("segments (lane: kind, recording time):")
    for s in r.edits.segments.sorted(by: { ($0.lane, $0.start) < ($1.lane, $1.start) }) {
        var what = s.kind
        switch s.kind {
        case "zoom": what += " \(s.level ?? 2)×"
        case "speed": what += " \(s.rate ?? 1)×"
        case "text": what += " “\(s.text ?? "")” \(s.style ?? "plain") in:\(s.animIn ?? "") out:\(s.animOut ?? "")"
        case "3d": what += " \(s.style ?? "hold") tilt \(s.tilt ?? 0) turn \(s.turn ?? 0)"
        default: if s.scope == "frame" { what += " (whole frame)" }
        }
        print("  \(s.lane): \(stamp(s.start))–\(stamp(s.end))  \(what)  [\(s.id)]")
    }
    if !r.edits.moves.isEmpty { print("moves:") }
    for m in r.edits.moves.sorted(by: { $0.t < $1.t }) {
        let a = m.angles.map { "  3D tilt \($0.tilt) turn \($0.turn) roll \($0.roll)" } ?? ""
        print("  lands \(stamp(m.t)) after \(m.duration)s \(m.style): x \(m.to.x) y \(m.to.y) scale \(m.to.scale)\(a)  [\(m.id)]")
    }

case "validate":
    guard let ref = args.first else { fail(usage) }
    let found = problems(open(ref))
    if found.isEmpty { print("ok") } else { found.forEach { print($0) }; exit(1) }

case "frame":
    guard args.count >= 2, let at = Double(args[1]) else { fail(usage) }
    let source = flag("--source")
    let out = URL(fileURLWithPath: option("--out") ?? ".exact/frame.png")
    let r = open(args[0])
    let (mix, comp, map) = composition(r)
    let t = source ? map.output(at) : min(max(at, 0), map.outputDuration - 0.02)
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

case "export":
    guard let ref = args.first else { fail(usage) }
    let r = open(ref)
    if case let found = problems(r), !found.isEmpty { found.forEach { print($0) }; fail("fix these first (exact-studio validate \(r.id))", code: 1) }
    let safe = r.meta.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let out = URL(fileURLWithPath: option("--out") ?? library.deletingLastPathComponent().appendingPathComponent("\(safe) \(r.id).mp4").path)
    try? FileManager.default.removeItem(at: out)
    let (mix, comp, map) = composition(r)
    let quality = option("--quality") ?? "best"
    guard ExportQuality.names.contains(quality) else { fail("no quality \(quality); one of \(ExportQuality.names.joined(separator: ", "))") }
    guard let session = ExportQuality.session(mix, comp, audio: Composition.audioMix(mix, map: map, volume: r.edits.volume), quality: quality, to: out) else { fail("this Mac can't export that") }
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
    guard args.count >= 2 else { fail(usage) }
    var r = open(args[0])
    let map = TimeMap(duration: r.meta.duration, edits: r.edits)
    guard let made = Templates.make(args[1], duration: map.outputDuration, source: { map.source($0) }, aspect: r.look.aspect,
                                    clicks: r.meta.clicks, three: r.edits.three) else { fail("no template \(args[1]); one of \(Templates.names.joined(separator: ", "))") }
    var packed: [Segment] = []
    for var seg in made.segments.sorted(by: { $0.start < $1.start }) {
        var lane = 0
        while packed.contains(where: { $0.lane == lane && $0.overlaps(seg) }) { lane += 1 }
        seg.lane = lane
        packed.append(seg)
    }
    r.edits.segments = packed
    r.edits.moves = made.moves
    r.edits.base = made.base
    r.edits.lanes = max(1, (packed.map(\.lane).max() ?? 0) + 1)
    write(r.edits, r.folder.appendingPathComponent("edits.json"))
    print("\(args[1]) applied to \(r.id): \(packed.count) segments, \(made.moves.count) moves (edits.json)")

case "schema":
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    print("docs/edits.md, schema/edits.schema.json and schema/look.schema.json in the exact-studio repository (\(root.path))")

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n" + usage)
}
