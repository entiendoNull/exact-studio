import AppKit
import AVFoundation
import CoreImage.CIFilterBuiltins

setvbuf(stdout, nil, _IOLBF, 0)
_ = NSApplication.shared

// MARK: A small runner

var passed = 0, failed: [String] = []
var current = ""
var problems: [String] = []

func test(_ name: String, _ body: () throws -> Void) {
    current = name
    problems = []
    do { try body() } catch { problems.append("threw \(error)") }
    if problems.isEmpty { passed += 1; print("  ok    \(name)") }
    else { failed.append(name); print("  FAIL  \(name)"); problems.forEach { print("        \($0)") } }
}

func expect(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
    if !ok { problems.append("line \(line): \(what())") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ what: String = "", line: Int = #line) {
    if a != b { problems.append("line \(line): \(what.isEmpty ? "" : what + ": ")got \(a), expected \(b)") }
}

func near(_ a: Double, _ b: Double, _ what: String = "", within: Double = 0.001, line: Int = #line) {
    if abs(a - b) > within { problems.append("line \(line): \(what.isEmpty ? "" : what + ": ")got \(a), expected \(b)") }
}

func decode(_ json: String) throws -> Edits { try JSONDecoder().decode(Edits.self, from: Data(json.utf8)) }

func seg(_ id: String, _ kind: String, _ start: Double, _ end: Double, lane: Int = 0) -> Segment {
    var s = Segment(id: id, kind: kind, start: start, end: end, lane: lane)
    if kind == "zoom" { s.level = 2 }
    if kind == "speed" { s.rate = 2 }
    if kind == "text" { s.text = "Hi" }
    return s
}

func wait(_ seconds: Double = 5, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > end { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return true
}

// MARK: The fixture video

func makeVideo(_ out: URL, seconds: Int, fps: Int32 = 10, width: Int = 320, height: Int = 180) throws {
    try? FileManager.default.removeItem(at: out)
    let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for i in 0...(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let b = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(b, [])
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<height { for x in 0..<width {
            let o = y * row + x * 4
            p[o] = UInt8((x + i * 4) % 256); p[o + 1] = UInt8(y % 256); p[o + 2] = 90; p[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(b, [])
        adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

let argv = CommandLine.arguments
if argv.count >= 3, argv[1] == "video" {
    do { try makeVideo(URL(fileURLWithPath: argv[2]), seconds: argv.count > 3 ? Int(argv[3]) ?? 10 : 10) }
    catch { FileHandle.standardError.write("couldn't write the video: \(error)\n".data(using: .utf8)!); exit(1) }
    exit(0)
}
guard argv.count >= 2 else { print("usage: model <repo root> | model video <out.mov> [seconds]"); exit(2) }
let repo = URL(fileURLWithPath: argv[1])
let fixtures = repo.appendingPathComponent("test/fixtures")

// MARK: The edit model

print("edit model")

test("an empty file takes every default") {
    let e = try decode("{}")
    eq(e.lanes, 1); eq(e.textLanes, 0); eq(e.imageLanes, 0); eq(e.frameLanes, 0); eq(e.soundLanes, 0)
    eq(e.volume, 1); eq(e.three.on, false); eq(e.base, Placement()); eq(e.segments.count, 0)
}

test("every key the format calls optional takes its documented default") {
    let e = try decode("""
    { "textLanes": 1, "imageLanes": 1, "base": { "x": 0.2 },
      "segments": [
        { "id": "z", "kind": "zoom", "start": 1, "end": 2, "level": 2 },
        { "id": "k", "kind": "mask", "start": 1, "end": 2, "rect": { "x": 0, "y": 0, "w": 0.5, "h": 0.5 } },
        { "id": "i", "kind": "image", "start": 1, "end": 5, "file": "images/logo.png",
          "moves": [{ "id": "im", "t": 3, "to": { "scale": 0.5 } }],
          "effects": [{ "id": "fx", "kind": "pulse", "start": 2, "end": 3 }] }
      ],
      "moves": [{ "id": "m", "t": 1, "to": {} }, { "id": "a", "t": 2, "to": { "x": 0.3 }, "angles": { "turn": 20 } }],
      "sounds": [{ "id": "s", "file": "sounds/beep.wav", "start": 0, "length": 1 }] }
    """)
    eq(e.segments.map(\.lane), [0, 0, 0], "a segment's lane")
    eq(e.segments[1].style, nil, "a mask's style is left out, and drawn as blur")
    let image = e.segments[2]
    eq(image.effects?.first?.lane, 0, "an image effect's lane")
    eq(image.moves?.first, Move(id: "im", t: 3, to: Placement(x: 0.5, y: 0.5, scale: 0.5), style: "smooth", duration: 0.8))
    eq(e.moves[0], Move(id: "m", t: 1, to: Placement(), style: "smooth", duration: 0.8, angles: nil))
    eq(e.moves[1].to, Placement(x: 0.3, y: 0.5, scale: 1)); eq(e.moves[1].angles, Angles(tilt: 0, turn: 20, roll: 0))
    eq(e.base, Placement(x: 0.2, y: 0.5, scale: 1))
    eq(e.sounds.first?.lane, 0); eq(e.sounds.first?.volume, 1)
}

test("a file that truly can't be read says where, and a missing file is no file") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("exact-studio-read-\(getpid()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try? FileManager.default.removeItem(at: url)
    expect(try EditFile.read(Edits.self, url) == nil, "a missing file reads as none")
    for (json, why) in [("{ \"lanes\": \"two\" }", "lanes: Expected to decode Int but found a string instead."),
                        ("{ \"moves\": [{ \"id\": \"m\", \"to\": {} }] }", "moves.Index 0: missing t"),
                        ("{ \"segments\": [", "The given data was not valid JSON.")] {
        try Data(json.utf8).write(to: url)
        do { _ = try EditFile.read(Edits.self, url); expect(false, "\(json) was read") } catch {
            expect(EditFile.problem(error).hasPrefix(why), "\(json): \(EditFile.problem(error))")
        }
    }
}

test("an old file: cuts become splits, texts and whole-frame effects get lanes of their own, each image keeps a lane") {
    let e = try JSONDecoder().decode(Edits.self, from: Data(contentsOf: fixtures.appendingPathComponent("valid/old-format/edits.json")))
    eq(e.splits, [4, 5]); eq(e.removed, [4])
    expect(!e.segments.contains { $0.kind == "cut" }, "a cut segment is left")
    eq(e.segments.first { $0.id == "t" }?.lane, 0, "text lane")
    eq(e.segments.first { $0.id == "m" }?.lane, 0, "whole-frame lane")
    eq(e.segments.first { $0.id == "z" }?.lane, 0, "zoom lane")
    eq(e.segments.first { $0.id == "i2" }?.lane, 0, "the image on the old top row is in front")
    eq(e.segments.first { $0.id == "i1" }?.lane, 1)
    eq(e.lanes, 1); eq(e.textLanes, 1); eq(e.frameLanes, 1); eq(e.imageLanes, 2)
}

test("a file written and read back is the same edit") {
    let e = try JSONDecoder().decode(Edits.self, from: Data(contentsOf: fixtures.appendingPathComponent("valid/full/edits.json")))
    let again = try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e))
    eq(again, e)
}

test("splits make parts; a part is removed by its start") {
    var e = Edits()
    e.splits = [3, 4.5, 7]; e.removed = [3]
    let p = e.pieces(10)
    eq(p.map(\.start), [0, 3, 4.5, 7]); eq(p.map(\.end), [3, 4.5, 7, 10]); eq(p.map(\.removed), [false, true, false, false])
    eq(p[1].id, "p:3000")
    e.splits = [0, 10, 12]
    eq(e.pieces(10).count, 1, "splits at the ends or past them make no parts")
}

test("two zooms, speeds or 3D turns never overlap, on any lane; the reason names the other and a way out") {
    for (kind, rule) in [("zoom", "one-zoom"), ("speed", "one-speed"), ("3d", "one-3d")] {
        let e = Edits(segments: [seg("a", kind, 1, 3, lane: 0), seg("b", kind, 2, 4, lane: 1)])
        eq(e.conflict(e.segments[1])?.rule, rule, kind)
        eq(e.conflict(e.segments[1])?.other, ItemRef(kind: kind, id: "a"), kind)
    }
    let e = Edits(segments: [seg("a", "zoom", 1, 3.04, lane: 0), seg("b", "zoom", 2, 4, lane: 1)])
    eq(e.conflict(e.segments[1])?.line1, "One zoom at a time.")
    eq(e.conflict(e.segments[1])?.line2, "Zoom in 2× runs to 0:03.1. Start it at 0:03.1 or later.", "rounded later, so the advice is right")
    eq(e.conflict(e.segments[0])?.line2, "Zoom in 2× starts at 0:02.0. End it by 0:02.0.")
    let touching = Edits(segments: [seg("a", "zoom", 1, 3), seg("b", "zoom", 3, 4)])
    eq(touching.conflict(touching.segments[1]), nil, "touching zooms")
}

test("P2: one blur and one black & white at a time, whatever each covers") {
    let e = Edits(segments: [seg("a", "blur", 1, 3, lane: 0), seg("b", "blur", 2, 4, lane: 1)])
    eq(e.conflict(e.segments[1])?.rule, "one-blur")
    var frame = seg("b", "blur", 2, 4)
    frame.scope = "frame"
    let mixed = Edits(segments: [seg("a", "blur", 1, 3), frame])
    eq(mixed.conflict(frame)?.rule, "one-blur", "a video blur under a whole-frame blur")
    eq(mixed.conflict(frame)?.text, "One blur at a time. Blur · video runs to 0:03.0. Start it at 0:03.0 or later.")
    var all = seg("c", "mono", 2, 4)
    all.scope = "all"
    let mono = Edits(segments: [seg("a", "mono", 1, 3), all])
    eq(mono.conflict(all)?.rule, "one-mono")
    let different = Edits(segments: [seg("a", "spotlight", 1, 3, lane: 0), seg("b", "highlight", 2, 4, lane: 1)])
    eq(different.conflict(different.segments[1]), nil)
}

test("P4: no zoom during a 3D orbit; a 3D hold may have one") {
    var orbit = seg("o", "3d", 1, 5)
    orbit.style = "orbit"
    let e = Edits(segments: [orbit, seg("z", "zoom", 3, 6, lane: 1)])
    eq(e.conflict(e.segments[1])?.rule, "no-zoom-in-orbit")
    eq(e.conflict(e.segments[1])?.text, "No zoom during an orbit. 3D orbit runs to 0:05.0. Start it at 0:05.0 or later.")
    eq(e.conflict(orbit)?.rule, "no-zoom-in-orbit", "told from the orbit too")
    var hold = orbit
    hold.style = "hold"
    eq(Edits(segments: [hold, seg("z", "zoom", 3, 6, lane: 1)]).conflict(seg("z", "zoom", 3, 6, lane: 1)), nil)
}

test("P1: a move starts travelling only after the move before it lands, for the video and each image") {
    var e = Edits()
    e.moves = [Move(id: "a", t: 9, to: Placement()), Move(id: "b", t: 9.5, to: Placement(), duration: 0.8)]
    let c = e.conflicts(ofMove: e.moves[1])
    eq(c.map(\.rule), ["move-after-move"])
    eq(c.first?.text, "One move at a time. The move before lands at 0:09.0. Land this one at 0:09.8 or later.")
    eq(e.conflicts(ofMove: e.moves[0]).first?.line2, "The next move starts at 0:08.7. Land this one by 0:08.7.")
    eq(e.conflicts(map: TimeMap(duration: 20, edits: e)).count, 1, "one per pair")
    e.moves[1].t = 9.8
    eq(e.conflicts(ofMove: e.moves[1]), [], "travels from the landing on")
    var image = seg("i", "image", 0, 10)
    image.moves = [Move(id: "a", t: 3, to: Placement()), Move(id: "b", t: 3.2, to: Placement())]
    eq(Edits.conflict(in: image)?.rule, "move-after-move")
    eq(Edits.conflict(in: image)?.item, ItemRef(kind: "image-move", id: "b", image: "i"))
}

test("one lane holds one thing at a time; texts, images and masks overlap on separate lanes") {
    let e = Edits(segments: [seg("a", "spotlight", 1, 3), seg("b", "highlight", 2, 4)])
    eq(e.conflict(e.segments[1])?.text, "That lane is taken. Spotlight is on this lane then. Put it on another lane.")
    for kind in ["text", "mask"] {
        let two = Edits(segments: [seg("a", kind, 1, 3, lane: 0), seg("b", kind, 2, 4, lane: 1)])
        eq(two.conflict(two.segments[1]), nil, kind)
        let one = Edits(segments: [seg("a", kind, 1, 3), seg("b", kind, 2, 4)])
        eq(one.conflict(one.segments[1])?.rule, "lane-taken", kind)
    }
    let spaces = Edits(segments: [seg("a", "zoom", 1, 3), seg("b", "text", 1, 3)])
    eq(spaces.conflict(spaces.segments[1]), nil, "a text and a zoom on lane 0 of their own spaces")
}

test("an image's own effects and moves stay inside it and never clash") {
    var image = seg("i", "image", 2, 6)
    image.file = "images/logo.png"
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "fade", 3, 5, lane: 1)]
    eq(Edits.conflict(in: image), nil)
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "pulse", 3, 5, lane: 1)]
    eq(Edits.conflict(in: image)?.text, "One of each per image. Its pulse runs to 0:04.0. Start it at 0:04.0 or later.")
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "fade", 3, 5)]
    eq(Edits.conflict(in: image)?.text, "That row is taken. Its pulse is on this row then. Put it on another row.")
    image.effects = [seg("e1", "pulse", 5, 7)]
    eq(Edits.conflict(in: image)?.text, "Keep it inside the image. logo.png shows 0:02.0–0:06.0. Start and end it there.")
    image.effects = [seg("e1", "sparkle", 2, 3)]
    eq(Edits.conflict(in: image)?.rule, "image-effect-kind")
    image.effects = []
    image.moves = [Move(id: "m", t: 7, to: Placement())]
    eq(Edits.conflict(in: image)?.text, "Keep it inside the image. logo.png shows 0:02.0–0:06.0. Land the move there.")
}

test("every rule's line 1 is short: five words or fewer") {
    for (id, line) in Rules.all {
        let words = line.split(separator: " ").filter { $0 != "&" }.count
        expect(words <= 5, "\(id): “\(line)” has \(words) words")
        expect(line.hasSuffix("."), "\(id): ends with a full stop")
    }
}

test("a new segment takes the first lane free then, else one past the last") {
    var e = Edits(segments: [seg("a", "spotlight", 1, 3, lane: 0), seg("b", "highlight", 1, 3, lane: 1)])
    e.lanes = 3
    eq(e.freeLane(for: seg("c", "blur", 2, 4)), 2)
    eq(e.freeLane(for: seg("c", "blur", 3, 4)), 0)
    e.lanes = 2
    eq(e.freeLane(for: seg("c", "blur", 2, 4)), 2)
    e.segments.append(seg("c", "blur", 2, 4, lane: 2))
    e.fitLanes()
    eq(e.lanes, 3, "fitLanes opens the lane")
}

test("pack lays segments on the fewest lanes and keeps the images' lanes") {
    var e = Edits()
    e.lanes = 4; e.textLanes = 3
    e.pack([seg("t1", "text", 0, 2, lane: 2), seg("t2", "text", 1, 3, lane: 2), seg("z", "zoom", 0, 2, lane: 3), seg("i", "image", 0, 2, lane: 1)])
    eq(e.segments.first { $0.id == "t1" }?.lane, 0); eq(e.segments.first { $0.id == "t2" }?.lane, 1)
    eq(e.segments.first { $0.id == "z" }?.lane, 0); eq(e.segments.first { $0.id == "i" }?.lane, 1)
    eq(e.lanes, 1); eq(e.textLanes, 2); eq(e.imageLanes, 2)
}

test("the time map skips removed parts and stretches slow parts") {
    var e = Edits(segments: [seg("s", "speed", 7.5, 9)])
    e.segments[0].rate = 0.5
    e.splits = [3, 4.5]; e.removed = [3]
    let map = TimeMap(duration: 10, edits: e)
    near(map.outputDuration, 10 - 1.5 + 1.5)
    near(map.output(2), 2); near(map.output(3.5), 3, "inside a removed part: where the next part starts")
    near(map.output(5), 3.5); near(map.output(8), 6.0 + 1)
    for t in [0.5, 2.9, 4.6, 7.6, 8.9, 9.9] { near(map.source(map.output(t)), t, "round trip at \(t)") }
    e.transitions = ["3000": "crossfade"]
    near(TimeMap(duration: 10, edits: e).outputDuration, 10 - 0.6, "a crossfade overlaps the parts")
}

test("sounds on one lane never play at once; a free lane is found for a new one") {
    var e = Edits()
    e.sounds = [Sound(id: "a", file: "sounds/beep.wav", start: 1, length: 2)]
    e.soundLanes = 1
    let map = TimeMap(duration: 10, edits: e)
    let b = Sound(id: "b", file: "sounds/beep.wav", start: 2, length: 1)
    eq(e.conflict(b, map: map)?.text, "That lane is taken. beep.wav is on this lane then. Put it on another lane.")
    eq(e.freeLane(for: b, map: map), 1)
    eq(e.conflict(Sound(id: "c", file: "sounds/beep.wav", start: 3, length: 1), map: map), nil)
}

test("Zoom on Clicks: clicks close together share a zoom") {
    let z = Edits.autoZooms([Point(t: 2, x: 0, y: 0), Point(t: 3, x: 0, y: 0), Point(t: 8, x: 0, y: 0)], duration: 10)
    eq(z.count, 2)
    near(z[0].start, 1.2); near(z[0].end, 5.2); near(z[1].end, 10)
}

func templateMeta(_ kind: String, _ w: Double, _ h: Double, duration: Double, clicks: [Double]) -> RecordingMeta {
    RecordingMeta(id: "t", name: "t", kind: kind, created: 0, duration: duration, width: w, height: h, crop: .full,
                  clicks: clicks.enumerated().map { Point(t: $1, x: 0.3 + 0.1 * Double($0 % 4), y: 0.5) })
}

func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { a.0 < b.1 - 0.001 && b.0 < a.1 - 0.001 }

test("every template, on every frame shape, length, click pattern and cut, is clean, readable and calm") {
    let shapes = [("simulator", 814.0, 1770.0), ("display", 1920.0, 1080.0), ("display", 1322.0, 534.0), ("window", 800.0, 800.0)]
    var made = 0
    for info in Templates.all { for aspect in ["16:9", "9:16", "1:1", "4:3", "auto"] { for (kind, w, h) in shapes {
        for length in [info.shortest, 8, 20, 60, 180] where length >= info.shortest { for pattern in ["none", "one", "sparse", "dense"] { for cut in [false, true] {
            let clicks: [Double] = pattern == "none" ? [] : pattern == "one" ? [length * 0.6]
                : Array(stride(from: 1.0, to: length - 0.5, by: pattern == "sparse" ? 5.5 : 1.1))
            var edits = Edits()
            if cut, length >= info.shortest + 2 { edits.splits = [length * 0.4, length * 0.4 + 1.5]; edits.removed = [length * 0.4] }
            let meta = templateMeta(kind, w, h, duration: length, clicks: clicks)
            var look = Look(); look.aspect = aspect
            let map = TimeMap(duration: length, edits: edits)
            let at = "\(info.name) \(aspect) \(kind) \(Int(w))×\(Int(h)) \(length)s \(pattern)\(cut ? " cut" : "")"
            guard map.outputDuration >= info.shortest else {
                expect(Templates.make(info.name, map: map, meta: meta, look: look) == nil, "\(at): made for a video under \(info.shortest) s"); continue
            }
            guard let m = Templates.make(info.name, map: map, meta: meta, look: look) else {
                let room = clicks.map { map.output($0) - 0.5 }.contains { $0 >= 0 && $0 + 2.5 <= map.outputDuration - 1.2 }
                expect(info.name == "clean" && !room, "\(at): made nothing"); continue
            }
            made += 1
            let again = Templates.make(info.name, map: map, meta: meta, look: look)
            expect(again?.segments == m.segments && again?.moves == m.moves, "\(at): not the same twice")
            var e = Templates.apply(m, to: edits)
            e.pack(e.segments)
            expect(!e.segments.isEmpty, "\(at): nothing in it")
            e.moves = m.moves
            for c in e.conflicts(map: TimeMap(duration: length, edits: e)) { expect(false, "\(at): \(c.rule) \(c.item?.key ?? ""): \(c.text)") }
            for s in e.segments {
                expect(s.start >= 0 && s.end <= length + 0.001 && s.end - s.start >= 0.1, "\(at): \(s.kind) \(s.id) at \(s.start)–\(s.end)")
            }
            for mv in m.moves { expect(mv.t >= 0 && mv.t <= length + 0.001, "\(at): move at \(mv.t)") }
            let out = { (s: Segment) in (map.output(s.start), map.output(s.end)) }
            let texts = e.texts.sorted { $0.start < $1.start }
            expect(texts.contains(where: \.isPlaceholder) == info.placeholders, "\(at): placeholders \(texts.map { $0.text ?? "" })")
            let stage = Templates.Stage.of(meta: meta, look: look)
            for t in texts {
                let words = t.isPlaceholder ? Templates.slotWords : (t.text ?? "").split(separator: " ").count
                let (a, b) = out(t)
                expect(b - a >= Templates.onScreen(words: words) - 0.001, "\(at): “\(t.text ?? "")” on screen \(b - a) s, needs \(Templates.onScreen(words: words))")
                let width = Double((t.text ?? "").count) * (t.size ?? 0.05) * 0.5 / stage.ratio
                let centred = abs((t.x ?? 0.5) - 0.5) < 0.01
                expect(width <= (centred ? 0.8 : stage.room) + 0.001, "\(at): “\(t.text ?? "")” \(width) of the width")
                expect((t.size ?? 0) >= 0.04, "\(at): “\(t.text ?? "")” size \(t.size ?? 0)")
                expect(t.animIn != "letters" && t.loop == "none", "\(at): a loud text \(t.id)")
            }
            for (x, y) in zip(texts, texts.dropFirst()) where x.x == y.x && x.y == y.y {
                expect(out(y).0 - out(x).1 >= 0.3 - 0.001, "\(at): \(x.id) and \(y.id) follow too closely in one place")
            }
            for (x, y) in zip(texts, texts.dropFirst()) where overlap(out(x), out(y)) {
                expect(info.name == "launch" && x.id.hasSuffix("t2") && y.id.hasSuffix("t3"), "\(at): \(x.id) and \(y.id) on screen together")
            }
            let emphasis = e.segments.filter { ["zoom", "3d", "spotlight", "highlight", "mono"].contains($0.kind) || ($0.kind == "blur" && !$0.coversFrame) }
            for z in emphasis {
                for t in texts where overlap(out(z), out(t)) { expect(false, "\(at): \(z.kind) \(z.id) fights \(t.id)") }
                for o in emphasis where o.id < z.id && overlap(out(z), out(o)) { expect(false, "\(at): \(z.kind) \(z.id) fights \(o.kind) \(o.id)") }
                if z.kind == "zoom" { expect(map.output(z.end) - map.output(z.start) >= 2.5 - 0.001, "\(at): zoom \(z.id) too short to hold") }
            }
            let zooms = e.segments.filter { $0.kind == "zoom" }.sorted { $0.start < $1.start }
            for (x, y) in zip(zooms, zooms.dropFirst()) { expect(out(y).0 - out(x).1 >= 1 - 0.001, "\(at): zooms \(x.id) and \(y.id) back to back") }
            for b in e.segments where b.coversFrame {
                expect(texts.contains { overlap(out(b), out($0)) } && out(b).0 < 0.01, "\(at): a blur \(b.id) that is not under the opening title")
            }
        } } }
    } } }
    expect(made > 1000, "only \(made) made")
    var look = Look(); look.aspect = "16:9"
    let map = TimeMap(duration: 10, edits: Edits())
    expect(Templates.make("nope", map: map, meta: templateMeta("display", 1920, 1080, duration: 10, clicks: []), look: look) == nil, "an unknown template")
}

test("templates fit the recording: zooms land on clicks, steps follow them, Before / After takes the cut") {
    var look = Look(); look.aspect = "16:9"
    let meta = templateMeta("display", 1920, 1080, duration: 30, clicks: [3, 12, 21])
    let map = TimeMap(duration: 30, edits: Edits())
    let clean = Templates.make("clean", map: map, meta: meta, look: look)!
    eq(clean.segments.map(\.start), [2.5, 11.5, 20.5])
    let steps = Templates.make("steps", map: map, meta: meta, look: look)!
    eq(steps.segments.map(\.text!), ["1. [What to do]", "2. [What to do]", "3. [What to do]"])
    eq(steps.segments.map(\.start), [0.2, 11.4, 20.4])
    var cut = Edits(); cut.splits = [8, 10]; cut.removed = [8]
    let ba = Templates.make("before-after", map: TimeMap(duration: 30, edits: cut), meta: meta, look: look)!
    eq(ba.segments.map(\.text!), ["Before", "After"])
    near(ba.segments[0].end, 7.85); near(ba.segments[1].start, 10.25)
    let tall = Templates.make("social", map: map, meta: meta, look: { var l = look; l.aspect = "9:16"; return l }())!
    expect(tall.segments[0].y! < tall.base.y, "the hook stands above the video in a tall frame")
    let wide = Templates.make("social", map: map, meta: templateMeta("simulator", 814, 1770, duration: 30, clicks: []), look: look)!
    expect(wide.segments[0].x! < wide.base.x, "the hook stands beside a phone in a wide frame")
}

test("mask colours: a hex or a text colour's name, else refused") {
    eq(Segment.maskHex(nil), "#000000"); eq(Segment.maskHex("pink"), "#FF458C"); eq(Segment.maskHex("#a1b2c3"), "#A1B2C3")
    eq(Segment.maskHex("teal"), nil)
}

// MARK: Motion paths

func pathFraming(_ edits: String, aspect: String = "16:9", kind: String = "area") throws -> Framing {
    let meta = try JSONDecoder().decode(RecordingMeta.self, from: Data("""
    {"id":"m","name":"m","kind":"\(kind)","created":0,"duration":10,"width":1600,"height":1000,
     "crop":{"x":0,"y":0,"w":1,"h":1},"clicks":[],"cursorBaked":true}
    """.utf8))
    var look = Look()
    look.aspect = aspect; look.shadow = false; look.background = "custom"; look.customA = "#000000"; look.customB = "#101010"; look.radius = 0
    return Framing(meta: meta, look: look, edits: try decode(edits), cursor: [])
}

let pathContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

func drawnBounds(_ f: Framing, at t: Double) -> CGRect {
    let w = Int(f.canvas.width), h = Int(f.canvas.height)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    let image = f.render(source, at: t, texts: false)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    pathContext.render(image, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
    var x0 = w, x1 = -1, y0 = h, y1 = -1
    for y in 0..<h { for x in 0..<w {
        let o = (y * w + x) * 4
        if px[o] > 200 && px[o + 1] < 60 && px[o + 2] > 200 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
    } }
    guard x1 >= 0 else { return .null }
    return CGRect(x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h), width: CGFloat(x1 - x0 + 1) / CGFloat(w), height: CGFloat(y1 - y0 + 1) / CGFloat(h))
}

func sameBox(_ drawn: CGRect, _ path: [CGPoint], _ what: String, pixels: Double = 3, canvas: CGSize, line: Int = #line) {
    let b = MotionPath.bounds(path).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    expect(!drawn.isNull, "\(what): nothing drawn", line: line)
    let px = pixels / Double(canvas.width), py = pixels / Double(canvas.height)
    near(drawn.minX, b.minX, "\(what) left", within: px, line: line); near(drawn.maxX, b.maxX, "\(what) right", within: px, line: line)
    near(drawn.minY, b.minY, "\(what) top", within: py, line: line); near(drawn.maxY, b.maxY, "\(what) bottom", within: py, line: line)
}

let pathMoves = """
{"base":{"x":0.5,"y":0.5,"scale":0.9},"moves":[
 {"id":"a","t":2,"to":{"x":0.3,"y":0.4,"scale":0.6}},
 {"id":"b","t":4,"to":{"x":0.72,"y":0.62,"scale":0.8},"style":"spring","duration":1.2},
 {"id":"c","t":6,"to":{"x":0.5,"y":0.45,"scale":1.1},"style":"linear"}]%@}
"""

test("each dashed landing frame is where the renderer puts the video at that move's time") {
    let f = try pathFraming(pathMoves.replacingOccurrences(of: "%@", with: ""))
    let path = f.motionPath(at: 1)!
    eq(path.landings.map(\.id), ["a", "b", "c"])
    eq(path.landings.map(\.label), ["1 · Smooth · 0:02.0", "2 · Spring · 0:04.0", "3 · Linear · 0:06.0"])
    for l in path.landings { sameBox(drawnBounds(f, at: l.t), l.corners, "move \(l.id)", canvas: f.canvas) }
    sameBox(drawnBounds(f, at: 1), path.now, "now", canvas: f.canvas)
    near(path.start.x, 0.5); near(path.start.y, 0.5)
}

test("a landing frame follows the frame shape, the padding and a zoom at its time") {
    let zoomed = pathMoves.replacingOccurrences(of: "%@", with: #","segments":[{"id":"z","kind":"zoom","start":3,"end":5,"level":1.5}]"#)
    for aspect in ["9:16", "1:1"] {
        let f = try pathFraming(zoomed, aspect: aspect)
        for l in f.motionPath(at: 0)!.landings { sameBox(drawnBounds(f, at: l.t), l.corners, "\(aspect) move \(l.id)", canvas: f.canvas) }
    }
}

test("in 3D a landing frame is the turned face the renderer draws") {
    let flat3D = pathMoves.replacingOccurrences(of: "%@", with: #","three":{"on":true}"#)
    let f = try pathFraming(flat3D)
    for l in f.motionPath(at: 0)!.landings { sameBox(drawnBounds(f, at: l.t), l.corners, "3D at 0° move \(l.id)", canvas: f.canvas) }
    let turned = """
    {"three":{"on":true,"thickness":0.02},"moves":[
     {"id":"a","t":2,"to":{"x":0.45,"y":0.5,"scale":1},"angles":{"tilt":12,"turn":-24,"roll":0}},
     {"id":"b","t":4,"to":{"x":0.55,"y":0.5,"scale":0.8},"angles":{"tilt":4,"turn":14,"roll":3}}]}
    """
    let g = try pathFraming(turned)
    for l in g.motionPath(at: 0)!.landings {
        eq(l.radius, 0, "a turned frame has no rounded corners")
        sameBox(drawnBounds(g, at: l.t), l.corners, "turned move \(l.id)", pixels: 4, canvas: g.canvas)
    }
}

test("an image's path: its box at each landing, turned with it; nothing without moves") {
    let f = try pathFraming(#"{"imageLanes":1,"segments":[{"id":"i","kind":"image","start":0,"end":8,"lane":0,"x":0.2,"y":0.3,"size":0.2,"rotation":90,"moves":[{"id":"m","t":3,"to":{"x":0.8,"y":0.7,"scale":0.5}}]}]}"#)
    let image = f.edits.segments[0]
    let path = f.motionPath(image: image, at: 0)!
    let box = f.imageFrame(image, at: 3)
    let b = MotionPath.bounds(path.landings[0].corners)
    near(b.midX, box.x + box.w / 2); near(b.midY, box.y + box.h / 2)
    near(b.height, box.w * f.canvas.width / f.canvas.height, "turned a quarter, its width stands up")
    near(path.start.x, 0.2); near(path.start.y, 0.3)
    expect(try pathFraming("{}").motionPath(at: 0) == nil, "no moves, no path")
}

test("the motion paths are never in a rendered frame: the preview alone draws them") {
    let f = try pathFraming(pathMoves.replacingOccurrences(of: "%@", with: ""))
    let w = Int(f.canvas.width), h = Int(f.canvas.height)
    let source = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    pathContext.render(f.render(source, at: 3, texts: true), toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
    var lit = 0
    for i in stride(from: 0, to: px.count, by: 4) where px[i] > 230 && px[i + 1] > 230 && px[i + 2] > 230 { lit += 1 }
    eq(lit, 0, "no white dashed frame, label or diamond in the render")
    var teal = 0
    for i in stride(from: 0, to: px.count, by: 4) where px[i] < 140 && px[i + 1] > 150 && px[i + 2] > 180 { teal += 1 }
    eq(teal, 0, "no teal path or arrow in the render")
}

// MARK: The editor


// MARK: Seamless splits

test("a split's halves join: both say so, the second gets a fresh id, an image's moves and effects go with their time") {
    var e = try decode("""
    { "imageLanes": 1, "segments": [
      { "id": "z1", "kind": "zoom", "start": 1, "end": 3, "level": 2 },
      { "id": "i", "kind": "image", "start": 1, "end": 5, "file": "images/logo.png",
        "moves": [{ "id": "a", "t": 2, "to": {} }, { "id": "b", "t": 4, "to": {} }],
        "effects": [{ "id": "p", "kind": "pulse", "start": 1.5, "end": 4 }, { "id": "q", "kind": "blur", "start": 4, "end": 5 }] } ] }
    """)
    let made = try e.splitSegment("z1", at: 2)
    eq(made, "z1-2")
    eq(e.segments.map(\.id), ["z1", "z1-2", "i"], "the second half follows the first, so the drawing order stays")
    eq(e.segments[0].end, 2); eq(e.segments[0].joinEnd, true); eq(e.segments[0].joinStart, nil)
    eq(e.segments[1].start, 2); eq(e.segments[1].joinStart, true); eq(e.segments[1].joinEnd, nil)
    expect(e.segments[0].joins(e.segments[1]), "the halves join")
    eq(try e.splitSegment("z1-2", at: 2.5), "z1-3", "a second split counts on")
    eq(Joins.run(e.segments[1], in: e.segments).map(\.id), ["z1", "z1-2", "z1-3"])
    try e.splitSegment("i", at: 3)
    let left = e.segments.first { $0.id == "i" }!, right = e.segments.first { $0.id == "i-2" }!
    eq(left.moves?.map(\.id), ["a"]); eq(right.moves?.map(\.id), ["b"])
    eq(left.effects?.map(\.id), ["p"]); eq(right.effects?.map(\.id), ["p-2", "q"])
    eq(left.effects?.first?.joinEnd, true); eq(right.effects?.first?.joinStart, true)
    let whole = Joins.whole(right, run: Joins.run(right, in: e.segments))
    eq(whole.start, 1); eq(whole.end, 5); eq(whole.moves?.map(\.id), ["a", "b"]); eq(whole.effects?.map(\.id), ["p", "p-2", "q"])
    do { try e.splitSegment("i", at: 2.95); expect(false, "a piece shorter than 0.1 s") } catch let r as SplitRefused { expect(r.why.contains("0.1 s"), r.why) }
}

test("a split sound plays on from the same moment of its file, and keeps its fades at the run's ends") {
    var e = try decode("""
    { "splits": [2, 3], "removed": [2], "soundLanes": 1,
      "sounds": [{ "id": "s", "file": "sounds/beep.wav", "start": 1, "length": 4, "offset": 0.5, "fadeIn": 0.6, "fadeOut": 1.5 }] }
    """)
    let map = TimeMap(duration: 10, edits: e)
    let whole = e.sounds[0], (a, b) = whole.playing(map)
    try e.splitSound("s", at: 4, map: map)
    let l = e.sounds[0], r = e.sounds[1]
    eq(r.id, "s-2"); eq(r.start, 4)
    near(l.playing(map).end, map.output(4)); near(r.playing(map).start, map.output(4)); near(r.playing(map).end, b)
    near(r.offset, l.offset + l.length, "the second half plays on from where the first stopped")
    eq(Joins.run(r, in: e.sounds, map: map).map(\.id), ["s", "s-2"])
    func level(_ ramps: [(start: Double, end: Double, from: Double, to: Double)], _ x: Double) -> Double? {
        ramps.first { x >= $0.start && x <= $0.end }.map { $0.from + ($0.to - $0.from) * ($0.end > $0.start ? (x - $0.start) / ($0.end - $0.start) : 0) }
    }
    let before = Sound.ramps(a, b, run: a, b, fadeIn: whole.fadeIn, fadeOut: whole.fadeOut)
    let left = Sound.ramps(l.playing(map).start, l.playing(map).end, run: a, b, fadeIn: l.fadeIn, fadeOut: r.fadeOut)
    let right = Sound.ramps(r.playing(map).start, r.playing(map).end, run: a, b, fadeIn: l.fadeIn, fadeOut: r.fadeOut)
    for x in stride(from: a, through: b, by: 0.05) {
        let after = x < l.playing(map).end ? level(left, x) : level(right, x)
        near(after ?? -1, level(before, x) ?? -2, "the volume at \(x)", within: 0.0001)
    }
    near(level(left, l.playing(map).end) ?? 0, 1, "no fade out where the halves meet")
    near(level(right, r.playing(map).start) ?? 0, 1, "no fade in where they meet")
}

test("Split All Lanes cuts the clip and every block under the playhead; moves never") {
    var e = try decode("""
    { "lanes": 2, "textLanes": 1, "soundLanes": 1,
      "segments": [{ "id": "z", "kind": "zoom", "start": 1, "end": 4, "level": 2 }, { "id": "sp", "kind": "speed", "start": 2, "end": 6, "lane": 1, "rate": 2 },
                   { "id": "t", "kind": "text", "start": 0, "end": 9, "text": "Hi" }, { "id": "late", "kind": "blur", "start": 5, "end": 6 },
                   { "id": "edge", "kind": "mono", "start": 2.95, "end": 4, "lane": 1 }],
      "moves": [{ "id": "m", "t": 3, "to": { "x": 0.3 } }],
      "sounds": [{ "id": "s", "file": "sounds/beep.wav", "start": 0, "length": 5 }] }
    """)
    let before = e, map = TimeMap(duration: 10, edits: e)
    let cut = try e.splitAll(at: 3, duration: 10, map: map)
    eq(cut, ["clip", "zoom z → z-2", "speed sp → sp-2", "text t → t-2", "sound s → s-2"])
    eq(e.splits, [3]); eq(e.moves, before.moves); eq(e.segments.count, 8)
    eq(TimeMap(duration: 10, edits: e).outputDuration, map.outputDuration, "a split speed keeps the timing")
    expect(e.looseJoins(map: map).isEmpty, "\(e.looseJoins(map: map))")
    var again = e
    do { try again.splitAll(at: 3, duration: 10, map: map); expect(false, "nothing is left to cut there") } catch let r as SplitRefused {
        eq(r.why, "Nothing under the playhead can be split there.")
    }
}

test("joins survive saving; a file without them loads unjoined; a half moved away loses its join") {
    var e = Edits(segments: [seg("z", "zoom", 1, 3)])
    try e.splitSegment("z", at: 2)
    let back = try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e))
    eq(back, e); eq(back.segments.map(\.joinEnd), [true, nil]); eq(back.segments.map(\.joinStart), [nil, true])
    let text = String(data: try JSONEncoder().encode(Edits(segments: [seg("y", "zoom", 1, 3)])), encoding: .utf8)!
    expect(!text.contains("join"), "an unjoined segment writes no join keys: \(text)")
    eq(try decode("{ \"segments\": [{ \"id\": \"z\", \"kind\": \"zoom\", \"start\": 1, \"end\": 2, \"level\": 2 }] }").segments[0].joinStart, nil)
    var moved = e
    moved.segments[1].start = 2.5; moved.segments[1].end = 3.5
    let map = TimeMap(duration: 10, edits: moved)
    eq(moved.looseJoins(map: map), ["zoom z: joinEnd, but no zoom on its lane starts where it ends with joinStart",
                                    "zoom z-2: joinStart, but no zoom on its lane ends where it starts with joinEnd"])
    moved.dropLooseJoins(map: map)
    eq(moved.segments.map(\.joinEnd), [nil, nil]); eq(moved.segments.map(\.joinStart), [nil, nil])
    var lane = e
    lane.segments[1].lane = 1
    lane.dropLooseJoins(map: map)
    eq(lane.segments[0].joinEnd, nil, "another lane is no longer joined")
}

print("editor")

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("exact-studio-model-\(getpid())")
defer { try? FileManager.default.removeItem(at: scratch) }
Library.scratch = scratch
Settings.isolate(in: scratch)
Pictures.mayAsk = false
let video = scratch.appendingPathComponent("capture.mov")
try FileManager.default.createDirectory(at: Library.recordings, withIntermediateDirectories: true)
try makeVideo(video, seconds: 10)
var opened = 0

func open(_ fixture: String, edits: String? = nil, look: String? = nil) -> Editor {
    opened += 1
    let id = "\(fixture)-\(opened)"
    let folder = Library.recordings.appendingPathComponent(id)
    try! FileManager.default.copyItem(at: fixtures.appendingPathComponent("valid/\(fixture)"), to: folder)
    for (dir, file) in [("images", "logo.png"), ("sounds", "beep.wav")] {
        try! FileManager.default.createDirectory(at: folder.appendingPathComponent(dir), withIntermediateDirectories: true)
        try! FileManager.default.copyItem(at: fixtures.appendingPathComponent("media/\(file)"), to: folder.appendingPathComponent("\(dir)/\(file)"))
    }
    try! FileManager.default.copyItem(at: video, to: folder.appendingPathComponent("capture.mov"))
    var meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as! [String: Any]
    meta["id"] = id
    try! JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
    if let edits { try! Data(edits.utf8).write(to: folder.appendingPathComponent("edits.json")) }
    if let look { try! Data(look.utf8).write(to: folder.appendingPathComponent("look.json")) }
    Settings.store.removeObject(forKey: Settings.foldedKey)
    let e = Editor(id: id)!
    expect(wait { e.player.currentItem?.status == .readyToPlay }, "the player never got ready")
    return e
}

func at(_ e: Editor, _ t: Double) {
    e.seek(source: t)
    expect(wait { abs(e.playhead - t) < 0.01 }, "the playhead never reached \(t) (at \(e.playhead))")
}

func onDisk(_ e: Editor) -> Edits { try! JSONDecoder().decode(Edits.self, from: Data(contentsOf: e.folder.appendingPathComponent("edits.json"))) }

test("split the clip at the playhead, remove the part, put it back, join it") {
    let e = open("empty")
    near(e.duration, 10, within: 0.11)
    at(e, 4)
    e.splitClip()
    eq(e.edits.splits, [4]); eq(e.selected, "p:4000"); eq(onDisk(e).splits, [4], "saved")
    at(e, 4)
    e.splitClip()
    eq(e.problem, "The clip is already split there.")
    e.toggleRemoved()
    eq(e.edits.removed, [4]); eq(e.summary["removed"] as? Int, 1)
    e.toggleRemoved()
    eq(e.edits.removed, [])
    e.join(-1)
    eq(e.edits.splits, []); eq(e.selected, "p:0")
}

test("removed parts: the last kept part stays, and the video gets shorter") {
    let e = open("empty")
    at(e, 5); e.splitClip()
    at(e, 7); e.splitClip()
    e.select("p:5000"); e.toggleRemoved()
    eq(e.edits.removed, [5]); near(e.summary["length"] as? Double ?? 0, 8, within: 0.11)
    e.select("p:7000"); e.toggleRemoved()
    e.select("p:0"); e.toggleRemoved()
    eq(e.problem, "Keep one clip part. The video needs at least one kept part.")
    eq(e.edits.removed.sorted(), [5, 7])
    e.select("p:5000"); e.join(1)
    eq(e.edits.splits, [5]); eq(e.edits.removed, [5], "joining two removed parts keeps the whole removed")
    at(e, 0.01); e.splitClip()
    eq(e.problem, "Move the playhead into the clip to split it.")
}

test("a transition is kept by the kept part's end") {
    let e = open("empty")
    at(e, 3); e.splitClip()
    at(e, 5); e.splitClip()
    e.select("p:3000"); e.toggleRemoved()
    e.select("p:0"); e.setTransition("crossfade")
    eq(e.edits.transitions, ["3000": "crossfade"]); eq(e.selection["transition"] as? String, "crossfade")
    e.setTransition("cut")
    eq(e.edits.transitions, [:])
}

test("add a zoom at the playhead; a second zoom there is refused; one before it fills the gap") {
    let e = open("empty")
    at(e, 1); e.add("zoom-in")
    let z = e.selectedSegment
    eq(z?.kind, "zoom"); eq(z?.level, 2); near(z?.start ?? -1, 1); near(z?.end ?? -1, 4)
    at(e, 2); e.add("zoom-out")
    eq(e.refusal?.rule, "room-at-playhead")
    eq(e.problem, "One zoom at a time. Zoom in 2× runs here until 0:04.0. Move the playhead past it.")
    eq(e.edits.zooms.count, 1)
    at(e, 0.5); e.add("zoom-out")
    eq(e.edits.zooms.count, 2); near(e.selectedSegment?.end ?? -1, 1, "it stops at the next zoom"); eq(e.selectedSegment?.level, 0.7)
    at(e, 0.8); e.add("fast")
    eq(e.edits.speeds.count, 1); eq(e.selectedSegment?.lane, 1, "a speed under a zoom takes the next lane"); eq(e.edits.lanes, 2)
}

test("texts stack on new text lanes; a whole-frame blur goes to its own row, and never over a video blur (P2)") {
    let e = open("empty")
    at(e, 2); e.add("text"); e.add("text")
    eq(e.edits.texts.map(\.lane), [0, 1]); eq(e.edits.textLanes, 2)
    eq(e.selectedSegment?.text, "Your text here")
    e.add("blur"); e.add("blur-frame")
    eq(e.edits.segments.filter { $0.kind == "blur" }.map(\.space), [0], "refused: one blur at a time")
    eq(e.refusal?.rule, "room-at-playhead")
    at(e, 6); e.add("blur-frame")
    eq(e.edits.segments.filter { $0.kind == "blur" }.map(\.space), [0, 3]); eq(e.edits.frameLanes, 1)
    e.add("mask")
    let m = e.selectedSegment
    eq(m?.kind, "mask"); eq(m?.style, "blur"); expect(m?.rect != nil, "a mask has its rect")
}

test("a drag that makes two zooms overlap is put back, and says why") {
    let e = open("empty")
    at(e, 1); e.add("zoom-in")
    at(e, 6); e.add("zoom-in")
    let id = e.selected
    e.drag(id, start: 3, end: 6, lane: 1)
    e.endDrag()
    eq(e.problem, "One zoom at a time. Zoom in 2× runs to 0:04.0. Start it at 0:04.0 or later.")
    near(e.selectedSegment?.start ?? -1, 6, "back where it was"); eq(e.edits.lanes, 1)
    e.drag(id, start: 4.5, end: 7.5, lane: 1)
    e.endDrag()
    eq(e.problem, ""); eq(e.selectedSegment?.lane, 1); eq(e.edits.lanes, 2, "a drop one past the last lane opens it")
}

test("typed times are checked; delete removes the selection") {
    let e = open("empty")
    at(e, 1); e.add("spotlight")
    e.setTimes(start: 3, end: 3.05)
    eq(e.refusal?.rule, "min-length")
    eq(e.problem, "Too short. An item lasts at least 0.1 s, inside 0:00–\(Rules.clock(e.duration, up: false)).")
    e.setTimes(start: 2, end: 5)
    near(e.selectedSegment?.start ?? -1, 2); near(e.selectedSegment?.end ?? -1, 5)
    at(e, 3); e.split()
    eq(e.edits.effects.count, 2)
    e.deleteSelected()
    eq(e.edits.effects.count, 1); eq(e.selected, "")
}

test("a template replaces the texts, effects and moves, keeps the cuts, speed changes, images and masks; undo puts them back") {
    for info in Templates.all where info.shortest <= 9.4 {
        let e = open("full")
        let before = e.edits
        e.applyTemplate(info.name)
        eq(e.undoName, "Template", info.name)
        expect(e.edits != before, "\(info.name) changed nothing")
        eq(e.edits.splits, before.splits); eq(e.edits.removed, before.removed); eq(e.edits.three, before.three)
        eq(e.edits.speeds.map { [$0.start, $0.end, $0.rate ?? 0] }, before.speeds.map { [$0.start, $0.end, $0.rate ?? 0] }, "\(info.name) keeps the speed changes"); expect(!before.speeds.isEmpty, "full has a speed change")
        eq(e.edits.images.map(\.id), ["img"]); eq(e.edits.masks.map(\.id).sorted(), ["mask1", "mask2"])
        expect(!e.edits.texts.contains { $0.id == "txt" }, "\(info.name): the old text stayed")
        eq(e.problem, "")
        eq(e.selectedSegment?.isPlaceholder ?? false, info.placeholders, "\(info.name): the first line to fill is selected")
        e.undo()
        eq(e.edits, before, info.name); eq(onDisk(e), before, "\(info.name) saved"); eq(e.undoName, ""); eq(e.redoName, "Template")
        e.redo()
        e.undo()
        eq(e.edits, before, "\(info.name) after redo and undo")
    }
    let e = open("full")
    let before = e.edits
    e.applyTemplate("launch")
    eq(e.problem, "Product Launch needs a video at least 10 s long.")
    eq(e.edits, before)
    e.applyTemplate("nope")
    eq(e.edits, before)
}

test("unfilled lists the [bracketed] texts by time, and nothing else; a broken rule is not one") {
    var e = Edits()
    var late = seg("late", "text", 6, 8); late.text = "2. [What to do]"
    var early = seg("early", "text", 1.2, 3); early.text = "[Product name]"
    var filled = seg("filled", "text", 3, 5, lane: 1); filled.text = "Export in one click"
    var square = seg("square", "text", 4, 5, lane: 2); square.text = "a [ alone"
    e.segments = [late, seg("z1", "zoom", 1, 3), seg("z2", "zoom", 2, 4), early, filled, square]
    e.fitLanes()
    eq(e.unfilled.map(\.id), ["early", "late"])
    expect(!e.conflicts(map: TimeMap(duration: 10, edits: e)).isEmpty, "the overlapping zooms break a rule")
    e.segments.removeAll { $0.kind == "text" && $0.id != "filled" }
    eq(e.unfilled.map(\.id), [])
}

test("the app's export refuses unfilled lines, lists them, shows the first, and exports once it is written") {
    let e = open("full")
    e.applyTemplate("social")
    eq(e.exportCheck["count"] as? Int, 1)
    eq(e.exportCheck["lines"] as? [String], ["0:00.2 [Hook line]"])
    eq(e.exportCheck["why"] as? String, "1 line still in brackets. Write it or delete it, then export.")
    do { _ = try e.exportable(look: e.look); expect(false, "it exported an unfilled line") }
    catch { eq("\(error)", "1 line still in brackets. Write it or delete it, then export.") }
    e.select("")
    e.showFirstUnfilled()
    eq(e.selected, e.edits.unfilled.first?.id ?? "-")
    e.setText("text", "Recording, framed for you")
    eq(e.exportCheck["count"] as? Int, 0)
    eq(e.exportCheck["first"] as? String, "")
    expect((try? e.exportable(look: e.look)) != nil, "it refused a filled template")
}

test("a broken rule the app tolerates does not stop its export") {
    let e = open("full", edits: #"{"segments":[{"id":"a","kind":"zoom","start":1,"end":3,"lane":0,"level":2},{"id":"b","kind":"zoom","start":2,"end":4,"lane":0,"level":2}]}"#)
    expect(!e.edits.conflicts(map: e.map).isEmpty, "the zooms overlap")
    eq(e.exportCheck["count"] as? Int, 0)
    expect((try? e.exportable(look: e.look)) != nil, "a tolerated rule break stopped the export")
}

test("every edit is one undo step, named for the Edit menu; redo walks forward again") {
    let e = open("empty")
    let start = e.edits
    at(e, 4); e.splitClip()
    eq(e.undoName, "Split Clip")
    e.toggleRemoved()
    eq(e.undoName, "Remove Part")
    at(e, 1); e.add("zoom-in")
    eq(e.undoName, "Add Zoom")
    let id = e.selectedSegment!.id, length = e.selectedSegment!.end - e.selectedSegment!.start
    e.drag(id, start: 1.5, end: 1.5 + length, lane: 0); e.drag(id, start: 2, end: 2 + length, lane: 0); e.endDrag()
    eq(e.undoName, "Move Zoom")
    let full = e.edits
    e.undo(); eq(e.edits.zooms.first?.start, 1, "the whole drag is one step")
    e.undo(); eq(e.edits.zooms.count, 0)
    eq(e.selected, "", "a selection that is gone is dropped")
    e.undo(); eq(e.edits.removed, [])
    e.undo(); eq(e.edits, start); eq(onDisk(e), start, "saved")
    eq(e.undoName, ""); eq(e.redoName, "Split Clip")
    e.undo(); eq(e.edits, start, "nothing more to undo")
    e.redo(); e.redo(); e.redo(); e.redo()
    eq(e.edits, full); eq(onDisk(e), full, "saved"); eq(e.redoName, "")
    e.undo(); e.setLookField("shadow", e.look.shadow ? "false" : "true")
    eq(e.redoName, "", "a new edit drops what could be redone")
}

test("a slider scrub is one step; a refused edit is none") {
    let e = open("empty")
    let padding = e.look.padding
    for v in stride(from: 10, through: 30, by: 2) { e.setLookField("padding", "\(v)") }
    eq(e.undoName, "Padding")
    e.setLookField("background", "sunset")
    eq(e.undoName, "Background")
    e.undo(); e.undo()
    eq(e.look.padding, padding, "the whole scrub")
    at(e, 1); e.add("zoom-in"); e.add("zoom-in")
    expect(e.problem != "", "the second zoom is refused")
    eq(e.undoName, "Add Zoom"); e.undo(); eq(e.edits.zooms.count, 0)
}

test("Clear Edits, a crop and an edit made on disk each undo as one step") {
    let e = open("full")
    let before = e.edits
    e.clearAll()
    eq(e.undoName, "Clear Edits"); e.undo(); eq(e.edits, before)
    let crop = e.meta.crop
    e.setCrop(UnitRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5))
    eq(e.undoName, "Crop"); e.undo(); eq(e.meta.crop, crop)
    eq(Library.meta(e.id)?.crop, crop, "saved")
    var next = before
    next.splits = [5]
    try JSONEncoder().encode(next).write(to: e.folder.appendingPathComponent("edits.json"))
    expect(wait(4) { e.edits.splits == [5] }, "the editor never read the file")
    eq(e.undoName, "Edit from File")
    e.undo()
    eq(e.edits, before); eq(onDisk(e), before, "written back")
    expect(!wait(1.2) { e.edits.splits == [5] }, "its own write read back as a change")
    eq(e.redoName, "Edit from File")
}

test("each recording has its own history") {
    let a = open("empty"), b = open("empty")
    at(a, 1); a.add("zoom-in")
    eq(b.undoName, "")
    b.undo(); eq(a.edits.zooms.count, 1)
}

test("lanes: add one, delete one with what it holds, never the last effect lane") {
    let e = open("empty")
    e.addLane(); eq(e.edits.lanes, 2)
    e.addLane(space: 1); eq(e.edits.textLanes, 1)
    e.deleteLane(1, space: 0); eq(e.edits.lanes, 1)
    e.deleteLane(0, space: 0); eq(e.edits.lanes, 1, "the last effect lane")
    at(e, 1); e.add("text")
    e.deleteLane(0, space: 1); eq(e.edits.textLanes, 0); eq(e.edits.texts.count, 0, "its text went with it")
}

func menu(_ row: TimelineRow, _ e: Editor) -> [MenuEntry] {
    if case let .menu(entries)? = TimelineMenus.plus(row, e) { return entries }
    problems.append("\(row) has no + menu")
    return []
}

test("a + menu holds items only, grouped, under a line that says where they land and what they change") {
    let e = open("empty")
    at(e, 1)
    let effects = menu(.lane(0, 0), e)
    eq(effects.titles, ["Add to Effects 1 at 0:01.0 · Changes the video only"])
    eq(effects.choices, ["Zoom › Zoom In", "Zoom › Zoom Out", "Zoom › Zoom on Clicks", "Speed › Slow Down", "Speed › Speed Up",
                         "Look › Spotlight", "Look › Cursor Highlight", "Look › Blur", "Look › Black & White", "Mask", "3D Turn"])
    eq(menu(.header("top"), e).choices, ["Text", "Image…"])
    eq(menu(.header("frame"), e).choices, ["Blur", "Black & White"])
    eq(menu(.position, e).choices.count, 11)
    eq(menu(.position, e).titles, ["Move the video at 0:01.0", "Then drag the video where it should go."])
    for row in [TimelineRow.lane(0, 0), .header("top"), .header("frame"), .position] {
        expect(!menu(row, e).choices.contains { $0.contains("Lane") }, "\(row)'s + offers a lane")
    }
    guard case .direct? = TimelineMenus.plus(.header("sound"), e) else { return problems.append("the Sound +, with one choice, should add at once") }
    expect(TimelineMenus.plus(.lane(1, 0), e) == nil, "a lane that does not exist has no +")
}

test("a lane's + adds on that lane; with no room there, on the first free lane of its kind, else a new one") {
    let e = open("empty")
    e.addLane()
    at(e, 1)
    expect(menu(.lane(0, 1), e).run("Zoom › Zoom In"), "Zoom In is in the Zoom submenu")
    eq(e.edits.zooms.first?.lane, 1, "on the lane whose + it was")
    menu(.lane(0, 1), e).run("Look › Blur")
    eq(e.edits.segments.first { $0.kind == "blur" }?.lane, 0, "no room on lane 2, so the first free lane")
    menu(.header("top"), e).run("Text")
    eq(e.edits.textLanes, 1)
    guard case let .direct(add)? = TimelineMenus.plus(.lane(1, 0), e) else { return problems.append("a text lane's + adds a text at once") }
    add()
    eq(e.edits.texts.count, 2)
    eq(e.edits.textLanes, 2, "the text lane was taken, so a new lane")
    eq(e.undoName, "Add Text")
}

test("a lane's ⋯ makes lanes above and below and moves it up and down; each is one undo step") {
    let e = open("empty")
    at(e, 1)
    menu(.header("top"), e).run("Text")
    let lanes = { TimelineMenus.lane(1, $0, e) { _, _, run in run() } }
    eq(lanes(0).titles, ["Text 1 · Sits on top of the video"])
    eq(lanes(0).choices, ["New Text Lane Above", "New Text Lane Below", "Move Lane Up", "Move Lane Down", "Delete Lane and Its 1 Text…"])
    expect(!lanes(0).run("Move Lane Up"), "the top lane can't move up")
    lanes(0).run("New Text Lane Above")
    eq(e.edits.textLanes, 2); eq(e.edits.texts.first?.lane, 1, "the text moved down with its lane")
    eq(e.undoName, "New Text Lane")
    lanes(1).run("Move Lane Up")
    eq(e.edits.texts.first?.lane, 0, "lane order is draw order, so the text moves with its lane")
    eq(e.undoName, "Move Lane Up")
    lanes(0).run("New Text Lane Below")
    eq(e.edits.textLanes, 3); eq(e.edits.texts.first?.lane, 0)
    e.undo(); e.undo()
    eq(e.edits.texts.first?.lane, 1); eq(e.edits.textLanes, 2)
    eq(TimelineMenus.group("top", e).choices, ["New Text Lane", "New Image Lane"])
    eq(TimelineMenus.group("sound", e).choices, ["New Sound Lane"])
    TimelineMenus.group("frame", e).run("New Whole Frame Lane")
    eq(e.edits.frameLanes, 1)
}

test("Delete Lane says what goes with it, asks when it holds items, and never takes the last Effects lane") {
    let e = open("empty")
    eq(TimelineMenus.lane(0, 0, e) { _, _, run in run() }.reason("Delete Lane"), "One Effects lane stays.\nIt is the last one.")
    at(e, 1); e.add("zoom-in")
    e.addLane()
    eq(TimelineMenus.lane(0, 1, e) { _, _, _ in }.choices.last, "Delete Lane", "an empty lane goes at once")
    var question = ""
    let first = TimelineMenus.lane(0, 0, e) { title, _, run in question = title; run() }
    eq(first.choices.last, "Delete Lane and Its 1 Effect…")
    first.run("Delete Lane and Its 1 Effect…")
    eq(question, "Delete Effects 1 and its 1 effect?")
    eq(e.edits.lanes, 1); eq(e.edits.zooms.count, 0)
    eq(e.undoName, "Delete Lane")
    e.undo()
    eq(e.edits.lanes, 2); eq(e.edits.zooms.first?.lane, 0)
    let declined = TimelineMenus.lane(0, 0, e) { _, _, _ in }
    declined.run("Delete Lane and Its 1 Effect…")
    eq(e.edits.zooms.count, 1, "Cancel keeps it")
}

test("a blur's reach moves it between the video's lanes and the whole frame's") {
    let e = open("empty")
    at(e, 1); e.add("blur")
    e.setSegment("scope", "frame")
    eq(e.selectedSegment?.space, 3); eq(e.edits.frameLanes, 1)
    e.setSegment("scope", "video")
    eq(e.selectedSegment?.space, 0)
}

test("every reach of a blur or black and white sits on its own lanes; no scope, or an unknown one, is the video's") {
    for (scope, space) in [(nil, 0), ("video", 0), ("background", 3), ("scene", 3), ("frame", 3), ("all", 3), ("nonsense", 0)] as [(String?, Int)] {
        for kind in ["blur", "mono"] {
            var s = seg("b", kind, 1, 3)
            s.scope = scope
            eq(s.space, space, "\(kind) \(scope ?? "none")")
            eq(s.coversFrame, space == 3, "\(kind) \(scope ?? "none")")
        }
    }
    var spot = seg("s", "spotlight", 1, 3)
    spot.scope = "scene"
    eq(spot.space, 0, "a spotlight has no reach")
    eq(Segment.scopes, ["video", "background", "scene", "frame", "all"])
}

test("the inspector's reach: each value lands on its lanes; a spotlight drops it; a text never takes one") {
    let e = open("empty")
    at(e, 1); e.add("mono")
    for (scope, space) in [("background", 3), ("scene", 3), ("frame", 3), ("all", 3), ("video", 0)] {
        e.setSegment("scope", scope)
        eq(e.selectedSegment?.scope, scope == "video" ? nil : scope); eq(e.selectedSegment?.space, space, scope)
    }
    e.setSegment("scope", "nonsense")
    eq(e.selectedSegment?.scope, nil, "an unknown reach is ignored")
    e.setSegment("scope", "scene")
    e.setValue(number: nil, kind: "spotlight")
    eq(e.selectedSegment?.kind, "spotlight"); eq(e.selectedSegment?.scope, nil); eq(e.selectedSegment?.space, 0)
    eq(e.selection["scope"] as? String, "video")
}

/// A picture of red and green squares, sharp and colourful, written to `url`.
func checkerPicture(_ url: URL) throws {
    let c = CIFilter.checkerboardGenerator()
    c.width = 8; c.color0 = CIColor(red: 0.95, green: 0.1, blue: 0.1); c.color1 = CIColor(red: 0.1, green: 0.85, blue: 0.2)
    let img = c.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let cg = CIContext().createCGImage(img, from: img.extent)!
    let rep = NSBitmapImageRep(cgImage: cg)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// What one reach covers, rendered: the frame at 3 s with a blur or black and white of `scope` from 1 s to 5 s,
/// and the same frame without it, in four regions: the background, the video, an image and a text.
struct Reach {
    let base: [UInt8], with: [UInt8], width: Int, height: Int
    let regions: [String: CGRect]
    /// Over a text, only its letters count: the picture shows between them. They are pink, which nothing else is.
    func letter(_ o: Int) -> Bool { base[o] > 245 && abs(Int(base[o + 1]) - 69) < 6 && abs(Int(base[o + 2]) - 140) < 6 }
    func change(_ name: String) -> (mean: Double, most: Int) {
        let r = regions[name]!
        var sum = 0, most = 0, n = 0
        for y in Int(r.minY * Double(height))..<Int(r.maxY * Double(height)) { for x in Int(r.minX * Double(width))..<Int(r.maxX * Double(width)) {
            if name == "text", !letter((y * width + x) * 4) { continue }
            for k in 0..<3 { let o = (y * width + x) * 4 + k; let d = abs(Int(base[o]) - Int(with[o])); sum += d; most = max(most, d); n += 1 }
        } }
        return (Double(sum) / Double(max(n, 1)), most)
    }
    /// How sharp a region is: the mean step between neighbouring pixels.
    func sharpness(_ name: String, effect: Bool) -> Double {
        let px = effect ? with : base, r = regions[name]!
        var sum = 0, n = 0
        for y in Int(r.minY * Double(height))..<Int(r.maxY * Double(height)) { for x in Int(r.minX * Double(width))..<(Int(r.maxX * Double(width)) - 1) {
            let o = (y * width + x) * 4
            sum += abs(Int(px[o]) - Int(px[o + 4])) + abs(Int(px[o + 1]) - Int(px[o + 5])); n += 1
        } }
        return Double(sum) / Double(max(n, 1))
    }
}

let reachFolder = scratch.appendingPathComponent("reach")
func reach(_ kind: String, _ scope: String?, textEffect: String? = nil) throws -> Reach {
    try FileManager.default.createDirectory(at: reachFolder, withIntermediateDirectories: true)
    let pic = reachFolder.appendingPathComponent("pic.png")
    if !FileManager.default.fileExists(atPath: pic.path) { try checkerPicture(pic) }
    let meta = try JSONDecoder().decode(RecordingMeta.self, from: Data("""
    {"id":"r","name":"r","kind":"area","created":0,"duration":10,"width":1600,"height":1000,
     "crop":{"x":0,"y":0,"w":1,"h":1},"clicks":[],"cursorBaked":true}
    """.utf8))
    var look = Look()
    look.shadow = false; look.radius = 0; look.background = "custom"; look.customA = "#E0302A"; look.customB = "#2A60E0"
    var image = seg("i", "image", 0, 10)
    image.file = "pic.png"; image.x = 0.3; image.y = 0.5; image.size = 0.25; image.animIn = "none"; image.animOut = "none"
    var text = seg("t", "text", 0, 10)
    text.text = "WORDS"; text.x = 0.7; text.y = 0.5; text.size = 0.12; text.color = "pink"; text.weight = "heavy"; text.style = "plain"
    text.animIn = "none"; text.animOut = "none"
    if let k = textEffect { text.effects = [Segment(id: "tx", kind: k, start: 1, end: 5)] }
    var plain = Edits(segments: [image, text])
    plain.textLanes = 1; plain.imageLanes = 1
    var covered = plain
    if textEffect == nil {
        var fx = seg("fx", kind, 1, 5)
        fx.scope = scope
        covered.segments.append(fx)
        covered.fitLanes()
    } else {
        plain.segments[1].effects = nil
    }
    let checker = CIFilter.checkerboardGenerator()
    checker.width = 10; checker.color0 = CIColor(red: 0.95, green: 0.6, blue: 0.1); checker.color1 = CIColor(red: 0.1, green: 0.3, blue: 0.9)
    let frame = checker.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    let a = Framing(meta: meta, look: look, edits: plain, cursor: [], folder: reachFolder)
    let b = Framing(meta: meta, look: look, edits: covered, cursor: [], folder: reachFolder)
    let tf = a.textFrame(text)
    let words = CGRect(x: tf.x + tf.w * 0.15, y: tf.y + tf.h * 0.25, width: tf.w * 0.7, height: tf.h * 0.5)
    let context = CIContext(options: [.cacheIntermediates: false])
    func pixels(_ f: Framing) -> [UInt8] {
        let w = Int(f.canvas.width), h = Int(f.canvas.height)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        context.render(f.render(frame, at: 3), toBitmap: &out, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return out
    }
    return Reach(base: pixels(a), with: pixels(b), width: Int(a.canvas.width), height: Int(a.canvas.height),
                 regions: ["background": CGRect(x: 0.01, y: 0.3, width: 0.08, height: 0.4), "video": CGRect(x: 0.45, y: 0.14, width: 0.1, height: 0.14),
                           "image": CGRect(x: 0.25, y: 0.4, width: 0.1, height: 0.2), "text": words])
}

test("each reach covers what it says, front to back: background, video, images, texts") {
    let layers = ["background", "video", "image", "text"]
    let covers: [(String?, Set<String>)] = [(nil, ["video"]), ("background", ["background"]), ("scene", ["background", "video"]),
                                           ("frame", ["background", "video", "image"]), ("all", ["background", "video", "image", "text"])]
    for (scope, reached) in covers {
        for kind in ["blur", "mono"] {
            let r = try reach(kind, scope)
            for layer in layers {
                let c = r.change(layer)
                let name = "\(kind) \(scope ?? "video only"), \(layer)"
                // A gradient background barely changes under a blur; the black and white shows its reach.
                if kind == "blur" && layer == "background" { if !reached.contains(layer) { expect(c.most <= 1, "\(name): changed by up to \(c.most)") }; continue }
                if reached.contains(layer) { expect(c.mean > 3, "\(name): only \(c.mean) on average, so it is not covered") }
                // A letter's soft edge keeps a trace of what is under it, so a text counts on average.
                else if layer == "text" { expect(c.mean < 0.5, "\(name): changed by \(c.mean) on average, so it is covered") }
                else { expect(c.most <= 2, "\(name): changed by up to \(c.most), so it is covered") }
            }
            if kind == "blur" {
                for layer in ["image"] where reached.contains(layer) {
                    expect(r.sharpness(layer, effect: true) < r.sharpness(layer, effect: false) * 0.8, "\(scope ?? "") blurs the \(layer)")
                }
            }
        }
    }
}

test("a text's own blur, black and white and fade change that text only") {
    for kind in ["blur", "mono", "fade"] {
        let r = try reach("", nil, textEffect: kind)
        expect(r.change("text").mean > 3, "\(kind): the text did not change")
        for layer in ["background", "video", "image"] { expect(r.change(layer).most <= 1, "\(kind) on the text changed the \(layer)") }
    }
}

test("a text's own effects: added from its + and its inspector, saved, undone, split with it; the rules an image's follow") {
    let e = open("full")
    at(e, 1)
    e.select("txt")
    let plus = TimelineMenus.plus(.imageEffects("txt", 0), e)
    guard case let .menu(entries)? = plus else { return expect(false, "the text's Effects row has no + menu") }
    eq(entries.choices, ["Blur", "Black & White", "Fade"])
    expect(entries.titles.first?.contains("Changes this text only") == true, "\(entries.titles)")
    entries.run("Blur")
    eq(e.edits.texts.first?.effects?.map(\.kind), ["blur"]); eq(onDisk(e).texts.first?.effects?.map(\.kind), ["blur"], "saved")
    eq(e.undoName, "Add Text Effect")
    expect(e.selected.hasPrefix("ie:txt:"), e.selected)
    eq(e.selection["kind"] as? String, "ifx"); eq(e.selection["file"] as? String, "“Hello”")
    eq(e.selectedImage?.id, nil, "a text's effect is not an image's"); eq(e.selectedItem?.id, "txt")
    expect(e.isOpen(space: 1, lane: 0), "selecting it opens the text's lane")
    e.select("txt")
    e.setText("add-effect", "mono")
    eq(e.edits.texts.first?.effects?.map(\.kind), ["blur", "mono"])
    e.setText("add-effect", "pulse")
    eq(e.edits.texts.first?.effects?.count, 2, "a text has no pulse")
    e.undo(); e.undo()
    eq(e.edits.texts.first?.effects, nil); eq(onDisk(e).texts.first?.effects, nil)
    e.redo()
    eq(e.edits.texts.first?.effects?.map(\.kind), ["blur"])
    var t = e.edits.texts.first!
    t.effects = [Segment(id: "a", kind: "blur", start: 0.6, end: 2), Segment(id: "b", kind: "blur", start: 1, end: 2.4, lane: 1)]
    eq(Edits.conflict(in: t)?.rule, "text-one-each")
    t.effects = [Segment(id: "a", kind: "pulse", start: 0.6, end: 2)]
    eq(Edits.conflict(in: t)?.text, "No such text effect. A text takes blur, mono or fade.")
    t.effects = [Segment(id: "a", kind: "fade", start: 0.1, end: 2)]
    eq(Edits.conflict(in: t)?.rule, "text-inside")
    e.select("txt")
    at(e, 1.5)
    e.split()
    let halves = e.edits.texts.sorted { $0.start < $1.start }
    eq(halves.count, 2); eq(halves.map { $0.effects?.count ?? 0 }.reduce(0, +), 2, "its effect is cut with it")
    eq(TimelineView.chips(halves[0]), ["Blur"])
}

test("a blur's block says its reach") {
    for (scope, words) in [(nil, "Blur · video"), ("background", "Blur · background"), ("scene", "Blur · video, background"),
                           ("frame", "Blur · whole frame"), ("all", "Blur · everything")] as [(String?, String)] {
        var s = seg("b", "blur", 1, 3)
        s.scope = scope
        eq(TimelineView.caption(s), words)
    }
    var m = seg("m", "mono", 1, 3)
    m.scope = "scene"
    eq(TimelineView.caption(m), "Black & white · video, background")
}

test("an image: added from a file, given effects of its own, a same effect twice refused") {
    let e = open("empty")
    at(e, 1)
    e.addImage(fixtures.appendingPathComponent("media/logo.png"))
    let image = e.selectedSegment
    eq(image?.kind, "image"); eq(image?.lane, 0); eq(e.edits.imageLanes, 1)
    expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent(image?.file ?? "x").path), "the picture was copied in")
    e.addItemEffect("pulse")
    eq(e.edits.images.first?.effects?.map(\.kind), ["pulse"])
    e.select(image!.id)
    e.addImageMove()
    eq(e.edits.images.first?.moves?.count, 1)
}

test("clear all empties the edit; Zoom on Clicks adds a zoom per click group") {
    let e = open("full")
    e.clearAll()
    eq(e.edits, Edits())
    e.autoZoom()
    eq(e.edits.zooms.count, 2)
}

test("an edit made on disk shows in the open editor") {
    let e = open("empty")
    var next = Edits(segments: [seg("z", "zoom", 1, 2)])
    next.splits = [5]
    try JSONEncoder().encode(next).write(to: e.folder.appendingPathComponent("edits.json"))
    expect(wait(4) { e.edits.splits == [5] }, "the editor never read the file")
    eq(e.edits.zooms.map(\.id), ["z"])
}

test("a file without lanes, styles or durations opens as written, and the next change keeps it") {
    let e = open("empty", edits: """
    { "segments": [{ "id": "z", "kind": "zoom", "start": 1, "end": 2, "level": 2 }], "moves": [{ "id": "m", "t": 3, "to": { "x": 0.3 } }] }
    """)
    eq(e.unreadable, [:]); eq(e.edits.zooms.map(\.id), ["z"]); eq(e.edits.moves.map(\.style), ["smooth"])
    at(e, 5); e.splitClip()
    eq(onDisk(e).zooms.map(\.id), ["z"], "saved with the zoom"); eq(onDisk(e).moves.first?.to.x, 0.3)
}

test("an edits.json the app can't read is never saved over; fixed on disk, it opens and saves again") {
    let bad = "{ \"lanes\": \"two\", \"splits\": [3] }"
    let e = open("empty", edits: bad)
    let file = e.folder.appendingPathComponent("edits.json")
    expect(e.unreadable["edits.json"]?.hasPrefix("edits.json can’t be read (lanes: Expected to decode Int") == true, "\(e.unreadable)")
    eq(e.selection["problem"] as? String, e.unreadable["edits.json"], "the inspector shows it")
    at(e, 1); e.add("zoom-in"); e.splitClip(); e.setVolume(0.5); e.autoZoom(); e.clearAll(); e.addLane()
    eq(e.problem, e.unreadable["edits.json"]); eq(e.edits, Edits())
    eq(try String(contentsOf: file, encoding: .utf8), bad, "the file is untouched")
    e.select("p:0")
    eq(e.selection["problem"] as? String, e.unreadable["edits.json"], "selecting does not hide it")
    try Data("{ \"splits\": [5] }".utf8).write(to: file)
    expect(wait(4) { e.unreadable.isEmpty && e.edits.splits == [5] }, "the editor never read the fixed file")
    eq(e.selection["problem"] as? String, "")
    at(e, 7); e.splitClip()
    eq(onDisk(e).splits, [5, 7], "it saves again")
}

test("a look.json the app can't read is never saved over") {
    let bad = "{ \"padding\": \"lots\" }"
    let e = open("empty", look: bad)
    expect(e.unreadable["look.json"] != nil, "look.json read")
    e.setLookField("padding", "20")
    eq(try String(contentsOf: e.folder.appendingPathComponent("look.json"), encoding: .utf8), bad)
    expect(e.problem.hasPrefix("look.json can’t be read"), e.problem)
    at(e, 1); e.add("zoom-in")
    eq(e.edits.zooms.count, 1, "edits.json is fine, so edits still save")
}

test("the inspector's selection says what is selected") {
    let e = open("full")
    e.select("p:0")
    eq(e.selection["kind"] as? String, "clip"); eq(e.selection["first"] as? Bool, true); eq(e.selection["transition"] as? String, "crossfade")
    e.select("txt")
    eq(e.selection["kind"] as? String, "text"); eq(e.selection["text"] as? String, "Hello"); eq(e.selection["startText"] as? String, "0:00.50")
    e.select("mask1")
    eq(e.selection["color"] as? String, "#FF458C")
    e.select("m:m1")
    eq(e.selection["kind"] as? String, "move"); eq(e.selection["moveStyle"] as? String, "spring")
    eq(e.summary["parts"] as? Int, 4); eq(e.summary["images"] as? Int, 1)
}

test("dragging a landing frame moves where that move lands, as one named undo step") {
    let e = open("full")
    e.setLanding("m1", x: 0.62, y: 0.3, live: true)
    e.setLanding("m1", x: 0.7, y: 0.35, live: true)
    e.setLanding("m1", x: 0.7, y: 0.35, live: false)
    eq(onDisk(e).moves[0].to, Placement(x: 0.7, y: 0.35, scale: 1.1))
    eq(e.undoName, "Move Landing")
    e.undo()
    eq(onDisk(e).moves[0].to, Placement(x: 0.4, y: 0.5, scale: 1.1))
    eq(e.undoName, "")
    e.setLanding("im1", image: "img", x: 0.6, y: 0.4, live: false)
    eq(onDisk(e).segments.first { $0.id == "img" }?.moves?[0].to, Placement(x: 0.6, y: 0.4, scale: 0.5))
    eq(e.undoName, "Move Landing")
}

test("a text or an image with no animation set shows the one it plays: Pop or Fade in, Fade out, Still") {
    let e = open("empty", edits: """
        {"segments": [{"id": "t1", "kind": "text", "start": 1, "end": 3, "text": "Hi"},
                      {"id": "t2", "kind": "text", "start": 1, "end": 3, "text": "Yo", "lane": 1, "animIn": "wobble", "loop": "spin"},
                      {"id": "i1", "kind": "image", "start": 4, "end": 6, "file": "images/logo.png"}],
         "textLanes": 2, "imageLanes": 1}
        """)
    e.select("t1")
    eq(e.selection["animIn"] as? String, "pop"); eq(e.selection["animOut"] as? String, "fade"); eq(e.selection["loop"] as? String, "none")
    e.select("t2")
    eq(e.selection["animIn"] as? String, "none", "an unknown entrance plays none"); eq(e.selection["loop"] as? String, "none")
    e.select("i1")
    eq(e.selection["animIn"] as? String, "fade"); eq(e.selection["animOut"] as? String, "fade")
}

// MARK: Seamless splits, rendered

let renderContext = CIContext(options: [.cacheIntermediates: false])
func pixels(_ f: Framing, _ frame: CIImage, at t: Double) -> [UInt8] {
    let w = Int(f.canvas.width), h = Int(f.canvas.height)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    renderContext.render(f.render(frame, at: t), toBitmap: &out, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return out
}
func differ(_ a: [UInt8], _ b: [UInt8]) -> (most: Int, count: Int) {
    var most = 0, count = 0
    for i in a.indices where a[i] != b[i] { most = max(most, abs(Int(a[i]) - Int(b[i]))); count += 1 }
    return (most, count)
}

test("every split keeps the rendered video the same: zooms, texts with loops, effects, 3D turns, images with moves and effects, masks") {
    let e = open("full")
    var base = e.edits
    var wave = seg("t2", "text", 3, 7.6)
    wave.text = "Wave"; wave.loop = "wave"; wave.animIn = "drop"; wave.animOut = "fall"; wave.y = 0.85; wave.style = "box"
    var turn = seg("hold", "3d", 2.6, 4.2, lane: 2)
    turn.style = "hold"; turn.tilt = 20; turn.turn = -30
    var blur = seg("vb", "blur", 5.6, 7.4, lane: 2)
    blur.scope = nil
    var rounded = base.segments.first { $0.id == "mask1" }!
    rounded.id = "mask3"; rounded.radius = 0.4; rounded.start = 5; rounded.end = 9; rounded.lane = 0; rounded.rect = UnitRect(x: 0.4, y: 0.5, w: 0.3, h: 0.2)
    base.segments += [wave, turn, blur, rounded]
    base.textLanes = 2
    base.three.on = false
    let cuts = [1.3, 2.7, 3.4, 4.5, 6.5, 6.9, 8.7]
    var split = base
    for c in cuts { try split.splitAll(at: c, duration: e.duration, map: TimeMap(duration: e.duration, edits: split)) }
    expect(split.segments.count >= base.segments.count + 12, "only \(split.segments.count - base.segments.count) blocks were cut")
    expect(split.looseJoins(map: TimeMap(duration: e.duration, edits: split)).isEmpty, "\(split.looseJoins(map: TimeMap(duration: e.duration, edits: split)))")
    let checker = CIFilter.checkerboardGenerator()
    checker.width = 12; checker.color0 = CIColor(red: 0.9, green: 0.4, blue: 0.1); checker.color1 = CIColor(red: 0.1, green: 0.3, blue: 0.8)
    let frame = checker.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: e.meta.width, height: e.meta.height))
    let one = Framing(meta: e.meta, look: e.look, edits: base, cursor: e.cursor, folder: e.folder)
    let two = Framing(meta: e.meta, look: e.look, edits: split, cursor: e.cursor, folder: e.folder)
    var naive = split
    naive.segments = naive.segments.map { var s = $0; s.joinStart = nil; s.joinEnd = nil
        s.effects = s.effects?.map { var x = $0; x.joinStart = nil; x.joinEnd = nil; return x }; return s }
    let three = Framing(meta: e.meta, look: e.look, edits: naive, cursor: e.cursor, folder: e.folder)
    let times = cuts.flatMap { c in [-0.3, -0.05, -1.0 / 60, 0, 1.0 / 60, 0.05, 0.3].map { c + $0 } } + stride(from: 0.1, to: 9.9, by: 0.7).map { $0 }
    var naiveDiffers = 0
    for t in times {
        let a = pixels(one, frame, at: t)
        let d = differ(a, pixels(two, frame, at: t))
        expect(d.most <= 1, "at \(t): \(d.count) bytes differ, by up to \(d.most)")
        if cuts.contains(where: { abs($0 - t) < 0.06 }), differ(a, pixels(three, frame, at: t)).most > 8 { naiveDiffers += 1 }
    }
    expect(naiveDiffers >= 6, "without the joins only \(naiveDiffers) frames by a cut changed: the test can't tell")
    base.three.on = true
    split.three.on = true
    let deep = [Framing(meta: e.meta, look: e.look, edits: base, cursor: e.cursor, folder: e.folder),
                Framing(meta: e.meta, look: e.look, edits: split, cursor: e.cursor, folder: e.folder)]
    for t in [2.7, 3.4, 4.2 - 1.0 / 60, 8.7, 8.7 + 1.0 / 60] {
        let d = differ(pixels(deep[0], frame, at: t), pixels(deep[1], frame, at: t))
        expect(d.most <= 1, "in 3D at \(t): \(d.count) bytes differ, by up to \(d.most)")
    }
}

// MARK: Depth

func item(_ id: String, _ kind: String, _ start: Double, _ end: Double, lane: Int = 0, layer: String? = nil, order: Int? = nil) -> Segment {
    var s = seg(id, kind, start, end, lane: lane)
    if kind == "image" { s.file = "images/logo.png" }
    s.layer = layer; s.order = order
    return s
}

test("depth: an old file keeps its stack; layer and order are read, written back, and left out when unset") {
    let old = try decode("""
    {"textLanes":1,"imageLanes":2,"segments":[
      {"id":"a","kind":"image","start":0,"end":5,"lane":1,"file":"x.png"},{"id":"b","kind":"image","start":0,"end":5,"lane":0,"file":"x.png"},
      {"id":"t1","kind":"text","start":0,"end":5,"text":"one"},{"id":"t2","kind":"text","start":0,"end":5,"text":"two"}]}
    """)
    eq(old.overlays(at: 1).map(\.id), ["a", "b", "t1", "t2"], "lane 0 in front, texts over images in list order")
    eq(old.overlays(at: 1, behind: true).map(\.id), [])
    expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("layer"), "no layer is written for an old file")
    expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("order"), "no order is written for an old file")
    var e = old
    e.segments[0].layer = "behind"; e.segments[3].order = -1; e.segments[1].layer = "front"
    let back = try JSONDecoder().decode(Edits.self, from: JSONEncoder().encode(e))
    eq(back, e)
    eq(back.overlays(at: 1).map(\.id), ["b", "t2", "t1"], "a lower order is further back")
    eq(back.overlays(at: 1, behind: true).map(\.id), ["a"])
}

test("arrange: forward and backward step past the next item of its kind that overlaps it; front and back go to the end") {
    var e = Edits(segments: [item("i0", "image", 0, 5, lane: 0), item("i1", "image", 0, 5, lane: 1), item("i2", "image", 6, 9, lane: 1),
                             item("i3", "image", 2, 4, lane: 2)])
    e.imageLanes = 3
    eq(e.depthStack(kind: "image", behind: false).map(\.id), ["i3", "i1", "i2", "i0"])
    let forward = e.arranged("i1", "forward")!
    eq(forward.depthStack(kind: "image", behind: false).map(\.id), ["i3", "i2", "i0", "i1"], "past i2, which it never meets, to in front of i0")
    eq(forward.segments.map(\.order), [2, 3, 1, 0])
    eq(e.arranged("i0", "forward"), nil, "already in front")
    eq(e.arrangeProblem("i0", "front"), "It is already in front of the other images in front of the video.")
    eq(e.arrangeProblem("i2", "forward"), "No other image in front of the video shows at the same time.")
    eq(e.arranged("i0", "back")!.depthStack(kind: "image", behind: false).map(\.id), ["i0", "i3", "i1", "i2"])
    eq(e.arranged("i3", "front")!.depthStack(kind: "image", behind: false).map(\.id), ["i1", "i2", "i0", "i3"])
    let backward = forward.arranged("i1", "backward")!
    eq(backward.segments.map(\.order), [nil, nil, nil, nil], "back where it was against everything it meets: the orders go")
    var texts = Edits(segments: [item("t1", "text", 0, 5), item("t2", "text", 1, 4), item("i", "image", 0, 5)])
    texts.textLanes = 2; texts.segments[1].lane = 1; texts.imageLanes = 1
    eq(texts.arranged("t1", "front")!.overlays(at: 2).map(\.id), ["i", "t2", "t1"], "a text moves among the texts; images stay under them")
}

test("arrange: behind the video lands next to it, at the front of the items behind; back in front, at the back of those in front") {
    var e = Edits(segments: [item("a", "image", 0, 5, lane: 0), item("b", "image", 0, 5, lane: 1, layer: "behind"), item("c", "image", 0, 5, lane: 2)])
    e.imageLanes = 3
    let behind = e.arranged("a", "behind")!
    eq(behind.overlays(at: 1, behind: true).map(\.id), ["b", "a"])
    eq(behind.overlays(at: 1).map(\.id), ["c"])
    eq(behind.segments.map(\.lane), [0, 1, 2], "its row stays")
    eq(behind.arrangeProblem("a", "behind"), "It is already behind the video.")
    let front = behind.arranged("b", "in-front")!
    eq(front.overlays(at: 1).map(\.id), ["b", "c"], "just over the video")
    eq(front.segments.first { $0.id == "b" }?.layer, nil, "in front is no layer at all")
    eq(e.arrangeProblem("a", "in-front"), "It is already in front of the video.")
    eq(Edits(segments: [seg("z", "zoom", 0, 2)]).arrangeProblem("z", "behind"), "Only a text or an image has a depth.")
    var halves = item("t", "text", 0, 2), second = item("t-2", "text", 2, 4)
    halves.joinEnd = true; second.joinStart = true
    let joined = Edits(segments: [halves, second]).arranged("t", "behind")!
    eq(joined.segments.map(\.layer), ["behind", "behind"], "a split text goes behind whole")
}

struct Depth {
    let pixels: [UInt8], width: Int, height: Int, video: UnitRect, picture: UnitRect
    func at(_ x: Double, _ y: Double) -> [UInt8] { let o = (Int(y * Double(height)) * width + Int(x * Double(width))) * 4; return Array(pixels[o..<o + 3]) }
}

func depth(layer: String?, picture: Bool = true, base: Placement = Placement(), effect: String? = nil, three: Bool = false) throws -> Depth {
    try FileManager.default.createDirectory(at: reachFolder, withIntermediateDirectories: true)
    let pic = reachFolder.appendingPathComponent("pic.png")
    if !FileManager.default.fileExists(atPath: pic.path) { try checkerPicture(pic) }
    let meta = try JSONDecoder().decode(RecordingMeta.self, from: Data("""
    {"id":"d","name":"d","kind":"area","created":0,"duration":10,"width":1600,"height":1000,
     "crop":{"x":0,"y":0,"w":1,"h":1},"clicks":[],"cursorBaked":true}
    """.utf8))
    var look = Look()
    look.shadow = true; look.radius = 24; look.background = "custom"; look.customA = "#E0302A"; look.customB = "#2A60E0"
    var image = seg("i", "image", 0, 10)
    image.file = "pic.png"; image.x = 0.5; image.y = 0.5; image.size = 0.4; image.animIn = "none"; image.animOut = "none"; image.layer = layer
    var edits = Edits(segments: picture ? [image] : [])
    edits.imageLanes = 1
    edits.base = base
    if three { edits.three.on = true; edits.three.turn = 80 }
    if let effect { var fx = seg("fx", "mono", 1, 5); fx.scope = effect; edits.segments.append(fx); edits.fitLanes() }
    let checker = CIFilter.checkerboardGenerator()
    checker.width = 10; checker.color0 = CIColor(red: 0.95, green: 0.6, blue: 0.1); checker.color1 = CIColor(red: 0.1, green: 0.3, blue: 0.9)
    let frame = checker.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    let f = Framing(meta: meta, look: look, edits: edits, cursor: [], folder: reachFolder)
    return Depth(pixels: pixels(f, frame, at: 3), width: Int(f.canvas.width), height: Int(f.canvas.height),
                 video: f.subjectFrame(at: 3), picture: f.imageFrame(image, at: 3))
}

test("behind the video: hidden where the video covers it, shown where the video moves, shrinks or turns away") {
    let none = try depth(layer: nil, picture: false), behind = try depth(layer: "behind"), front = try depth(layer: nil)
    eq(behind.pixels, none.pixels, "the video covers all of it: the frame is the one without it, byte for byte")
    expect(front.pixels != none.pixels, "in front, it shows over the video")
    let away = Placement(x: 0.82, y: 0.5, scale: 0.3)
    let movedNone = try depth(layer: nil, picture: false, base: away), movedBehind = try depth(layer: "behind", base: away)
    let movedFront = try depth(layer: nil, base: away)
    expect(movedBehind.at(0.5, 0.5) != movedNone.at(0.5, 0.5), "with the video moved away, it shows")
    eq(movedBehind.at(0.5, 0.5), movedFront.at(0.5, 0.5), "where the video is not, it looks as it does in front")
    eq(movedBehind.at(0.82, 0.5), movedNone.at(0.82, 0.5), "where the video is, the video covers it")
    let near = Placement(x: 0.7, y: 0.5, scale: 0.4)
    let n = try depth(layer: nil, picture: false, base: near), b = try depth(layer: "behind", base: near), fr = try depth(layer: nil, base: near)
    let edge = (max(b.video.x, b.picture.x) + min(b.video.x + b.video.w, b.picture.x + b.picture.w)) / 2
    expect(b.video.x < b.picture.x + b.picture.w - 0.01, "the video's edge lies over the picture")
    expect(fr.at(edge, 0.5) != n.at(edge, 0.5), "in front, it covers the video's edge")
    eq(b.at(edge, 0.5), n.at(edge, 0.5), "behind, the video's edge covers it")
    let turnedNone = try depth(layer: nil, picture: false, three: true), turned = try depth(layer: "behind", three: true)
    expect(turned.pixels != turnedNone.pixels, "a video turned in 3D shows it at its narrowing side")
}

test("behind the video: the background cut stays under it; scene and the cuts above it cover it") {
    let away = Placement(x: 0.82, y: 0.5, scale: 0.3)
    let plain = try depth(layer: "behind", base: away)
    let p = plain.at(0.5, 0.5)
    eq(try depth(layer: "behind", base: away, effect: "background").at(0.5, 0.5), p, "a background reach leaves it in colour")
    for scope in ["scene", "frame", "all"] {
        let c = try depth(layer: "behind", base: away, effect: scope).at(0.5, 0.5)
        expect(c != p && abs(Int(c[0]) - Int(c[1])) < 4 && abs(Int(c[1]) - Int(c[2])) < 4, "\(scope) turns it grey: \(c) from \(p)")
    }
    let front = try depth(layer: nil, base: away, effect: "scene").at(0.5, 0.5)
    eq(front, try depth(layer: nil, base: away).at(0.5, 0.5), "scene never reaches an image in front")
    eq(Framing.stack, ["background", "behind", "video", "images", "texts"])
}

test("arrange from the Editor: each step is one named undo step; a refused one says why and is none") {
    let e = open("empty", edits: """
    {"textLanes":1,"imageLanes":2,"segments":[
      {"id":"a","kind":"image","start":1,"end":6,"lane":0,"file":"images/logo.png"},
      {"id":"b","kind":"image","start":2,"end":5,"lane":1,"file":"images/logo.png"},
      {"id":"t","kind":"text","start":1,"end":4,"lane":0,"text":"Hi"}]}
    """)
    e.select("b")
    eq(e.selection["layer"] as? String, "front"); eq(e.selection["canForward"] as? Bool, true); eq(e.selection["canBack"] as? Bool, false)
    e.arrange("forward")
    eq(e.undoName, "Bring Forward"); eq(e.edits.overlays(at: 3).map(\.id), ["a", "b", "t"])
    eq(onDisk(e).segments.map(\.order), [0, 1, nil], "saved")
    e.arrange("behind")
    eq(e.undoName, "Send Behind Video"); eq(e.edits.overlays(at: 3, behind: true).map(\.id), ["b"])
    eq(e.selection["layer"] as? String, "behind"); eq(e.selection["canForward"] as? Bool, false)
    eq(TimelineView.chips(e.selectedSegment!), [TimelineView.behindChip])
    e.arrange("behind")
    eq(e.undoName, "Send Behind Video", "a refused step is none"); eq(e.problem, "It is already behind the video.")
    e.arrange("in-front")
    eq(e.undoName, "Bring In Front of Video"); eq(e.edits.overlays(at: 3).map(\.id), ["b", "a", "t"])
    e.select("t"); e.arrange("behind"); e.select("t")
    eq(e.undoName, "Send Behind Video")
    e.undo(); e.undo(); e.undo(); e.undo()
    eq(e.edits.overlays(at: 3).map(\.id), ["b", "a", "t"]); eq(e.edits.segments.map(\.order), [nil, nil, nil])
    eq(onDisk(e).segments.map(\.layer), [nil, nil, nil])
    e.select("a"); e.arrange("back")
    eq(e.undoName, "Send to Back"); eq(e.edits.overlays(at: 3).map(\.id), ["a", "b", "t"])
    e.arrange("front")
    eq(e.undoName, "Bring to Front"); e.arrange("backward"); eq(e.undoName, "Send Backward")
}

test("Split follows the selection and names itself; the clip when nothing is selected; each split is one undo step") {
    let e = open("full")
    at(e, 1.3)
    e.select("")
    eq(e.splitLabel, "Split Clip"); eq(e.summary["canSplit"] as? Bool, true); eq(e.summary["splitLabel"] as? String, "Split Clip")
    e.select("txt")
    eq(e.splitLabel, "Split Text")
    e.split()
    eq(e.problem, ""); eq(e.undoName, "Split Text"); eq(e.selected, "txt-2", "the second half is selected")
    eq(e.edits.splits, [3, 4.5, 7], "the clip is not cut")
    e.select("z1"); eq(e.splitLabel, "Split Zoom")
    e.select("img"); eq(e.splitLabel, "Split Image")
    e.select("snd:sound1"); eq(e.splitLabel, "Split Sound")
    e.select("ie:img:e1"); eq(e.splitLabel, "Split Image Effect")
    eq(e.summary["canSplit"] as? Bool, false, "the playhead is off that effect"); expect((e.summary["splitWhy"] as? String ?? "").contains("0.1 s"), "says why")
    e.split()
    expect(e.problem.contains("0.1 s"), e.problem)
    e.select("m:m1"); eq(e.splitLabel, "Split Clip", "a move is a point in time, so the clip is cut")
    e.undo()
    eq(e.edits.texts.count, 1)
}

test("Split All Lanes is one undo step, and undo restores exactly") {
    let e = open("full")
    let before = e.edits
    at(e, 1.3)
    eq(e.summary["canSplitAll"] as? Bool, true)
    e.splitAll()
    eq(e.problem, ""); eq(e.undoName, "Split All Lanes")
    expect(e.edits.splits.contains { abs($0 - 1.3) < 0.01 }, "the clip is cut"); eq(e.edits.moves, before.moves)
    expect(e.edits.segments.count > before.segments.count + 3, "every lane was cut"); eq(e.edits.sounds.count, 2)
    eq(onDisk(e), e.edits, "saved with its joins")
    e.undo()
    eq(e.edits, before); eq(onDisk(e), before, "written back")
    e.redo()
    expect(e.edits.segments.count > before.segments.count + 3, "redo cuts again")
}

test("a half dragged away from the other is no longer joined") {
    let e = open("full")
    at(e, 1.8)
    e.select("z1"); e.split()
    let right = e.selected
    eq(e.edits.segments.first { $0.id == "z1" }?.joinEnd, true)
    e.drag(right, start: 2.0, end: 2.7, lane: 0)
    e.endDrag()
    eq(e.problem, "")
    eq(e.edits.segments.first { $0.id == "z1" }?.joinEnd, nil); eq(e.selectedSegment?.joinStart, nil)
}

test("the old folds move to the new key once: the old Clip fold is dropped, the others stay folded") {
    expect(Settings.store != UserDefaults.standard, "the tests keep their settings apart from the person's")
    Settings.store.set(["video", "top", "sound"], forKey: "ExactStudio.folded")
    Settings.store.set(true, forKey: "ExactStudio.videoClosed")
    let e = open("full")
    eq(e.folded, ["top", "sound"])
    expect(e.videoOpen, "VIDEO starts open")
    expect(Settings.store.object(forKey: "ExactStudio.folded") == nil, "the old key is gone")
    expect(Settings.store.object(forKey: "ExactStudio.videoClosed") == nil, "the old Clip key is gone")
    e.toggle(group: "video")
    Settings.store.set(["frame"], forKey: "ExactStudio.folded")
    eq(Settings.folded, ["top", "sound", "video"], "the new key wins over a later old one")
}

test("folding VIDEO hides the Clip too; selecting a clip part, a move, the sound or an effect opens it again") {
    let e = open("full")
    let text = e.edits.segments.first { $0.space == 1 }!.id, zoom = e.edits.segments.first { $0.space == 0 }!.id
    for id in [e.pieces[0].id, "m:" + e.edits.moves[0].id, Editor.recordedSound, zoom] {
        e.select("")
        e.toggle(group: "video")
        expect(!e.videoOpen, "folded before selecting \(id)")
        e.select(id)
        expect(e.videoOpen, "selecting \(id) opens VIDEO")
    }
    e.select("")
    e.toggle(group: "top")
    e.select(text)
    expect(!e.folded.contains("top"), "selecting a text opens ON TOP")
}

func timeline(_ e: Editor, height: CGFloat) -> TimelineView {
    let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 1100, height: height))
    view.attach(e)
    return view
}

test("VIDEO folded is one summary line: the Clip and its rows go, ON TOP moves up under it") {
    let e = open("full")
    let view = timeline(e, height: 2000)
    let open = view.rows
    eq(open.first?.kind, .header("video"))
    let clipEnd = open.first { $0.kind == .position }!.y
    expect(clipEnd > open[0].maxY + 40, "open, the Clip sits between VIDEO and its rows")
    e.toggle(group: "video")
    let folded = view.rows
    eq(folded.map(\.kind).filter { [.position, .lane(0, 0), .sound].contains($0) }, [], "folded, no row of the video's")
    eq(folded[1].kind, .header("top"))
    near(Double(folded[1].y - folded[0].maxY), 8, "ON TOP sits right under the VIDEO line")
    e.toggle(group: "video")
    eq(view.rows.map(\.y), open.map(\.y), "unfolded, every row is back where it was")
    view.detach()
}

test("a fold or unfold keeps the header clicked where it was, however far the rows are scrolled") {
    let e = open("full")
    let view = timeline(e, height: 150)
    func screen(_ kind: TimelineView.Kind) -> CGFloat? { view.rows.first { $0.kind == kind }.map { $0.y - view.scrollY } }
    func scroll(to kind: TimelineView.Kind) {
        view.scrollY = view.rows.first { $0.kind == kind }!.y - 60
        expect(view.scrollY + view.bounds.height < view.rows.last!.maxY, "the rows scroll as far as \(kind)")
    }
    for group in ["top", "sound"] {
        scroll(to: .header(group))
        let before = screen(.header(group))
        e.toggle(group: group)
        eq(screen(.header(group)), before, "folding \(group)")
        e.toggle(group: group)
        eq(screen(.header(group)), before, "unfolding \(group)")
    }
    scroll(to: .header("sound"))
    let sound = screen(.header("sound"))
    e.toggle(group: "video")
    eq(screen(.header("sound")), sound, "VIDEO folded out of sight leaves the rows in sight where they were")
    e.select(e.pieces[0].id)
    expect(e.videoOpen, "selecting a clip part opens VIDEO")
    eq(screen(.header("sound")), sound, "VIDEO opened out of sight leaves the rows in sight where they were")
    view.detach()
}

// MARK: Refusals: the same rules, in the same words, everywhere
// @ref LLP 0005#refusals

struct RuleCase: Decodable { var rule, app, item, line1, line2: String; var before, after: Edits }
let ruleCases = try JSONDecoder().decode([RuleCase].self, from: Data(contentsOf: repo.appendingPathComponent("test/rules.json")))

func json(_ e: Edits) -> String { String(data: try! JSONEncoder().encode(e), encoding: .utf8)! }

test("test/rules.json covers every rule a file can break") {
    let covered = Set(ruleCases.map(\.rule))
    for (id, _) in Rules.all where !["room-at-playhead", "last-effects-lane"].contains(id) { expect(covered.contains(id), "no case for \(id)") }
    for c in ruleCases { eq(Rules.line1(c.rule), c.line1, c.rule) }
}

for c in ruleCases {
    test("\(c.rule): the app says “\(c.line1) \(c.line2)”, the words validate and MCP print") {
        let e = open("empty", edits: json(c.before))
        eq(e.standing, [], "the case's before breaks nothing")
        let steps = e.undoName
        switch c.app {
        case "refuses":
            expect(!e.apply(c.after), "refused")
            eq(e.refusal?.rule, c.rule); eq(e.refusal?.line1, c.line1); eq(e.refusal?.line2, c.line2)
            eq(onDisk(e), c.before, "nothing saved"); eq(e.undoName, steps, "no undo step")
        case "relanes":
            expect(e.apply(c.after), "a taken lane is no refusal in the app")
            eq(e.edits.conflicts(map: e.map), [], "it went to the first free lane")
            eq(Editor.newConflict(c.after, since: c.before, duration: 10)?.text, "\(c.line1) \(c.line2)", "the words validate prints for the file")
        case "setTimes":
            e.select("a"); e.setTimes(start: 1, end: 1.05)
            eq(e.refusal?.rule, c.rule); eq(e.refusal?.line1, c.line1); eq(e.refusal?.line2, c.line2)
        case "toggleRemoved":
            e.select("p:5000"); e.toggleRemoved()
            eq(e.refusal?.rule, c.rule); eq(e.refusal?.line1, c.line1); eq(e.refusal?.line2, c.line2)
        default: expect(false, "unknown app case \(c.app)")
        }
    }
}

test("an old file that breaks the new rules opens, keeps every edit, marks the items, and refuses only new breaks") {
    let old = """
    { "lanes": 2, "textLanes": 0, "frameLanes": 1,
      "segments": [{ "id": "b1", "kind": "blur", "start": 1, "end": 4 }, { "id": "b2", "kind": "blur", "start": 2, "end": 5, "scope": "frame" },
                   { "id": "o", "kind": "3d", "start": 5, "end": 8, "style": "orbit" }, { "id": "z", "kind": "zoom", "start": 6, "end": 9, "lane": 1, "level": 2 }],
      "moves": [{ "id": "m1", "t": 3, "to": { "x": 0.3 } }, { "id": "m2", "t": 3.4, "to": { "x": 0.7 }, "duration": 0.8 }] }
    """
    let e = open("empty", edits: old)
    eq(e.edits.segments.count, 4, "every segment kept"); eq(e.edits.moves.count, 2, "every move kept")
    eq(Set(e.standing.map(\.rule)), ["one-blur", "no-zoom-in-orbit", "move-after-move"])
    e.select("z")
    eq(e.selection["problem"] as? String, "No zoom during an orbit. 3D orbit runs to 0:08.0. Start it at 0:08.0 or later.", "the reason shows on the item")
    eq(e.refusal, nil, "shown, not refused")
    e.setValue(number: 2.5, kind: nil)
    eq(e.selectedSegment?.level, 2.5, "a change that leaves the old break alone lands")
    eq(onDisk(e).segments.count, 4, "saved with the old break in it")
    e.select("b1"); e.setTimes(start: 1, end: 6)
    eq(e.refusal, nil, "the same pair, so not new")
    at(e, 8.5); e.add("blur")
    eq(e.refusal?.rule, nil)
    let late = e.selectedSegment!
    e.select(late.id); e.setTimes(start: 4.5, end: 9)
    eq(e.refusal?.rule, "one-blur", "a new pair is refused")
}

test("a refused drag: checked on every step, the clash named, nothing saved and no undo step on release") {
    let e = open("empty", edits: """
    { "lanes": 2, "textLanes": 2, "segments": [{ "id": "a", "kind": "zoom", "start": 1, "end": 4, "level": 2 }, { "id": "b", "kind": "zoom", "start": 6, "end": 8, "level": 0.7 },
      { "id": "t1", "kind": "text", "start": 1, "end": 3, "text": "One" }, { "id": "t2", "kind": "text", "start": 5, "end": 7, "text": "Two" }] }
    """)
    let steps = e.undoName, disk = onDisk(e)
    e.select("b")
    e.drag("b", start: 3, end: 5, lane: 1)
    eq(e.dragCheck?.item, ItemRef(kind: "zoom", id: "b"))
    eq(e.dragCheck?.conflict?.rule, "one-zoom"); eq(e.dragCheck?.conflict?.other, ItemRef(kind: "zoom", id: "a"))
    eq(e.dragCheck?.conflict?.text, "One zoom at a time. Zoom in 2× runs to 0:04.0. Start it at 0:04.0 or later.")
    e.drag("b", start: 4.5, end: 6.5, lane: 1)
    eq(e.dragCheck?.conflict, nil, "the next step is fine again")
    e.drag("b", start: 2, end: 4, lane: 1)
    expect(!e.endDrag(), "refused")
    near(e.selectedSegment?.start ?? -1, 6, "back where it was"); eq(e.selected, "b", "still selected")
    eq(onDisk(e), disk, "nothing saved"); eq(e.undoName, steps, "no undo step"); eq(e.dragCheck, nil)
    eq(e.problem, "One zoom at a time. Zoom in 2× runs to 0:04.0. Start it at 0:04.0 or later.", "the inspector keeps the reason")
    e.select("t2")
    e.drag("t2", start: 2, end: 4, lane: 0)
    eq(e.dragCheck?.conflict, nil, "a text over a text is no refusal"); eq(e.dragCheck?.landing, 1, "it shows where it will land")
    expect(e.endDrag(), "dropped")
    eq(e.selectedSegment?.lane, 1); near(e.selectedSegment?.start ?? -1, 2)
}

test("a + menu item that would be refused is off, its reason the rule's two lines; asking changes nothing") {
    let e = open("empty")
    at(e, 1); e.add("zoom-in")
    let before = e.edits, chosen = e.selected
    at(e, 2)
    let effects = menu(.lane(0, 0), e)
    let zoom: [MenuEntry] = { if case let .sub(_, inner) = effects.first(where: { if case .sub("Zoom", _) = $0 { return true }; return false })! { return inner }; return [] }()
    eq(zoom.reason("Zoom In"), "One zoom at a time.\nZoom in 2× runs here until 0:04.0. Move the playhead past it.")
    eq(zoom.reason("Zoom Out"), zoom.reason("Zoom In"))
    expect(!effects.run("Zoom › Zoom In"), "an off item does not run")
    eq(zoom.reason("Zoom on Clicks"), nil)
    expect(effects.choices.contains("Look › Blur") && !effects.run("Zoom › Zoom Out"), "the menu keeps its shape")
    eq(e.edits, before, "asking changed nothing"); eq(e.selected, chosen); eq(e.problem, "")
    e.addMove()
    at(e, 2.3)
    eq(menu(.position, e).reason("Add Move Here"), "One move at a time.\nThe move before lands at 0:02.0. Land this one at 0:02.8 or later.")
    at(e, 5)
    eq(menu(.position, e).reason("Add Move Here"), nil)
}

test("a text's own effect + menu: an effect with no room left is off, with the rule's two lines") {
    let e = open("empty", edits: """
    { "lanes": 1, "textLanes": 1, "segments": [{ "id": "t", "kind": "text", "start": 1, "end": 3, "text": "Hi",
      "effects": [{ "id": "b", "kind": "blur", "start": 1, "end": 3 }] }] }
    """)
    at(e, 2)
    let entries = menu(.imageEffects("t", 0), e)
    eq(entries.reason("Blur"), "One of each per text.\nIts blur leaves no 0.3 s free. Shorten or remove it.")
    eq(entries.reason("Fade"), nil)
    expect(!entries.run("Blur"), "an off item does not run")
    eq(e.edits.texts.first?.effects?.count, 1)
}

test("a typed time that clashes says why under its field, and nothing changes until Return") {
    let e = open("empty", edits: """
    { "lanes": 2, "textLanes": 0, "segments": [{ "id": "a", "kind": "zoom", "start": 1, "end": 4, "level": 2 }, { "id": "b", "kind": "zoom", "start": 6, "end": 8, "level": 0.7, "lane": 1 }] }
    """)
    e.select("b")
    e.checkTime("start", 3)
    eq(e.selection["startWhy"] as? String, "One zoom at a time. Zoom in 2× runs to 0:04.0. Start it at 0:04.0 or later.")
    eq(e.selection["endWhy"] as? String, "")
    near(e.selectedSegment?.start ?? -1, 6, "not applied while typing"); eq(e.problem, "")
    e.checkTime("start", 4.5)
    eq(e.selection["startWhy"] as? String, "", "a fine value clears it")
    e.checkTime("start", 3)
    e.setTimes(start: 3, end: nil)
    near(e.selectedSegment?.start ?? -1, 6, "Return: refused, it stays"); eq(e.selection["startWhy"] as? String, "")
    eq(e.refusal?.rule, "one-zoom")
}

test("P1 fixes the jump: a move that waits for the last landing moves smoothly; one that does not jumps") {
    func pose(_ moves: String) throws -> Framing { try pathFraming("{ \"moves\": [\(moves)] }") }
    let a = "{ \"id\": \"a\", \"t\": 3, \"to\": { \"x\": 0.2, \"y\": 0.5, \"scale\": 0.6 }, \"duration\": 1 }"
    let jumps = try pose(a + ", { \"id\": \"b\", \"t\": 3.6, \"to\": { \"x\": 0.8, \"y\": 0.5, \"scale\": 0.6 }, \"duration\": 1.2 }")
    let fine = try pose(a + ", { \"id\": \"b\", \"t\": 4.2, \"to\": { \"x\": 0.8, \"y\": 0.5, \"scale\": 0.6 }, \"duration\": 1.2 }")
    func biggestStep(_ f: Framing) -> Double {
        stride(from: 1.5, to: 5.5, by: 0.01).map { t in abs(f.pose(at: t + 0.01).x - f.pose(at: t).x) }.max() ?? 0
    }
    expect(biggestStep(jumps) > 0.1, "the old overlap jumps (\(biggestStep(jumps)))")
    expect(biggestStep(fine) < 0.03, "after the landing it glides (\(biggestStep(fine)))")
    var e = Edits()
    e.moves = try decode("{ \"moves\": [\(a), { \"id\": \"b\", \"t\": 3.6, \"to\": { \"x\": 0.8 }, \"duration\": 1.2 }] }").moves
    eq(e.conflicts(map: TimeMap(duration: 10, edits: e)).map(\.rule), ["move-after-move"], "and the rule refuses it")
}

if let shots = ProcessInfo.processInfo.environment["EXACT_STUDIO_SHOTS"] {
    test("pictures of a refused drag and an off menu item (EXACT_STUDIO_SHOTS)") {
        let out = URL(fileURLWithPath: shots)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let e = open("empty", edits: """
        { "lanes": 3, "textLanes": 1, "segments": [
          { "id": "zin", "kind": "zoom", "start": 1, "end": 4.4, "level": 2 },
          { "id": "zout", "kind": "zoom", "start": 6.4, "end": 8.6, "level": 0.7, "lane": 1 },
          { "id": "mask", "kind": "mask", "start": 1.6, "end": 6.2, "lane": 2, "style": "solid", "rect": { "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.1 } },
          { "id": "t", "kind": "text", "start": 0.5, "end": 3, "text": "New in 2.0" },
          { "id": "t2", "kind": "text", "start": 4.6, "end": 7, "text": "Notification controls" } ],
          "moves": [{ "id": "m", "t": 2, "to": { "x": 0.4 } }] }
        """)
        let w = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 1100, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 1100, height: 470))
        w.contentView = view
        view.attach(e)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: view.bounds.height - p.y), modifierFlags: [], timestamp: 0,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func save(_ name: String) {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        let row = view.rows.first { $0.kind == .lane(0, 1) }!
        let x = { (t: Double) in CGFloat(170 + 14) + CGFloat(t / e.duration) * (view.bounds.width - 170 - 14 - 22) }
        let grab = CGPoint(x: x(7.4), y: row.y + row.height / 2)
        view.mouseDown(with: event(.leftMouseDown, grab))
        for step in 1...8 { view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: grab.x - CGFloat(step) * (x(7.4) - x(3.6)) / 8, y: grab.y))) }
        eq(e.dragCheck?.conflict?.rule, "one-zoom")
        view.display()
        save("refused-drag.png")
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: x(3.6), y: grab.y)))
        _ = wait(0.4) { false }
        view.display()
        save("refused-drag-after.png")

        let text = view.rows.first { $0.kind == .lane(1, 0) }!
        let t0 = CGPoint(x: x(5.5), y: text.y + text.height / 2)
        view.mouseDown(with: event(.leftMouseDown, t0))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: x(2.2), y: t0.y)))
        expect(e.dragCheck?.landing == 1, "lands on a new text lane")
        view.display()
        save("taken-lane-lands.png")
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: x(2.2), y: t0.y)))

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        w.orderFront(nil)
        _ = wait(0.8) { false }
        at(e, 2.4)
        let effects = menu(.lane(0, 0), e)
        guard case let .sub(_, zoom)? = effects.first(where: { if case .sub("Zoom", _) = $0 { return true }; return false }) else { return }
        for (name, entries) in [("off-menu-zoom.png", zoom), ("off-menu-move.png", menu(.position, e))] {
            let m = view.nsMenu(entries)
            let shot = out.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: shot)
            for _ in 0..<3 where !FileManager.default.fileExists(atPath: shot.path) {
                _ = wait(0.6) { false }
                let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
                    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }
                    if let id = windows.last?[kCGWindowNumber as String] as? Int {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-l", "\(id)", shot.path]
                        try? p.run(); p.waitUntilExit()
                    }
                    m.cancelTracking()
                }
                RunLoop.main.add(timer, forMode: .common)
                m.popUp(positioning: nil, at: CGPoint(x: 220, y: 100), in: view)
                timer.invalidate()
            }
            expect(FileManager.default.fileExists(atPath: shot.path), "\(name) written")
        }
        w.orderOut(nil)
        view.detach()
    }
}

// MARK: The curtain: the app's own windows out of the way while picking and recording

func plainWindow(_ frame: CGRect, level: NSWindow.Level = .normal) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.level = level
    w.orderFront(nil)
    return w
}

test("the curtain orders the app's windows out and back exactly as they were") {
    let a = plainWindow(CGRect(x: 40, y: 60, width: 300, height: 200))
    let b = plainWindow(CGRect(x: 120, y: 90, width: 320, height: 240))
    a.orderFront(nil)
    let frames = (a.frame, b.frame)
    let curtain = Curtain(fade: 0) { [a, b] }
    curtain.close()
    eq(curtain.closed, true)
    expect(!a.isVisible && !b.isVisible, "both windows are ordered out")
    curtain.open()
    expect(a.isVisible && b.isVisible, "both windows are back")
    eq(a.frame, frames.0); eq(b.frame, frames.1)
    eq(a.alphaValue, 1); eq(b.alphaValue, 1)
    expect(a.orderedIndex < b.orderedIndex, "the same order, front to back: \(a.orderedIndex) \(b.orderedIndex)")
    a.orderOut(nil); b.orderOut(nil)
}

test("the curtain closes once and opens once") {
    let a = plainWindow(CGRect(x: 40, y: 60, width: 300, height: 200))
    let curtain = Curtain(fade: 0) { [a] }
    curtain.open()
    expect(a.isVisible, "opening a curtain that never closed changes nothing")
    curtain.close(); curtain.close()
    eq(curtain.held.count, 1, "a second close holds nothing more")
    curtain.open(); curtain.open()
    expect(a.isVisible, "back after the first open")
    eq(curtain.held.count, 0)
    a.orderOut(nil)
}

test("the curtain leaves windows at the menu bar's level and above, and windows already hidden") {
    let main = plainWindow(CGRect(x: 40, y: 60, width: 300, height: 200))
    let bar = plainWindow(CGRect(x: 0, y: 0, width: 200, height: 22), level: .statusBar)
    let overlay = plainWindow(CGRect(x: 0, y: 0, width: 200, height: 200), level: .screenSaver)
    let closed = plainWindow(CGRect(x: 10, y: 10, width: 200, height: 200))
    closed.orderOut(nil)
    let curtain = Curtain(fade: 0) { [main, bar, overlay, closed] }
    curtain.close()
    expect(!main.isVisible, "the main window goes")
    expect(bar.isVisible && overlay.isVisible, "the menu bar item and a picker overlay stay")
    curtain.open()
    expect(main.isVisible, "the main window is back")
    expect(!closed.isVisible, "a window that was not shown stays hidden")
    [main, bar, overlay].forEach { $0.orderOut(nil) }
}

test("the curtain takes a child window with its parent") {
    let parent = plainWindow(CGRect(x: 40, y: 60, width: 400, height: 300))
    let child = plainWindow(CGRect(x: 80, y: 100, width: 200, height: 120))
    parent.addChildWindow(child, ordered: .above)
    let frame = child.frame
    let curtain = Curtain(fade: 0) { [parent, child] }
    curtain.close()
    expect(!parent.isVisible && !child.isVisible, "both are gone")
    curtain.open()
    expect(parent.isVisible && child.isVisible, "both are back")
    eq(child.frame, frame)
    parent.removeChildWindow(child)
    parent.orderOut(nil); child.orderOut(nil)
}

test("opening the curtain while it fades out keeps the windows") {
    let a = plainWindow(CGRect(x: 40, y: 60, width: 300, height: 200))
    let curtain = Curtain(fade: 0.2) { [a] }
    curtain.close()
    curtain.open()
    _ = wait(0.6) { false }
    expect(a.isVisible, "the late fade-out did not order it out")
    near(Double(a.alphaValue), 1, "fully shown again", within: 0.01)
    a.orderOut(nil)
}

test("the app's own windows are never a picker's candidates") {
    let mine = plainWindow(CGRect(x: 100, y: 100, width: 400, height: 300))
    mine.title = "Exact Studio test window"
    _ = wait(0.3) { false }
    let ids = SourcePicker.candidates(.window).compactMap(\.windowID) + SourcePicker.candidates(.simulator).compactMap(\.windowID)
    expect(!ids.contains(CGWindowID(mine.windowNumber)), "our window is not offered")
    mine.orderOut(nil)
}

test("another copy of the app is never a candidate either") {
    let id = "com.entiendonull.exactstudio"
    eq(Sources.ours(id, mine: id), true)
    eq(Sources.ours("com.apple.TextEdit", mine: id), false)
    eq(Sources.ours(nil, mine: id), false)
    eq(Sources.ours(id, mine: nil), false)
}

test("new ids never repeat, even many in one millisecond") {
    let ids = (0..<5000).map { _ in Editor.newID("t") }
    eq(Set(ids).count, ids.count)
}

print("\(passed) passed, \(failed.count) failed")
if !failed.isEmpty { failed.forEach { print("  failed: \($0)") }; exit(1) }
