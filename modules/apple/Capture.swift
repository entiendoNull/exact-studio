// Capture: what can be recorded, the area picker, and the recorder.
// Windows are captured on their own (`desktopIndependentWindow`), with their
// alpha and without their shadow, so a Simulator or emulator window gives
// the device's shape and nothing of the desktop behind it.
#if os(macOS)
import AppKit
import AVFoundation
import ScreenCaptureKit

enum SourceKind: String { case display, window, simulator, emulator }

enum Sources {
    static func kind(of window: SCWindow) -> SourceKind {
        let bundle = window.owningApplication?.bundleIdentifier ?? ""
        let app = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        // Xcode 27 shows simulated devices in Device Hub; earlier, in Simulator.
        if bundle == "com.apple.iphonesimulator" || bundle == "com.apple.dt.Devices" || app == "Device Hub" { return .simulator }
        if app.hasPrefix("qemu-system") || title.hasPrefix("Android Emulator") { return .emulator }
        return .window
    }

    /// Displays, then devices, then other windows; never this app's own.
    static func list() async throws -> [[String: Any]] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [[String: Any]] = []
        for d in content.displays {
            out.append(["id": "display:\(d.displayID)", "name": "Display \(d.width)×\(d.height)", "app": "", "kind": "display"])
        }
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 120
                && $0.owningApplication?.processID != me
        }
        var devices: [[String: Any]] = [], others: [[String: Any]] = []
        for w in windows {
            let k = kind(of: w)
            let app = w.owningApplication?.applicationName ?? ""
            let title = (w.title ?? "").isEmpty ? app : w.title!
            if k == .window && title.isEmpty { continue }
            let row: [String: Any] = ["id": "window:\(w.windowID)", "name": title, "app": k == .emulator ? "Android Emulator" : app, "kind": k.rawValue]
            if k == .window { others.append(row) } else { devices.append(row) }
        }
        return out + devices + others.sorted { ($0["app"] as! String, $0["name"] as! String) < ($1["app"] as! String, $1["name"] as! String) }
    }
}

/// A full-screen overlay where the person drags out the area to record. The
/// selection stays: drag inside it to move it, drag a handle to resize it,
/// drag elsewhere for a new one. A bar beside it starts the recording
/// (Return) or cancels (Escape). The rest of the screen is dimmed.
/// The rectangle comes back in the display's points, origin top-left.
final class AreaPicker: NSObject {
    private var windows: [NSWindow] = []
    private var done: ((NSScreen, CGRect)?) -> Void = { _ in }

    func pick(_ done: @escaping ((NSScreen, CGRect)?) -> Void) {
        self.done = done
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.finish = { [weak self] rect in self?.finish(rect.map { (screen, $0) }) }
            view.began = { [weak self, weak view] in
                // One selection at a time: starting one on this screen clears the others.
                self?.windows.compactMap { $0.contentView as? PickerView }.filter { $0 !== view }.forEach { $0.clear() }
            }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            if NSMouseInRect(mouse, screen.frame, false) { w.makeKey() }
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ result: (NSScreen, CGRect)?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let done = self.done
        self.done = { _ in }
        done(result)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var finish: (CGRect?) -> Void = { _ in }
    var began: () -> Void = {}

    /// The selection, in this view's coordinates (origin bottom-left).
    private var selection: CGRect?
    private enum Mode { case new(CGPoint), move(CGPoint, CGRect), resize(Int, CGRect) }
    private var mode: Mode?
    private let bar = NSVisualEffectView()
    private let size = NSTextField(labelWithString: "")
    private let record = NSButton(title: "Record", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private static let handle: CGFloat = 10, minimum: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.material = .hudWindow
        bar.state = .active
        bar.blendingMode = .withinWindow
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.isHidden = true
        size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        size.textColor = .secondaryLabelColor
        record.bezelStyle = .rounded
        record.bezelColor = .systemRed
        record.keyEquivalent = "\r"
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        record.imagePosition = .imageLeading
        record.target = self
        record.action = #selector(start)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(stop)
        let stack = NSStackView(views: [size, cancel, record])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() { selection = nil; mode = nil; placeBar(); needsDisplay = true }

    @objc private func start() {
        guard let r = selection else { return }
        // AppKit's origin is bottom-left; ScreenCaptureKit's source rectangle is top-left.
        finish(CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
    }
    @objc private func stop() { finish(nil) }

    // The eight handles: corners 0–3, edges 4–7.
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0, alpha: 0.5).setFill()
        bounds.fill()
        guard let r = selection else {
            let hint = "Drag to choose an area to record. Press Escape to cancel." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .medium)]
            let s = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
            return
        }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1.5
        border.setLineDash([6, 4], count: 2, phase: 0)
        border.stroke()
        for p in handles(r) {
            let h = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: h).fill()
            NSColor(white: 0, alpha: 0.4).setStroke()
            NSBezierPath(ovalIn: h).stroke()
        }
    }

    private func placeBar() {
        guard let r = selection, r.width >= Self.minimum, r.height >= Self.minimum, mode == nil else { bar.isHidden = true; return }
        size.stringValue = "\(Int(r.width)) × \(Int(r.height))"
        bar.isHidden = false
        let s = bar.fittingSize
        var origin = CGPoint(x: r.midX - s.width / 2, y: r.minY - s.height - 14)
        if origin.y < 12 { origin.y = r.maxY + 14 }
        if origin.y + s.height > bounds.height - 12 { origin.y = r.minY + 14 }
        origin.x = min(max(origin.x, 12), bounds.width - s.width - 12)
        bar.frame = CGRect(origin: origin, size: s)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let r = selection {
            if let i = handles(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= Self.handle }) { mode = .resize(i, r) }
            else if r.contains(p) { mode = .move(p, r) }
            else { mode = .new(p); selection = nil; began() }
        } else {
            mode = .new(p)
            began()
        }
        placeBar()
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch mode {
        case let .new(a):
            selection = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y)).integral
        case let .move(a, r):
            var m = r.offsetBy(dx: p.x - a.x, dy: p.y - a.y)
            m.origin.x = min(max(m.minX, 0), bounds.width - m.width)
            m.origin.y = min(max(m.minY, 0), bounds.height - m.height)
            selection = m.integral
        case let .resize(i, r):
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            switch i {
            case 0: x0 = p.x; y0 = p.y
            case 1: x1 = p.x; y0 = p.y
            case 2: x1 = p.x; y1 = p.y
            case 3: x0 = p.x; y1 = p.y
            case 4: y0 = p.y
            case 5: x1 = p.x
            case 6: y1 = p.y
            default: x0 = p.x
            }
            selection = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).integral
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        mode = nil
        if let r = selection, r.width < Self.minimum || r.height < Self.minimum { selection = nil }
        placeBar()
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: stop()                        // Escape
        case 36, 76: start()                   // Return, Enter
        default: super.keyDown(with: e)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

/// One recording in progress.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let id: String
    let folder: URL
    let kind: SourceKind
    let name: String
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "exact-studio.capture")
    private let pixelSize: CGSize
    /// Where the captured content is on screen, in global points, origin top-left;
    /// for a window it follows the window as it moves.
    private let frameOnScreen: () -> CGRect?
    private var firstTime: Double?
    private var lastTime: Double = 0
    private var crop: UnitRect = .full
    private var cornerRadius: Double?
    private var detected = false
    private var cursor: [(Double, CGPoint)] = []
    private var clicks: [(Double, CGPoint)] = []
    private var releases: [(Double, CGPoint)] = []
    private var sampler: Timer?
    private var monitor: Any?

    init(id: String, folder: URL, kind: SourceKind, name: String, filter: SCContentFilter, config: SCStreamConfiguration, frameOnScreen: @escaping () -> CGRect?) throws {
        self.id = id; self.folder = folder; self.kind = kind; self.name = name
        self.frameOnScreen = frameOnScreen
        pixelSize = CGSize(width: config.width, height: config.height)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("capture.mov"), fileType: .mov)
        let bits = max(8_000_000, Int(pixelSize.width * pixelSize.height * 6))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bits],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? ExactStudioError("The recording file could not be opened.") }
        try await stream.startCapture()
        await MainActor.run {
            // The cursor at 60 Hz, and every click, in host time, mapped into the capture.
            sampler = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample(.move) }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] e in
                self?.sample(e.type == .leftMouseUp || e.type == .rightMouseUp ? .up : .down)
            }
        }
    }

    private enum Sample { case move, down, up }

    private func sample(_ kind: Sample) {
        guard let f = frameOnScreen(), f.width > 0, f.height > 0 else { return }
        let m = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let p = CGPoint(x: (m.x - f.minX) / f.width, y: (top - m.y - f.minY) / f.height)
        let now = CACurrentMediaTime()
        queue.async {
            switch kind {
            case .down: self.clicks.append((now, p))
            case .up: self.releases.append((now, p))
            case .move: self.cursor.append((now, p))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        let pts = sample.presentationTimeStamp
        if firstTime == nil {
            firstTime = pts.seconds
            writer.startSession(atSourceTime: pts)
        }
        if !detected && (kind == .simulator || kind == .emulator) {
            detected = true
            // A transparent window around the device, else its dark bezel on an opaque one.
            if let found = Bezel.detect(buffer) {
                crop = found
            } else if let outline = Bezel.outline(buffer) {
                crop = outline.rect
                cornerRadius = outline.radius
            }
        }
        lastTime = pts.seconds
        if input.isReadyForMoreMediaData { input.append(sample) }
    }

    /// Ends the recording and writes its metadata; replies with it.
    func stop() async throws -> RecordingMeta {
        await MainActor.run {
            sampler?.invalidate(); sampler = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        try? await stream.stopCapture()
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<RecordingMeta, Error>) in
            queue.async {
                guard let first = self.firstTime else {
                    self.writer.cancelWriting()
                    return k.resume(throwing: ExactStudioError("No frames arrived. Is Screen Recording allowed in System Settings › Privacy & Security?"))
                }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(seconds: self.lastTime, preferredTimescale: 600))
                let cursor = self.cursor.filter { $0.0 >= first }.map { Point(t: $0.0 - first, x: $0.1.x, y: $0.1.y) }
                let point = { (e: (Double, CGPoint)) in Point(t: e.0 - first, x: e.1.x, y: e.1.y) }
                let clicks = self.clicks.filter { $0.0 >= first }.map(point)
                let releases = self.releases.filter { $0.0 >= first }.map(point)
                let meta = RecordingMeta(id: self.id, name: self.name, kind: self.kind.rawValue,
                                         created: Date().timeIntervalSince1970 * 1000, duration: self.lastTime - first,
                                         width: self.pixelSize.width, height: self.pixelSize.height, crop: self.crop, clicks: clicks,
                                         releases: releases, cornerRadius: self.cornerRadius, device: nil, cursorBaked: false)
                self.writer.finishWriting {
                    do {
                        try Library.write(meta, cursor: cursor, in: self.folder)
                        k.resume(returning: meta)
                    } catch { k.resume(throwing: error) }
                }
            }
        }
    }

    // Window ID → its bounds right now (global points, origin top-left).
    static func bounds(of windowID: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    static func make(source: String, area: (NSScreen, CGRect)?, folder: URL, id: String) async throws -> Recorder {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // The cursor is drawn by the editor from the recorded path, so it can be hidden, resized and animated.
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false

        if source.hasPrefix("window:"), let wid = UInt32(source.dropFirst(7)),
           let window = content.windows.first(where: { $0.windowID == wid }) {
            let scale = NSScreen.screens.first(where: { $0.frame.intersects(appKitRect(window.frame)) })?.backingScaleFactor ?? 2
            config.width = even(window.frame.width * scale)
            config.height = even(window.frame.height * scale)
            let kind = Sources.kind(of: window)
            let name = (window.title ?? "").isEmpty ? (window.owningApplication?.applicationName ?? "Window") : window.title!
            return try Recorder(id: id, folder: folder, kind: kind, name: name,
                                filter: SCContentFilter(desktopIndependentWindow: window), config: config,
                                frameOnScreen: { bounds(of: wid) })
        }

        // A display, whole or an area of it.
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        let display: SCDisplay
        var rect: CGRect
        if let (screen, r) = area {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let d = content.displays.first(where: { $0.displayID == number }) else { throw ExactStudioError("That display is gone.") }
            display = d; rect = r
        } else if source.hasPrefix("display:"), let did = UInt32(source.dropFirst(8)),
                  let d = content.displays.first(where: { $0.displayID == did }) {
            display = d; rect = CGRect(x: 0, y: 0, width: d.width, height: d.height)
        } else {
            throw ExactStudioError("That window or display is gone. Refresh the list.")
        }
        let scale = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID })?.backingScaleFactor ?? 2
        rect = rect.integral
        config.sourceRect = rect
        config.width = even(rect.width * scale)
        config.height = even(rect.height * scale)
        let onScreen = CGRect(x: display.frame.minX + rect.minX, y: display.frame.minY + rect.minY, width: rect.width, height: rect.height)
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let name = area != nil ? "Area \(Int(rect.width))×\(Int(rect.height))" : "Display \(display.width)×\(display.height)"
        return try Recorder(id: id, folder: folder, kind: .display, name: name, filter: filter, config: config, frameOnScreen: { onScreen })
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
    /// A top-left global rectangle in AppKit's bottom-left coordinates.
    private static func appKitRect(_ r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }
}

struct ExactStudioError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Recordings live in ~/Movies/Exact Studio/Recordings/<id>/: capture.mov,
/// meta.json and cursor.json. Exports go to ~/Movies/Exact Studio/.
enum Library {
    /// Under the agent, the session's scratch data folder, so a drive never sees or touches the person's recordings.
    static var scratch: URL?
    static var root: URL {
        scratch ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Exact Studio", isDirectory: true)
    }
    static var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }

    static func write(_ meta: RecordingMeta, cursor: [Point], in folder: URL) throws {
        try JSONEncoder().encode(meta).write(to: folder.appendingPathComponent("meta.json"))
        try JSONEncoder().encode(cursor).write(to: folder.appendingPathComponent("cursor.json"))
    }

    static func meta(_ id: String) -> RecordingMeta? {
        guard let data = try? Data(contentsOf: recordings.appendingPathComponent(id).appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(RecordingMeta.self, from: data)
    }

    static func cursor(_ id: String) -> [Point] {
        guard let data = try? Data(contentsOf: recordings.appendingPathComponent(id).appendingPathComponent("cursor.json")) else { return [] }
        return (try? JSONDecoder().decode([Point].self, from: data)) ?? []
    }

    static func all() -> [RecordingMeta] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
        return ids.compactMap(meta).sorted { $0.created > $1.created }
    }

    static func save(_ meta: RecordingMeta) throws {
        try JSONEncoder().encode(meta).write(to: recordings.appendingPathComponent(meta.id).appendingPathComponent("meta.json"))
    }
}
#endif
