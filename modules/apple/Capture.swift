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
        if bundle == "com.apple.iphonesimulator" { return .simulator }
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

/// A full-screen overlay where the person drags out the area to record.
/// Escape cancels. The rectangle comes back in the display's points, origin top-left.
final class AreaPicker: NSObject {
    private var windows: [NSWindow] = []
    private var done: ((NSScreen, CGRect)?) -> Void = { _ in }

    func pick(_ done: @escaping ((NSScreen, CGRect)?) -> Void) {
        self.done = done
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.finish = { [weak self] rect in self?.finish(rect.map { (screen, $0) }) }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let first = windows.first(where: { $0.screen == NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) }) ?? windows.first {
            first.makeKey()
        }
        NSCursor.crosshair.push()
    }

    private func finish(_ result: (NSScreen, CGRect)?) {
        NSCursor.pop()
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
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let a = start, let b = current else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            label.draw(at: CGPoint(x: r.minX + 6, y: r.maxY + 6), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
        } else {
            let hint = "Drag to choose an area to record. Press Escape to cancel." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .medium)]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil); current = start; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { current = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        guard let r = selection, r.width >= 40, r.height >= 40 else { start = nil; current = nil; needsDisplay = true; return }
        // AppKit's origin is bottom-left; ScreenCaptureKit's source rectangle is top-left.
        finish(CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
    }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { finish(nil) } else { super.keyDown(with: e) } }
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
    private var detected = false
    private var cursor: [(Double, CGPoint)] = []
    private var clicks: [(Double, CGPoint)] = []
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
            sampler = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample(click: false) }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.sample(click: true) }
        }
    }

    private func sample(click: Bool) {
        guard let f = frameOnScreen(), f.width > 0, f.height > 0 else { return }
        let m = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let p = CGPoint(x: (m.x - f.minX) / f.width, y: (top - m.y - f.minY) / f.height)
        let now = CACurrentMediaTime()
        queue.async {
            if click { self.clicks.append((now, p)) } else { self.cursor.append((now, p)) }
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
            crop = Bezel.detect(buffer) ?? .full
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
                let clicks = self.clicks.filter { $0.0 >= first }.map { Point(t: $0.0 - first, x: $0.1.x, y: $0.1.y) }
                let meta = RecordingMeta(id: self.id, name: self.name, kind: self.kind.rawValue,
                                         created: Date().timeIntervalSince1970 * 1000, duration: self.lastTime - first,
                                         width: self.pixelSize.width, height: self.pixelSize.height, crop: self.crop, clicks: clicks)
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
        config.showsCursor = true
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
    static var root: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Exact Studio", isDirectory: true)
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
