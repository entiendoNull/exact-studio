// Capture: what can be recorded, the area picker, and the recorder.
// Windows are captured on their own (`desktopIndependentWindow`), with their
// alpha and without their shadow, so a Simulator or emulator window gives
// the device's shape and nothing of the desktop behind it.
#if os(macOS)
import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit

enum SourceKind: String { case display, window, simulator, emulator }

enum Sources {
    static func kind(of window: SCWindow) -> SourceKind {
        kind(bundle: window.owningApplication?.bundleIdentifier ?? "", app: window.owningApplication?.applicationName ?? "", title: window.title ?? "")
    }

    static func kind(bundle: String, app: String, title: String) -> SourceKind {
        // Xcode 27 shows simulated devices in Device Hub; earlier, in Simulator.
        if bundle == "com.apple.iphonesimulator" || bundle == "com.apple.dt.Devices" || app == "Device Hub" { return .simulator }
        if app.hasPrefix("qemu-system") || title.hasPrefix("Android Emulator") { return .emulator }
        return .window
    }

    /// The Simulator and emulator windows open now, for the sidebar's Simulators list.
    /// Displays and other windows are picked on the screen instead (SourcePicker).
    static func list() async throws -> [[String: Any]] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { w in
            guard w.windowLayer == 0, w.frame.width >= 120, w.frame.height >= 120, w.owningApplication?.processID != me else { return nil }
            let k = kind(of: w)
            guard k != .window else { return nil }
            let app = w.owningApplication?.applicationName ?? ""
            let title = (w.title ?? "").isEmpty ? app : w.title!
            return ["id": "window:\(w.windowID)", "name": title, "app": k == .emulator ? "Android Emulator" : app, "kind": k.rawValue]
        }
    }
}

/// What every picker shares, so they read as one family: the dim, the lit outline,
/// the overlay windows and the one-line hint at the bottom.
enum PickerLook {
    static let dim: CGFloat = 0.4
    static let outline: CGFloat = 2.5
    static var accent: NSColor { .controlAccentColor }

    /// A clear, borderless window over all of `screen`, above everything else.
    static func overlay(on screen: NSScreen, view: NSView) -> NSWindow {
        let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        return w
    }

    /// One quiet line in a pill at the bottom centre of `bounds`.
    static func hint(_ text: String, in bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(white: 1, alpha: 0.85), .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        let line = text as NSString
        let s = line.size(withAttributes: attrs)
        let pill = CGRect(x: (bounds.midX - s.width / 2 - 16).rounded(), y: 32, width: (s.width + 32).rounded(), height: (s.height + 14).rounded())
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        line.draw(at: CGPoint(x: pill.minX + 16, y: pill.minY + 7), withAttributes: attrs)
    }

    /// The red Start Recording button every picker ends with.
    static func startButton(_ title: String = "Start Recording") -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.bezelColor = .systemRed
        b.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        return b
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
            let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.finish = { [weak self] rect in self?.finish(rect.map { (screen, $0) }) }
            view.began = { [weak self, weak view] in
                // One selection at a time: starting one on this screen clears the others.
                self?.windows.compactMap { $0.contentView as? PickerView }.filter { $0 !== view }.forEach { $0.clear() }
            }
            let w = PickerLook.overlay(on: screen, view: view)
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

/// The Display, Window and Simulator pickers: an overlay on every display, the
/// screen dimmed a little. The candidate under the pointer is lit, with its icon,
/// name and size and a Start Recording button in its middle. Comes back with the
/// source to record ("window:<id>" or "display:<id>"), or nil when cancelled.
// @ref LLP 0001#sources — one family; only the button or Return starts a recording
final class SourcePicker: NSObject {
    enum Kind { case display, window, simulator }

    struct Candidate {
        /// What "start" records: the same strings the sidebar's rows send.
        let source: String
        /// Global AppKit points, origin bottom-left.
        let frame: CGRect
        let name: String
        let icon: NSImage?
        let windowID: CGWindowID?
    }

    /// A candidate's shape as a one-off screenshot shows it, in its own points (origin
    /// bottom-left): the rounded rectangle to outline and, for a phone, the silhouette to light.
    struct Shape { var rect: CGRect; var radius: CGFloat; var mask: CGImage?; var maskRect: CGRect }

    /// Until a window's own corners are measured.
    private static let windowRadius: CGFloat = 12

    let kind: Kind
    private(set) var candidates: [Candidate] = []
    /// The lit candidate, an index into `candidates`.
    private(set) var lit: Int?
    private var shapes: [CGWindowID: Shape] = [:]
    private var asked = Set<CGWindowID>()
    private var content: Task<SCShareableContent?, Never>?
    private var views: [SourcePickerView] = []
    private var windows: [NSWindow] = []
    /// The view under the pointer: the hint and the info block show there.
    private weak var active: SourcePickerView?
    private let block = InfoBlock()
    /// The info block and the gap to its candidate, in global points: the pointer there keeps the candidate lit.
    private var reach = CGRect.null
    private var done: (String?) -> Void = { _ in }

    init(_ kind: Kind) {
        self.kind = kind
        super.init()
    }

    /// One display needs no choosing: it is lit at once.
    private var single: Bool { kind == .display && candidates.count == 1 }

    var hint: String {
        switch kind {
        case .display: return single ? "Return records · Esc cancels" : "Move to a display · Return records · Esc cancels"
        case .window: return "Move to a window · Return records · Esc cancels"
        case .simulator: return "Move to a Simulator · Return records · Esc cancels"
        }
    }

    /// What this picker offers now, front to back. Never this app's own windows.
    static func candidates(_ kind: Kind) -> [Candidate] {
        if kind == .display {
            let many = NSScreen.screens.count > 1
            let icon = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))
            return NSScreen.screens.compactMap { s in
                guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                return Candidate(source: "display:\(n)", frame: s.frame, name: many ? s.localizedName : "Display", icon: icon, windowID: nil)
            }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let w = b["Width"] ?? 0, h = b["Height"] ?? 0
            guard w >= 120, h >= 120 else { return nil }
            let owner = NSRunningApplication(processIdentifier: pid)
            let app = info[kCGWindowOwnerName as String] as? String ?? owner?.localizedName ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            // @ref LLP 0001#sources — device windows belong to the Simulator picker, which lights the phone
            let device = Sources.kind(bundle: owner?.bundleIdentifier ?? "", app: app, title: title) != .window
            guard device == (kind == .simulator) else { return nil }
            let name = title.isEmpty ? app : title
            guard !name.isEmpty else { return nil }
            // The list's origin is the main display's top-left; AppKit's is its bottom-left.
            let frame = CGRect(x: b["X"] ?? 0, y: top - (b["Y"] ?? 0) - h, width: w, height: h)
            return Candidate(source: "window:\(id)", frame: frame, name: name, icon: owner?.icon, windowID: id)
        }
    }

    func pick(_ candidates: [Candidate], done: @escaping (String?) -> Void) {
        self.candidates = candidates
        self.done = done
        block.start.target = self
        block.start.action = #selector(startLit)
        if kind != .display {
            content = Task { try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        }
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let view = SourcePickerView(picker: self, origin: screen.frame.origin)
            let w = PickerLook.overlay(on: screen, view: view)
            views.append(view)
            windows.append(w)
            if NSMouseInRect(mouse, screen.frame, false) { w.makeKey(); active = view }
        }
        if active == nil { active = views.first; windows.first?.makeKey() }
        NSApp.activate(ignoringOtherApps: true)
        // A phone's shape is wanted before it is pointed at, and there are only a few.
        if kind == .simulator { candidates.forEach(learnShape) }
        if single { light(0) } else { moved(to: mouse, in: active) }
    }

    /// The pointer is at a global point, over `view`.
    fileprivate func moved(to p: CGPoint, in view: SourcePickerView?) {
        if let view, view !== active {
            active = view
            place()
            views.forEach { $0.needsDisplay = true }
        }
        if single { return }
        // Over the info block, or on the way to it, the candidate stays lit so its button can be reached.
        if lit != nil && reach.contains(p) { return }
        light(candidates.firstIndex { $0.frame.contains(p) })
    }

    fileprivate func isActive(_ view: SourcePickerView) -> Bool { view === active }

    private func light(_ i: Int?) {
        guard i != lit else { return }
        lit = i
        if let i { learnShape(candidates[i]) }
        place()
        views.forEach { $0.needsDisplay = true }
    }

    /// The lit outline of candidate `i` in global points: its learnt shape, else its frame.
    func outline(_ i: Int) -> (rect: CGRect, radius: CGFloat, shape: Shape?) {
        let c = candidates[i]
        guard let id = c.windowID, let s = shapes[id] else { return (c.frame, kind == .display ? 0 : Self.windowRadius, nil) }
        return (s.rect.offsetBy(dx: c.frame.minX, dy: c.frame.minY), s.radius, s)
    }

    /// The info block in the middle of the lit candidate, or just below (else above) it when it does not fit.
    private func place() {
        guard let i = lit, let view = active else {
            block.removeFromSuperview()
            reach = .null
            return
        }
        let c = candidates[i]
        let o = outline(i)
        block.show(name: c.name, icon: c.icon, size: o.shape?.maskRect.size ?? c.frame.size)
        if block.superview !== view { view.addSubview(block) }
        let s = block.fittingSize
        let bounds = view.bounds
        let r = o.rect.offsetBy(dx: -view.origin.x, dy: -view.origin.y)
        let seen = r.intersection(bounds)
        let gap: CGFloat = 12, margin: CGFloat = 12
        let middle = seen.isNull ? r : seen
        var at = CGPoint(x: middle.midX - s.width / 2, y: middle.midY - s.height / 2)
        var outside = false
        let fits = !seen.isNull && seen.width >= s.width + 2 * margin && seen.height >= s.height + 2 * margin
        if !fits && r.minY - gap - s.height >= margin {
            at.y = r.minY - gap - s.height
            outside = true
        } else if !fits && r.maxY + gap + s.height <= bounds.height - margin {
            at.y = r.maxY + gap
            outside = true
        }
        // With no room outside either, it stays in the middle, over the candidate, rather than float off.
        if outside { at.x = r.midX - s.width / 2 }
        at.x = min(max(at.x, margin), bounds.width - s.width - margin)
        at.y = min(max(at.y, margin), bounds.height - s.height - margin)
        block.frame = CGRect(origin: at, size: s).integral
        block.layoutSubtreeIfNeeded()
        let held = outside ? block.frame.insetBy(dx: 0, dy: -(gap + 4)) : block.frame
        reach = held.offsetBy(dx: view.origin.x, dy: view.origin.y)
    }

    @objc func startLit() {
        guard let i = lit else { return }
        finish(candidates[i].source)
    }

    func cancel() { finish(nil) }

    private func finish(_ source: String?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        block.removeFromSuperview()
        content?.cancel()
        let done = self.done
        self.done = { _ in }
        done(source)
    }

    // MARK: Shapes

    /// Measures a window's corners, or finds the phone in a device window, from one screenshot
    /// of that window alone, off the main thread. The whole window stays lit until it lands.
    private func learnShape(_ c: Candidate) {
        guard kind != .display, let id = c.windowID, asked.insert(id).inserted, let content else { return }
        let size = c.frame.size, phone = kind == .simulator
        let scale = NSScreen.screens.first { $0.frame.intersects(c.frame) }?.backingScaleFactor ?? 2
        Task { [weak self] in
            guard let all = await content.value, let window = all.windows.first(where: { $0.windowID == id }),
                  let image = await Self.screenshot(window, scale: scale) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let shape = phone ? Self.phone(in: image, size: size) : Self.corners(of: image, size: size) else { return }
                DispatchQueue.main.async {
                    guard let self, !self.windows.isEmpty else { return }
                    self.shapes[id] = shape
                    if let i = self.lit, self.candidates[i].windowID == id { self.place() }
                    self.views.forEach { $0.needsDisplay = true }
                }
            }
        }
    }

    /// The window as the recording sees it: on its own, without its shadow, corners transparent.
    private static func screenshot(_ window: SCWindow, scale: CGFloat) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    /// The phone, found the way a recording finds it: silhouette, else the dark outline.
    // @ref LLP 0001#how-the-phone-is-found
    private static func phone(in image: CGImage, size: CGSize) -> Shape? {
        func local(_ u: UnitRect) -> CGRect {
            CGRect(x: u.x * size.width, y: (1 - u.y - u.h) * size.height, width: u.w * size.width, height: u.h * size.height)
        }
        if let s = Bezel.silhouette(image) {
            let whole = local(s.rect)
            guard let b = Bezel.body(s.mask) else { return Shape(rect: whole, radius: whole.width * 0.12, mask: s.mask, maskRect: whole) }
            let body = local(UnitRect(x: s.rect.x + b.rect.x * s.rect.w, y: s.rect.y + b.rect.y * s.rect.h, w: b.rect.w * s.rect.w, h: b.rect.h * s.rect.h))
            return Shape(rect: body, radius: CGFloat(b.radius) * body.width, mask: s.mask, maskRect: whole)
        }
        if let o = Bezel.outline(image) {
            let r = local(o.rect)
            return Shape(rect: r, radius: CGFloat(o.radius) * r.width, mask: nil, maskRect: r)
        }
        return nil
    }

    private static func corners(of image: CGImage, size: CGSize) -> Shape? {
        let whole = CGRect(origin: .zero, size: size)
        return Shape(rect: whole, radius: Bezel.windowRadius(image).map { CGFloat($0) * size.width } ?? 0, mask: nil, maskRect: whole)
    }
}

private final class SourcePickerView: NSView {
    private weak var picker: SourcePicker?
    /// This screen's origin in global AppKit points.
    let origin: CGPoint

    init(picker: SourcePicker, origin: CGPoint) {
        self.picker = picker
        self.origin = origin
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func global(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
    }

    override func mouseMoved(with e: NSEvent) { picker?.moved(to: global(e), in: self) }
    // @ref LLP 0001#sources — a click only lights a candidate; a stray click never records
    override func mouseDown(with e: NSEvent) { picker?.moved(to: global(e), in: self) }
    override func rightMouseDown(with e: NSEvent) { picker?.cancel() }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: picker?.cancel()               // Escape
        case 36, 76: picker?.startLit()         // Return, Enter
        default: super.keyDown(with: e)
        }
    }

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0, alpha: PickerLook.dim).setFill()
        bounds.fill()
        guard let picker else { return }
        if let i = picker.lit {
            let o = picker.outline(i)
            var r = o.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            // A display's outline sits inside its edges, where it can be seen.
            if picker.kind == .display { r = r.insetBy(dx: PickerLook.outline, dy: PickerLook.outline) }
            if r.intersects(bounds) {
                let frame = picker.candidates[i].frame.offsetBy(dx: -origin.x, dy: -origin.y)
                light(r, radius: o.radius, shape: o.shape, at: frame.origin)
            }
        }
        if picker.isActive(self) { PickerLook.hint(picker.hint, in: bounds) }
    }

    /// The lit candidate: the dim lifted and a soft tint over exactly its shape, and a clear outline.
    private func light(_ r: CGRect, radius: CGFloat, shape: SourcePicker.Shape?, at origin: CGPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let tint = PickerLook.accent.withAlphaComponent(0.16)
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        if let shape, let mask = shape.mask {
            // A phone: lit along its silhouette, side buttons and all.
            let m = shape.maskRect.offsetBy(dx: origin.x, dy: origin.y)
            ctx.clip(to: m, mask: mask)
            ctx.setFillColor(tint.cgColor)
            ctx.fill(m)
        } else {
            tint.setFill()
            path.fill()
        }
        ctx.restoreGState()
        PickerLook.accent.setStroke()
        path.lineWidth = PickerLook.outline
        path.stroke()
    }
}

/// The lit candidate's card: its app's icon, its name, its size and the Start Recording button.
private final class InfoBlock: NSVisualEffectView {
    let start = PickerLook.startButton()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    /// The name's width, set from what its text needs (the cell's own measure, padding included), at most 300.
    private lazy var nameWidth = name.widthAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 16
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        size.textColor = NSColor(white: 1, alpha: 0.6)
        let stack = NSStackView(views: [icon, name, size, start])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(16, after: size)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 44),
            nameWidth,
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(name: String, icon: NSImage?, size: CGSize) {
        self.icon.image = icon
        self.icon.isHidden = icon == nil
        // A symbol (the display's) in white; an app's own icon as it is.
        self.icon.contentTintColor = icon?.isTemplate == true ? .white : nil
        self.name.stringValue = name
        // Whole unless longer than the card allows; then cut in the middle.
        nameWidth.constant = min(300, ceil(self.name.cell?.cellSize.width ?? 0) + 2)
        self.size.stringValue = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
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
    private let record = PickerLook.startButton()
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
        record.keyEquivalent = "\r"
        record.target = self
        record.action = #selector(start)
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
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
        NSColor(white: 0, alpha: PickerLook.dim).setFill()
        bounds.fill()
        guard let r = selection else {
            PickerLook.hint("Drag out an area · Esc cancels", in: bounds)
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
    private static let stills = CIContext()
    let id: String
    let folder: URL
    let kind: SourceKind
    let name: String
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// The system's sound, when asked for.
    private let ears: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "exact-studio.capture")
    private let pixelSize: CGSize
    /// Where the captured content is on screen, in global points, origin top-left;
    /// for a window it follows the window as it moves.
    private let frameOnScreen: () -> CGRect?
    private var firstTime: Double?
    private var lastTime: Double = 0
    private var crop: UnitRect = .full
    private var cornerRadius: Double?
    private var mask: String?
    private var detected = false
    private var frames = 0
    private let finding = DispatchGroup()
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
        if config.capturesAudio {
            let ears = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: config.sampleRate,
                AVNumberOfChannelsKey: config.channelCount, AVEncoderBitRateKey: 192_000,
            ])
            ears.expectsMediaDataInRealTime = true
            writer.add(ears)
            self.ears = ears
        } else {
            ears = nil
        }
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if ears != nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
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
        // Sound joins once the first frame has opened the file; sound from before it is dropped.
        if type == .audio {
            guard let ears, let first = firstTime, sample.isValid, sample.presentationTimeStamp.seconds >= first,
                  ears.isReadyForMoreMediaData else { return }
            ears.append(sample)
            return
        }
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        let pts = sample.presentationTimeStamp
        if firstTime == nil {
            firstTime = pts.seconds
            writer.startSession(atSourceTime: pts)
        }
        frames += 1
        // A few frames in, once the window has drawn: find the device's silhouette, off this queue.
        if !detected && frames >= 10 && (kind == .simulator || kind == .emulator || kind == .window) {
            detected = true
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = Recorder.stills.createCGImage(image, from: image.extent) {
                finding.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { finding.leave() }
                    if kind == .window {
                        let r = Bezel.windowRadius(cg)
                        queue.async { self.cornerRadius = r }
                    } else if let found = Bezel.silhouette(cg), let name = Library.saveMask(found.mask, in: folder) {
                        queue.async { self.crop = found.rect; self.mask = name }
                    } else if let outline = Bezel.outline(cg) {
                        queue.async { self.crop = outline.rect; self.cornerRadius = outline.radius }
                    } else if let alpha = Bezel.detect(buffer) {
                        queue.async { self.crop = alpha }
                    }
                }
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
        // Let the silhouette search land first.
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in finding.notify(queue: queue) { k.resume() } }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<RecordingMeta, Error>) in
            queue.async {
                guard let first = self.firstTime else {
                    self.writer.cancelWriting()
                    return k.resume(throwing: ExactStudioError("No frames arrived. Is Screen Recording allowed in System Settings › Privacy & Security?"))
                }
                self.input.markAsFinished()
                self.ears?.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(seconds: self.lastTime, preferredTimescale: 600))
                let cursor = self.cursor.filter { $0.0 >= first }.map { Point(t: $0.0 - first, x: $0.1.x, y: $0.1.y) }
                let point = { (e: (Double, CGPoint)) in Point(t: e.0 - first, x: e.1.x, y: e.1.y) }
                let clicks = self.clicks.filter { $0.0 >= first }.map(point)
                let releases = self.releases.filter { $0.0 >= first }.map(point)
                let meta = RecordingMeta(id: self.id, name: self.name, kind: self.kind.rawValue,
                                         created: Date().timeIntervalSince1970 * 1000, duration: self.lastTime - first,
                                         width: self.pixelSize.width, height: self.pixelSize.height, crop: self.crop, clicks: clicks,
                                         releases: releases, cornerRadius: self.cornerRadius, device: nil, mask: self.mask, maskRect: self.mask == nil ? nil : self.crop, cursorBaked: false)
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

    static func make(source: String, area: (NSScreen, CGRect)?, folder: URL, id: String, sound: Bool) async throws -> Recorder {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // The cursor is drawn by the editor from the recorded path, so it can be hidden, resized and animated.
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        // The system's sound (a window's: its app's), never this app's own.
        config.capturesAudio = sound
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
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

    /// A silhouette written beside the recording, under a new name each time so no cache holds the old one.
    static func saveMask(_ mask: CGImage, in folder: URL) -> String? {
        let name = "mask-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        guard let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, mask, nil)
        return CGImageDestinationFinalize(dest) ? name : nil
    }

    static func save(_ meta: RecordingMeta) throws {
        try JSONEncoder().encode(meta).write(to: recordings.appendingPathComponent(meta.id).appendingPathComponent("meta.json"))
    }
}
#endif
