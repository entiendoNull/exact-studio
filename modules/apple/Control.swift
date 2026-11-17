// Control: how an agent records without a person. The command-line tool drops a
// request file into a private folder; the running app answers with a reply file.
// The app records, so the Screen Recording permission, the red menu bar mark and
// the library are the app's, as when a person records.
// Compiled into the app (Studio.swift serves it) and into ./exact-studio (the client).
// @ref LLP 0007#the-channel — a private folder of request and reply files, no network
import Foundation

enum Control {
    /// ~/Library/Application Support/Exact Studio/control, or EXACT_STUDIO_CONTROL.
    static var folder: URL {
        if let f = ProcessInfo.processInfo.environment["EXACT_STUDIO_CONTROL"], !f.isEmpty { return URL(fileURLWithPath: f, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exact Studio/control", isDirectory: true)
    }
    static func requests(_ root: URL) -> URL { root.appendingPathComponent("requests", isDirectory: true) }
    static func replies(_ root: URL) -> URL { root.appendingPathComponent("replies", isDirectory: true) }
    /// The running app's pid, written when it starts serving and removed when it stops.
    static func presence(_ root: URL) -> URL { root.appendingPathComponent("app.json") }
    /// What a request's file is called: its id and ".json", nothing else.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    /// Makes the folder and its two subfolders, owned by this user and closed to others (0700).
    /// Throws when one is a link, is someone else's, or others can get in.
    // @ref LLP 0007#same-user-only
    static func prepare(_ root: URL) throws {
        for dir in [root, requests(root), replies(root)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var s = stat()
            guard lstat(dir.path, &s) == 0 else { throw ControlError("can't read \(dir.path)") }
            guard (s.st_mode & S_IFMT) == S_IFDIR else { throw ControlError("\(dir.path) is not a plain folder") }
            guard s.st_uid == getuid() else { throw ControlError("\(dir.path) belongs to another user") }
            if s.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
            guard lstat(dir.path, &s) == 0, s.st_mode & 0o077 == 0 else { throw ControlError("\(dir.path) is open to other users; make it 0700") }
        }
    }

    /// A regular file this user owns, not a link.
    static func ownFile(_ url: URL) -> Bool {
        var s = stat()
        return lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == getuid()
    }

    /// Writes JSON to `url` through a temporary file in the same folder, readable by this user only.
    static func put(_ object: [String: Any], _ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ControlError("can't write in \(tmp.deletingLastPathComponent().path)")
        }
        guard rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw ControlError("can't write \(url.path)") }
    }

    static func read(_ url: URL) -> [String: Any]? {
        guard ownFile(url), let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The pid in the presence file, when that process is alive.
    static func runningApp(_ root: URL) -> Int32? {
        guard let p = read(presence(root)), let pid = (p["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
    }
}

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: Sources by name

/// One thing that can be recorded, as the app lists it for agents.
// @ref LLP 0007#names
struct SourceEntry: Equatable {
    /// What the app records: "display:<CGDirectDisplayID>" or "window:<CGWindowID>".
    var id: String
    /// display, window, simulator or emulator.
    var kind: String
    /// A display's name, a window's "App — Title" (or the app alone), a device's window title.
    var name: String
    var app: String = ""
    var title: String = ""
    /// Points.
    var width: Int = 0, height: Int = 0
    /// What `record start` takes: unique within the list it came from.
    var ref: String = ""

    init(id: String, kind: String, name: String, app: String = "", title: String = "", width: Int = 0, height: Int = 0) {
        self.id = id; self.kind = kind; self.name = name; self.app = app; self.title = title; self.width = width; self.height = height
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let kind = d["kind"] as? String, let name = d["name"] as? String else { return nil }
        self.init(id: id, kind: kind, name: name, app: d["app"] as? String ?? "", title: d["title"] as? String ?? "",
                  width: (d["width"] as? NSNumber)?.intValue ?? 0, height: (d["height"] as? NSNumber)?.intValue ?? 0)
    }

    var json: [String: Any] { ["id": id, "kind": kind, "name": name, "app": app, "title": title, "width": width, "height": height, "ref": ref] }

    /// The word before the colon in a ref: an emulator is listed with the Simulators, as in the sidebar.
    var group: String { kind == "emulator" ? "simulator" : kind }
    var number: String { String(id.split(separator: ":").last ?? "") }

    /// Gives each entry its ref: "display:1" (in the list's order), else "<group>:<name>",
    /// and "<group>:#<number>" for entries whose name another entry of the group shares.
    static func named(_ list: [SourceEntry]) -> [SourceEntry] {
        var displays = 0
        let counts = Dictionary(list.map { ("\($0.group):\($0.name.lowercased())", 1) }, uniquingKeysWith: +)
        return list.map { e in
            var e = e
            if e.kind == "display" { displays += 1; e.ref = "display:\(displays)" }
            else if counts["\(e.group):\(e.name.lowercased())"]! > 1 || e.name.isEmpty { e.ref = "\(e.group):#\(e.number)" }
            else { e.ref = "\(e.group):\(e.name)" }
            return e
        }
    }

    /// One line for a list: the ref, then what it is.
    var line: String {
        var what: [String] = []
        if !ref.hasSuffix(":" + name) { what.append(name) }
        if kind == "emulator" { what.append("Android emulator") }
        return ref + (what.isEmpty ? "" : "  (\(what.joined(separator: ", ")))") + "  \(width)×\(height)"
    }
}

/// What a `record start` source names, on a fixed list.
enum SourcePick: Equatable {
    case source(SourceEntry)
    /// An area of a display, in its points, origin top-left.
    case area(SourceEntry, x: Double, y: Double, w: Double, h: Double)
    case problem(String)
}

// @ref LLP 0007#names — matching is pure, on the list the app gave, so it is tested without the app
enum SourceMatch {
    static let groups = ["display", "window", "simulator", "emulator", "area"]

    static func pick(_ query: String, in raw: [SourceEntry]) -> SourcePick {
        let list = raw.first?.ref.isEmpty == false ? raw : SourceEntry.named(raw)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .problem("Name a source to record. These can be recorded now:\n" + listing(list)) }
        var group: String?, text = q
        if let colon = q.firstIndex(of: ":"), groups.contains(q[..<colon].lowercased()) {
            group = q[..<colon].lowercased()
            text = String(q[q.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if groups.contains(q.lowercased()) {
            group = q.lowercased(); text = ""
        }
        if group == "area" { return area(text, in: list) }
        let pool = list.filter { e in group == nil || e.group == group || e.kind == group }
        let what = group.map { $0 == "display" ? "display" : $0 == "window" ? "window" : "Simulator or emulator" } ?? "source"
        func one(_ hits: [SourceEntry]) -> SourcePick? {
            if hits.count == 1 { return .source(hits[0]) }
            if hits.count > 1 { return .problem("\"\(q)\" matches \(hits.count) sources. Name one of them:\n" + listing(hits)) }
            return nil
        }
        if pool.isEmpty {
            return .problem("There is no \(what) to record now." + (group == "simulator" || group == "emulator" ? " Open a Simulator or an emulator first." : "")
                            + (list.isEmpty ? "" : " These can be recorded:\n" + listing(list)))
        }
        if text.isEmpty {
            return one(pool)!
        }
        let t = text.lowercased()
        if t.hasPrefix("#") {
            if let hit = one(pool.filter { $0.number == String(t.dropFirst()) }) { return hit }
        }
        if group == "display", let n = Int(t) {
            let displays = list.filter { $0.kind == "display" }
            if n >= 1 && n <= displays.count { return .source(displays[n - 1]) }
            return .problem("There is no display \(n). Displays:\n" + listing(displays))
        }
        // Whole names first, then a part of one.
        let exact = pool.filter { e in [e.ref, String(e.ref.drop { $0 != ":" }.dropFirst()), e.name, e.app, e.title].contains { $0.lowercased() == t } }
        if let hit = one(exact) { return hit }
        let part = pool.filter { e in e.name.lowercased().contains(t) || e.app.lowercased().contains(t) }
        if let hit = one(part) { return hit }
        return .problem("No \(what) matches \"\(text)\". These can be recorded now:\n" + listing(group == nil ? list : pool))
    }

    /// "x,y,w,h" in points of display 1, or "x,y,w,h@<display>".
    private static func area(_ text: String, in list: [SourceEntry]) -> SourcePick {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        let nums = (parts.first ?? "").split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        let usage = "An area is area:x,y,w,h in points from the display's top-left corner, optionally @<display> (default @1), for example area:0,0,1280,800@2."
        guard nums.count == 4, nums.allSatisfy({ $0 != nil }) else { return .problem(usage) }
        let (x, y, w, h) = (nums[0]!, nums[1]!, nums[2]!, nums[3]!)
        let displays = list.filter { $0.kind == "display" }
        guard case let .source(d) = pick("display:\(parts.count > 1 ? parts[1] : "1")", in: displays.isEmpty ? list : displays), d.kind == "display" else {
            return .problem("There is no such display. Displays:\n" + listing(displays))
        }
        guard w >= 40, h >= 40 else { return .problem("An area must be at least 40×40 points. " + usage) }
        guard x >= 0, y >= 0, x + w <= Double(d.width), y + h <= Double(d.height) else {
            return .problem("That area is not inside \(d.ref) (\(d.name)), which is \(d.width)×\(d.height) points.")
        }
        return .area(d, x: x, y: y, w: w, h: h)
    }

    static func listing(_ list: [SourceEntry]) -> String {
        list.isEmpty ? "  (nothing)" : list.map { "  " + $0.line }.joined(separator: "\n")
    }
}

// MARK: The app's side

/// Watches the request folder and answers each request through `handle`, on the main queue.
/// A request is a JSON file `requests/<id>.json` with `op` and `expires` (seconds since 1970);
/// its reply is `replies/<id>.json`. An expired request is dropped unanswered.
final class ControlServer {
    let root: URL
    private let handle: (_ request: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()

    init(root: URL = Control.folder, handle: @escaping (_ request: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void) {
        self.root = root
        self.handle = handle
    }

    func start() throws {
        try Control.prepare(root)
        // Leftovers from a run that ended: nobody waits for them.
        let fm = FileManager.default
        for dir in [Control.requests(root), Control.replies(root)] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] { unlink(dir.appendingPathComponent(name).path) }
        }
        try Control.put(["pid": Int(getpid()), "since": Date().timeIntervalSince1970], Control.presence(root))
        let fd = open(Control.requests(root).path, O_EVTONLY)
        guard fd >= 0 else { throw ControlError("can't watch \(Control.requests(root).path)") }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        // A request written between the presence file and the watch would wait for the next one.
        DispatchQueue.main.async { [weak self] in self?.scan() }
    }

    func stop() {
        source?.cancel()
        source = nil
        if Control.runningApp(root) == getpid() { unlink(Control.presence(root).path) }
    }

    private func scan() {
        // Two copies of the app may watch one folder; only the one the presence file names answers,
        // so a request never starts two recordings.
        guard Control.runningApp(root) == getpid() else { return }
        let dir = Control.requests(root)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            let url = dir.appendingPathComponent(name)
            guard Control.validID(id), !seen.contains(id) else { continue }
            let request = Control.read(url)
            unlink(url.path)
            guard let request, (request["expires"] as? NSNumber)?.doubleValue ?? 0 > Date().timeIntervalSince1970 else { continue }
            seen.insert(id)
            handle(request) { [root] answer in
                try? Control.put(answer, Control.replies(root).appendingPathComponent("\(id).json"))
            }
        }
    }
}
