import AppKit
import AVFoundation

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

test("two zooms, speeds or 3D turns never overlap, on any lane") {
    for kind in ["zoom", "speed", "3d"] {
        let e = Edits(segments: [seg("a", kind, 1, 3, lane: 0), seg("b", kind, 2, 4, lane: 1)])
        eq(e.conflict(e.segments[1]), "Two \(Segment.noun(kind)) can’t overlap.", kind)
    }
    let touching = Edits(segments: [seg("a", "zoom", 1, 3), seg("b", "zoom", 3, 4)])
    eq(touching.conflict(touching.segments[1]), nil, "touching zooms")
}

test("two of one visual effect with the same reach never overlap; another reach may") {
    let e = Edits(segments: [seg("a", "blur", 1, 3, lane: 0), seg("b", "blur", 2, 4, lane: 1)])
    eq(e.conflict(e.segments[1]), "Two blurs can’t overlap.")
    var frame = seg("b", "blur", 2, 4)
    frame.scope = "frame"
    let mixed = Edits(segments: [seg("a", "blur", 1, 3), frame])
    eq(mixed.conflict(frame), nil, "a video blur under a whole-frame blur")
    let different = Edits(segments: [seg("a", "spotlight", 1, 3, lane: 0), seg("b", "highlight", 2, 4, lane: 1)])
    eq(different.conflict(different.segments[1]), nil)
}

test("one lane holds one thing at a time; texts, images and masks overlap on separate lanes") {
    let e = Edits(segments: [seg("a", "spotlight", 1, 3), seg("b", "highlight", 2, 4)])
    eq(e.conflict(e.segments[1]), "That lane is taken there; drop it on another lane.")
    for kind in ["text", "mask"] {
        let two = Edits(segments: [seg("a", kind, 1, 3, lane: 0), seg("b", kind, 2, 4, lane: 1)])
        eq(two.conflict(two.segments[1]), nil, kind)
        let one = Edits(segments: [seg("a", kind, 1, 3), seg("b", kind, 2, 4)])
        eq(one.conflict(one.segments[1]), "That lane is taken there; drop it on another lane.", kind)
    }
    let spaces = Edits(segments: [seg("a", "zoom", 1, 3), seg("b", "text", 1, 3)])
    eq(spaces.conflict(spaces.segments[1]), nil, "a text and a zoom on lane 0 of their own spaces")
}

test("an image's own effects and moves stay inside it and never clash") {
    var image = seg("i", "image", 2, 6)
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "fade", 3, 5, lane: 1)]
    eq(Edits.conflict(in: image), nil)
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "pulse", 3, 5, lane: 1)]
    eq(Edits.conflict(in: image), "Two of the same effect can’t overlap on one image.")
    image.effects = [seg("e1", "pulse", 2, 4), seg("e2", "fade", 3, 5)]
    eq(Edits.conflict(in: image), "That row is taken there; drop it on another row.")
    image.effects = [seg("e1", "pulse", 5, 7)]
    eq(Edits.conflict(in: image), "An image’s effect must stay inside the image’s time.")
    image.effects = [seg("e1", "sparkle", 2, 3)]
    eq(Edits.conflict(in: image), "An image has no sparkle effect.")
    image.effects = []
    image.moves = [Move(id: "m", t: 7, to: Placement())]
    eq(Edits.conflict(in: image), "An image’s move must land inside the image’s time.")
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
    eq(e.conflict(b, map: map), "That sound lane is taken there; drop it on another lane.")
    eq(e.freeLane(for: b, map: map), 1)
    eq(e.conflict(Sound(id: "c", file: "sounds/beep.wav", start: 3, length: 1), map: map), nil)
}

test("Zoom on Clicks: clicks close together share a zoom") {
    let z = Edits.autoZooms([Point(t: 2, x: 0, y: 0), Point(t: 3, x: 0, y: 0), Point(t: 8, x: 0, y: 0)], duration: 10)
    eq(z.count, 2)
    near(z[0].start, 1.2); near(z[0].end, 5.2); near(z[1].end, 10)
}

test("every template, for every frame shape, lands without a clash inside the video") {
    var cut = Edits()
    cut.splits = [3, 4.5]; cut.removed = [3]
    let map = TimeMap(duration: 10, edits: cut)
    for name in Templates.names { for aspect in ["16:9", "9:16", "1:1", "4:3", "auto"] {
        guard let made = Templates.make(name, duration: map.outputDuration, source: { map.source($0) }, aspect: aspect,
                                        clicks: [Point(t: 2, x: 0.5, y: 0.5)], three: ThreeD()) else { expect(false, "\(name) \(aspect) made nothing"); continue }
        var e = cut
        e.pack(made.segments)
        expect(!made.segments.isEmpty, "\(name) \(aspect) has no segments")
        for s in e.segments {
            if let why = e.conflict(s) { expect(false, "\(name) \(aspect): \(s.kind) \(s.id): \(why)") }
            expect(s.start >= 0 && s.end <= 10.001 && s.end - s.start >= 0.1, "\(name) \(aspect): \(s.kind) \(s.id) at \(s.start)–\(s.end)")
        }
        for m in made.moves { expect(m.t >= 0 && m.t <= 10.001, "\(name) \(aspect): move at \(m.t)") }
    } }
    expect(Templates.make("nope", duration: 10, source: { $0 }, aspect: "16:9", clicks: [], three: ThreeD()) == nil, "an unknown template")
    expect(Templates.make("launch", duration: 1, source: { $0 }, aspect: "16:9", clicks: [], three: ThreeD()) == nil, "a recording too short")
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

print("editor")

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("exact-studio-model-\(getpid())")
defer { try? FileManager.default.removeItem(at: scratch) }
Library.scratch = scratch
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
    UserDefaults.standard.removeObject(forKey: "ExactStudio.folded")
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
    eq(e.problem, "Keep at least one part of the clip.")
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
    eq(e.problem, "There’s already a zoom at the playhead. Move the playhead to a free spot.")
    eq(e.edits.zooms.count, 1)
    at(e, 0.5); e.add("zoom-out")
    eq(e.edits.zooms.count, 2); near(e.selectedSegment?.end ?? -1, 1, "it stops at the next zoom"); eq(e.selectedSegment?.level, 0.7)
    at(e, 0.8); e.add("fast")
    eq(e.edits.speeds.count, 1); eq(e.selectedSegment?.lane, 1, "a speed under a zoom takes the next lane"); eq(e.edits.lanes, 2)
}

test("texts stack on new text lanes; blurs on the video and on the whole frame go to their own rows") {
    let e = open("empty")
    at(e, 2); e.add("text"); e.add("text")
    eq(e.edits.texts.map(\.lane), [0, 1]); eq(e.edits.textLanes, 2)
    eq(e.selectedSegment?.text, "Your text here")
    e.add("blur"); e.add("blur-frame")
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
    eq(e.problem, "Two zooms can’t overlap.")
    near(e.selectedSegment?.start ?? -1, 6, "back where it was"); eq(e.edits.lanes, 1)
    e.drag(id, start: 4.5, end: 7.5, lane: 1)
    e.endDrag()
    eq(e.problem, ""); eq(e.selectedSegment?.lane, 1); eq(e.edits.lanes, 2, "a drop one past the last lane opens it")
}

test("typed times are checked; delete removes the selection") {
    let e = open("empty")
    at(e, 1); e.add("spotlight")
    e.setTimes(start: 3, end: 3.05)
    eq(e.problem, "Start must come at least 0.1 s before end, inside 0:00–\(Editor.stamp(e.duration)).")
    e.setTimes(start: 2, end: 5)
    near(e.selectedSegment?.start ?? -1, 2); near(e.selectedSegment?.end ?? -1, 5)
    at(e, 3); e.splitSelected()
    eq(e.edits.effects.count, 2)
    e.deleteSelected()
    eq(e.edits.effects.count, 1); eq(e.selected, "")
}

test("a template replaces the texts, effects and moves, keeps the cuts, images and masks; undo puts them back") {
    let e = open("full")
    let before = e.edits
    e.applyTemplate("launch")
    eq(e.undoName, "Template")
    expect(e.edits != before, "the template changed nothing")
    eq(e.edits.splits, before.splits); eq(e.edits.removed, before.removed)
    eq(e.edits.images.map(\.id), ["img"]); eq(e.edits.masks.map(\.id).sorted(), ["mask1", "mask2"])
    expect(!e.edits.texts.contains { $0.id == "txt" }, "the old text stayed")
    eq(e.problem, "")
    e.undo()
    eq(e.edits, before); eq(onDisk(e), before, "saved"); eq(e.undoName, ""); eq(e.redoName, "Template")
    e.applyTemplate("nope")
    eq(e.edits, before)
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

test("lanes: add one, remove an empty one, never the last effect lane or one in use") {
    let e = open("empty")
    e.addLane(); eq(e.edits.lanes, 2)
    e.addLane(space: 1); eq(e.edits.textLanes, 1)
    e.removeLane(1); eq(e.edits.lanes, 1)
    e.removeLane(0); eq(e.edits.lanes, 1, "the last effect lane")
    at(e, 1); e.add("text")
    e.removeLane(0, space: 1); eq(e.edits.textLanes, 1, "a lane in use")
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

test("a blur's reach moves it between the video's lanes and the whole frame's") {
    let e = open("empty")
    at(e, 1); e.add("blur")
    e.setSegment("scope", "frame")
    eq(e.selectedSegment?.space, 3); eq(e.edits.frameLanes, 1)
    e.setSegment("scope", "video")
    eq(e.selectedSegment?.space, 0)
}

test("an image: added from a file, given effects of its own, a same effect twice refused") {
    let e = open("empty")
    at(e, 1)
    e.addImage(fixtures.appendingPathComponent("media/logo.png"))
    let image = e.selectedSegment
    eq(image?.kind, "image"); eq(image?.lane, 0); eq(e.edits.imageLanes, 1)
    expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent(image?.file ?? "x").path), "the picture was copied in")
    e.addImageEffect("pulse")
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

print("\(passed) passed, \(failed.count) failed")
if !failed.isEmpty { failed.forEach { print("  failed: \($0)") }; exit(1) }
