// An image on the video: a picture file in the recording's folder, drawn over the finished
// frame like a text. It can fade or spring in and out, and it has moves and effects of its own,
// as the video has. The preview, the export and the CLI draw it here.
// @ref LLP 0002#images — an image is a row of its own, with its own moves and effects
#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Why a file could not be brought into a recording, in words for the person.
struct FileRefused: Error { let why: String }

/// Files an edit uses, kept in the recording's own folder so it stays whole when copied.
// @ref LLP 0004#the-rule — a file an edit uses lives in the recording's folder
enum RecordingFiles {
    /// Copy `url` into `recording`'s `folder` and give its path inside the recording. The same file
    /// added twice is one file; another file with a taken name gets a number. `what` names it in a refusal.
    static func bring(_ url: URL, into recording: URL, folder: String, what: String) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileRefused(why: "There is no file at \(url.path).") }
        let dir = recording.appendingPathComponent(folder)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var name = url.lastPathComponent, n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path), !fm.contentsEqual(atPath: dir.appendingPathComponent(name).path, andPath: url.path) {
            name = "\(stem)-\(n).\(ext)"
            n += 1
        }
        let to = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: to.path) {
            do { try fm.copyItem(at: url, to: to) } catch { throw FileRefused(why: "Couldn’t copy the \(what) into the recording.") }
        }
        return folder + "/" + name
    }
}

/// Picture files, loaded once per file and again when the file changes.
enum Pictures {
    static let types = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]
    /// The folder inside a recording that holds its pictures.
    static let folder = "images"

    private static var cache: [String: (Date, CIImage)] = [:]
    private static let lock = NSLock()

    static func image(_ file: String?, in folder: URL?) -> CIImage? {
        guard let file, !file.isEmpty, let folder else { return nil }
        let url = folder.appendingPathComponent(file)
        guard let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[url.path], hit.0 == changed { return hit.1 }
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), !img.extent.isEmpty, !img.extent.isInfinite else { return nil }
        // Its bottom-left corner at the origin, whatever the file said.
        let placed = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        cache[url.path] = (changed, placed)
        return placed
    }

    typealias Refused = FileRefused

    /// Whether a panel may open: not while an agent drives the app.
    static var mayAsk = true

    /// A picture file the person picks in a panel.
    static func pick(prompt: String = "Add", then: @escaping (URL) -> Void) {
        guard mayAsk else { return }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedFileTypes = types
            panel.prompt = prompt
            panel.message = "Choose a picture to put on the video."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            then(url)
        }
    }

    /// Copy a picture into a recording's images folder and give its path inside the recording.
    /// The same picture added twice is one file; another picture with a taken name gets a number.
    static func bring(_ url: URL, into recording: URL) throws -> String {
        guard types.contains(url.pathExtension.lowercased()) else {
            throw Refused(why: "Exact Studio can’t show that file. Use a PNG, JPEG, HEIC, TIFF, GIF, WebP or BMP picture.")
        }
        let file = try RecordingFiles.bring(url, into: recording, folder: folder, what: "picture")
        guard image(file, in: recording) != nil else { throw Refused(why: "Couldn’t read that picture.") }
        return file
    }

    /// A new image segment for a picture already in the recording, centred on (x, y): a third of a
    /// canvas's height, or less for a wide picture so it takes at most half the width.
    static func segment(id: String, file: String, in recording: URL, canvas: CGSize, start: Double, end: Double, x: Double = 0.5, y: Double = 0.5) -> Segment {
        var s = Segment(id: id, kind: "image", start: start, end: end)
        let shape = image(file, in: recording).map { Double($0.extent.width / $0.extent.height) } ?? 1
        s.file = file
        s.x = x; s.y = y
        s.size = ((min(0.3, 0.5 * Double(canvas.width / canvas.height) / shape)) * 1000).rounded() / 1000
        s.opacity = 1; s.rotation = 0; s.animIn = "pop"; s.animOut = "fade"
        return s
    }
}

extension Framing {
    /// Where an image is at `t`: its centre, and `scale` times its `size`. Its moves work as the video's do.
    func imagePose(_ s: Segment, at t: Double) -> Pose {
        var from = Placement(x: s.x ?? 0.5, y: s.y ?? 0.5, scale: 1)
        let moves = (s.moves ?? []).sorted { $0.t < $1.t }
        guard !moves.isEmpty else { return Pose(x: from.x, y: from.y, scale: 1) }
        // The scale at which it covers the canvas, for a move through full screen.
        let box = imageFrame(s, x: 0.5, y: 0.5, size: s.size ?? 0.25)
        let fill = max(1 / max(box.w, 0.001), 1 / max(box.h, 0.001)) * 1.04
        for m in moves {
            if t >= m.t { from = m.to; continue }
            let start = m.t - m.duration
            guard t > start, m.duration > 0 else { break }
            return Framing.blend(from, m.to, u: (t - start) / m.duration, style: m.style, fill: fill)
        }
        return Pose(x: from.x, y: from.y, scale: from.scale)
    }

    func renderImage(_ s: Segment, at t: Double) -> CIImage {
        guard let art = Pictures.image(s.file, in: folder) else { return .empty() }
        let pose = imagePose(s, at: t)
        let h = max(0.005, (s.size ?? 0.25) * pose.scale) * canvas.height, k = h / art.extent.height, w = art.extent.width * k
        let box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        // Lanczos keeps a large picture sharp when it is drawn small.
        var picture = art.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        picture = picture.transformed(by: CGAffineTransform(translationX: box.minX - picture.extent.minX, y: box.minY - picture.extent.minY))
        if let r = s.radius, r > 0.001 {
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = box
            g.radius = Float(min(r, 0.5) * min(w, h))
            g.color = .white
            let cut = CIFilter.blendWithMask()
            cut.inputImage = picture
            cut.backgroundImage = CIImage.empty()
            cut.maskImage = g.outputImage
            picture = cut.outputImage!.cropped(to: box)
        }

        var whole = CGAffineTransform.identity, alpha = min(max(s.opacity ?? 1, 0), 1) * pose.opacity, blur = 0.0, grey = 0.0
        func scale(_ k: Double) { whole = whole.scaledBy(x: k, y: k) }
        let since = t - s.start, until = s.end - t

        // Its own effects, each easing in and out over its span.
        for fx in s.effects ?? [] {
            let a = presence(fx, at: t, ramp: 0.3)
            guard a > 0.001 else { continue }
            let run = t - fx.start
            switch fx.kind {
            case "blur": blur = max(blur, h * 0.06 * a)
            case "mono": grey = max(grey, a)
            case "fade": alpha *= 1 - a * (1 - min(max(fx.level ?? 0.3, 0), 1))
            case "pulse": scale(1 + 0.06 * a * sin(run * 2 * .pi / 1.4))
            case "float": whole = whole.translatedBy(x: 0, y: a * sin(run * 2 * .pi / 2.4) * h * 0.05)
            case "wiggle": whole = whole.rotated(by: a * sin(run * 2 * .pi / 1.1) * 0.06)
            default: break
            }
        }
        if grey > 0.001 {
            let c = CIFilter.colorControls()
            c.inputImage = picture
            c.saturation = Float(1 - grey)
            picture = c.outputImage!.cropped(to: box)
        }
        if s.shadow == true {
            let dark = CIFilter.colorMatrix()
            dark.inputImage = picture
            dark.rVector = CIVector(x: 0, y: 0, z: 0, w: 0); dark.gVector = CIVector(x: 0, y: 0, z: 0, w: 0); dark.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            dark.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.5)
            picture = picture.composited(over: dark.outputImage!.applyingGaussianBlur(sigma: h * 0.04).transformed(by: CGAffineTransform(translationX: 0, y: -h * 0.03)))
        }

        // The entrances and exits a text has as a whole.
        let ein = since / 0.55, eout = until / 0.45
        switch s.animIn ?? "fade" {
        case "fade": alpha *= Ease.smooth(ein)
        case "pop": scale(max(0.001, Ease.spring(ein, bounce: 1.2))); alpha *= Ease.smooth(ein * 3)
        case "rise": whole = whole.translatedBy(x: 0, y: -(1 - Ease.out(ein)) * h * 0.3); alpha *= Ease.smooth(ein)
        case "blur": blur = max(blur, (1 - Ease.out(ein)) * h * 0.12); alpha *= Ease.smooth(ein)
        case "spin": whole = whole.rotated(by: -(1 - Ease.spring(ein)) * .pi / 2); scale(max(0.001, Ease.spring(ein))); alpha *= Ease.smooth(ein * 2)
        case "slide": whole = whole.translatedBy(x: -(1 - Ease.spring(ein, bounce: 0.6)) * canvas.width * 0.4, y: 0); alpha *= Ease.smooth(ein * 2)
        default: break
        }
        switch s.animOut ?? "fade" {
        case "fade": alpha *= Ease.smooth(eout)
        case "pop": scale(max(0.001, Ease.inOut(eout))); alpha *= Ease.smooth(eout * 2)
        case "sink": whole = whole.translatedBy(x: 0, y: -(1 - Ease.out(eout)) * h * 0.3); alpha *= Ease.smooth(eout)
        case "blur": blur = max(blur, (1 - Ease.out(eout)) * h * 0.12); alpha *= Ease.smooth(eout)
        default: break
        }
        guard alpha > 0.001 else { return .empty() }
        whole = whole.rotated(by: -((s.rotation ?? 0) + pose.rotation) * .pi / 180)
        if blur > 0.5 { picture = picture.applyingGaussianBlur(sigma: blur) }
        return picture
            .transformed(by: whole)
            .transformed(by: CGAffineTransform(translationX: pose.x * canvas.width, y: (1 - pose.y) * canvas.height))
            .opacity(alpha)
    }

    /// An image's box on the canvas, at rest, for a centre and height. Unit, origin top-left.
    func imageFrame(_ s: Segment, x: Double, y: Double, size: Double) -> UnitRect {
        let shape = Pictures.image(s.file, in: folder).map { Double($0.extent.width / $0.extent.height) } ?? 1
        let w = size * shape * Double(canvas.height / canvas.width)
        return UnitRect(x: x - w / 2, y: y - size / 2, w: w, h: size)
    }

    /// An image's box at `t`.
    func imageFrame(_ s: Segment, at t: Double) -> UnitRect {
        let p = imagePose(s, at: t)
        return imageFrame(s, x: p.x, y: p.y, size: (s.size ?? 0.25) * p.scale)
    }
}
#endif
