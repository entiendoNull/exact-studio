// @ref LLP 0005#add-where-it-goes
#if os(macOS)
import Foundation

enum MenuEntry {
    case title(String)
    case item(String, () -> Void)
    case off(String, String)
    case check(String, Bool, () -> Void)
    /// An item with a second line under its name that says what it changes.
    case two(String, String, () -> Void)
    /// A submenu with a second line under its name.
    case sub2(String, String, [MenuEntry])
    case dim(String)
    case sub(String, [MenuEntry])
    case line
}

enum Plus {
    case menu([MenuEntry])
    case direct(() -> Void)
}

enum TimelineRow: Equatable {
    case position
    case lane(Int, Int)
    case imagePosition(String)
    case imageEffects(String, Int)
}

enum TimelineMenus {
    static func clock(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d.%d", m, sec, Int((s - floor(s)) * 10))
    }

    // @ref LLP 0002#rows — plain names; a second row of a kind adds a number, one row has none
    static func kindName(_ space: Int) -> String {
        space == 1 ? "Text" : space == 2 ? "Images" : space == Edits.soundSpace ? "Music & Sound" : "Effects"
    }

    static func laneName(_ space: Int, _ lane: Int) -> String { lane == 0 ? kindName(space) : "\(kindName(space)) \(lane + 1)" }

    static func scope(_ space: Int) -> String {
        space == 1 || space == 2 ? "Sits on top of the video" : space == Edits.soundSpace ? "Plays over the video" : "Changes the video only"
    }

    /// The Move submenu: a move at the playhead, or a pattern of them.
    static func moves(_ editor: Editor) -> [MenuEntry] {
        [.item("Add Move Here") { editor.addMove() },
         .sub("Motion Patterns", [.item("Side to Side") { editor.pattern("side") }, .item("Zoom Tour") { editor.pattern("tour") },
                                  .item("Entrance") { editor.pattern("entrance") }, .item("Bounce") { editor.pattern("bounce") },
                                  .item("Slow Push In") { editor.pattern("drift") }]),
         .sub("3D Patterns", [.item("Turntable") { editor.pattern("turntable") }, .item("Orbit") { editor.pattern("orbit") },
                              .item("Hero Reveal") { editor.pattern("reveal") }, .item("Flip In") { editor.pattern("flip") },
                              .item("Float") { editor.pattern("float") }])]
    }

    // @ref LLP 0005#refusals — a menu checks the playhead first: an item that would be refused is off, with its reason
    static func checked(_ entries: [MenuEntry], _ editor: Editor) -> [MenuEntry] {
        entries.map { entry in
            switch entry {
            case let .item(title, run) where !title.hasSuffix("…"): return editor.probe(run).map { .off(title, $0.menuText) } ?? entry
            case let .two(title, _, run) where !title.hasSuffix("…"): return editor.probe(run).map { .off(title, $0.menuText) } ?? entry
            case let .sub(title, inner): return .sub(title, checked(inner, editor))
            case let .sub2(title, line, inner): return .sub2(title, line, checked(inner, editor))
            default: return entry
            }
        }
    }

    /// + Add, the first control of the timeline bar: every kind of thing, at the playhead, each with what it changes.
    // @ref LLP 0005#add-where-it-goes
    static func add(_ editor: Editor) -> [MenuEntry] {
        checked([
            .title("Add at \(clock(editor.playhead))"), .line,
            .two("Text", "On top of the video") { editor.add("text") },
            .two("Image…", "On top of the video") { Pictures.pick { editor.addImage($0) } },
            .line,
            .sub2("Zoom", "Pushes in on the cursor, or out", [.item("Zoom In") { editor.add("zoom-in") }, .item("Zoom Out") { editor.add("zoom-out") },
                                                               .item("Zoom on Clicks") { editor.autoZoom() }]),
            .sub2("Effect", "The video, or the whole frame", [
                .sub("Speed", [.item("Slow Down") { editor.add("slow") }, .item("Speed Up") { editor.add("fast") }]),
                .item("Spotlight") { editor.add("spotlight") }, .item("Cursor Highlight") { editor.add("highlight") },
                .item("Blur") { editor.add("blur") }, .item("Black & White") { editor.add("mono") },
                .item("Mask") { editor.add("mask") }, .item("3D Turn") { editor.add("3d") }]),
            .sub2("Move", "Where the video goes", [.title("Then drag the video where it should go."), .line] + moves(editor)),
            .line,
            .two("Music & Sound…", "Plays over the video") { Sounds.pick { editor.addSound($0) } },
        ], editor)
    }

    static func plus(_ row: TimelineRow, _ editor: Editor) -> Plus? {
        let at = clock(editor.playhead)
        let effects: [MenuEntry] = [
            .sub("Zoom", [.item("Zoom In") { editor.add("zoom-in") }, .item("Zoom Out") { editor.add("zoom-out") },
                          .item("Zoom on Clicks") { editor.autoZoom() }]),
            .sub("Speed", [.item("Slow Down") { editor.add("slow") }, .item("Speed Up") { editor.add("fast") }]),
            .sub("Look", [.item("Spotlight") { editor.add("spotlight") }, .item("Cursor Highlight") { editor.add("highlight") },
                          .item("Blur") { editor.add("blur") }, .item("Black & White") { editor.add("mono") }]),
            .item("Mask") { editor.add("mask") },
            .item("3D Turn") { editor.add("3d") },
        ]
        func checked(_ entries: [MenuEntry]) -> [MenuEntry] { TimelineMenus.checked(entries, editor) }
        func on(_ lane: Int, _ entries: [MenuEntry]) -> [MenuEntry] {
            entries.map { entry in
                switch entry {
                case let .item(title, run): return .item(title) { editor.onLane(lane, run) }
                case let .sub(title, inner): return .sub(title, on(lane, inner))
                default: return entry
                }
            }
        }
        switch row {
        case .position:
            return .menu(checked([.title("Move the video at \(at)"), .title("Then drag the video where it should go."), .line,
                          ] + moves(editor)))
        case let .lane(space, lane):
            guard lane <= editor.edits.laneCount(space: space) else { return nil }
            switch space {
            case 1: return .direct { editor.onLane(lane) { editor.add("text") } }
            case 2: return .direct { Pictures.pick { url in editor.onLane(lane) { editor.addImage(url) } } }
            case Edits.soundSpace: return .direct { Sounds.pick { url in editor.onLane(lane) { editor.addSound(url) } } }
            default:
                return .menu(checked([.title("Add to \(laneName(space, lane)) at \(at) · \(scope(space))"), .line] + on(lane, effects)))
            }
        case let .imagePosition(id):
            return .direct { editor.select(id); editor.addImageMove() }
        case let .imageEffects(id, lane):
            guard lane == 0, let item = editor.edits.segments.first(where: { $0.id == id && $0.isOverlay }) else { return nil }
            let add = { (kind: String) in { editor.select(id); editor.addItemEffect(kind) } }
            if item.kind == "text" {
                return .menu(checked([.title("Add to “\(item.text ?? "")” at \(at) · Changes this text only"), .line,
                              .item("Blur", add("blur")), .item("Black & White", add("mono")), .item("Fade", add("fade"))]))
            }
            let name = URL(fileURLWithPath: item.file ?? "").lastPathComponent
            return .menu(checked([.title("Add to \(name) at \(at) · Changes this image only"), .line,
                          .item("Blur", add("blur")), .item("Black & White", add("mono")), .item("Fade", add("fade")), .line,
                          .item("Pulse", add("pulse")), .item("Float", add("float")), .item("Wiggle", add("wiggle"))]))
        }
    }
}

extension TimelineMenus {
    static func noun(_ space: Int, _ n: Int) -> String {
        let one = space == 1 ? "Text" : space == 2 ? "Image" : space == Edits.soundSpace ? "Sound" : "Effect"
        return n == 1 ? "1 \(one)" : "\(n) \(one)s"
    }

    // @ref LLP 0005#the-lane-menu
    static func lane(_ space: Int, _ lane: Int, _ editor: Editor, confirm: @escaping (String, String, @escaping () -> Void) -> Void) -> [MenuEntry] {
        let count = editor.edits.laneCount(space: space)
        guard lane < count else { return [] }
        let name = laneName(space, lane), items = editor.laneItems(lane, space: space)
        var out: [MenuEntry] = [.title("\(name) · \(scope(space))"), .line]
        var canUp = lane > 0, canDown = lane < count - 1
        // @ref LLP 0005#layers — a text or image row moves through the whole stack, past the video too
        if space == 1 || space == 2 {
            let stack = editor.edits.stack(), at = stack.firstIndex(of: LayerRow(kind: space == 1 ? "text" : "image", lane: lane)) ?? 0
            canUp = at > 0; canDown = at < stack.count - 1
        }
        out.append(canUp ? .item("Move Lane Up") { editor.moveLane(lane, space: space, by: -1) } : .dim("Move Lane Up"))
        out.append(canDown ? .item("Move Lane Down") { editor.moveLane(lane, space: space, by: 1) } : .dim("Move Lane Down"))
        out.append(.line)
        if items == 0 {
            out.append(.item("Delete Lane") { editor.deleteLane(lane, space: space) })
        } else {
            let what = noun(space, items)
            out.append(.item("Delete Lane and Its \(what)…") {
                confirm("Delete \(name) and its \(what.lowercased())?", "You can undo this with ⌘Z.") { editor.deleteLane(lane, space: space) }
            })
        }
        out += [.line, .check("Show Empty Lanes", editor.showEmptyLanes) { editor.setShowEmptyLanes(!editor.showEmptyLanes) }]
        return out
    }
}

extension Array where Element == MenuEntry {
    var choices: [String] {
        flatMap { entry -> [String] in
            switch entry {
            case let .item(title, _), let .off(title, _), let .dim(title), let .check(title, _, _), let .two(title, _, _): return [title]
            case let .sub(title, inner), let .sub2(title, _, inner): return inner.choices.map { "\(title) › \($0)" }
            default: return []
            }
        }
    }

    var titles: [String] { compactMap { if case let .title(t) = $0 { return t } else { return nil } } }

    @discardableResult
    func run(_ path: String) -> Bool {
        let parts = path.components(separatedBy: " › ")
        for entry in self {
            switch entry {
            case let .item(title, run) where parts.count == 1 && title == parts[0]: run(); return true
            case let .check(title, _, run) where parts.count == 1 && title == parts[0]: run(); return true
            case let .two(title, _, run) where parts.count == 1 && title == parts[0]: run(); return true
            case let .sub2(title, _, inner) where parts.count > 1 && title == parts[0]: return inner.run(parts.dropFirst().joined(separator: " › "))
            case let .sub(title, inner) where parts.count > 1 && title == parts[0]: return inner.run(parts.dropFirst().joined(separator: " › "))
            default: continue
            }
        }
        return false
    }

    func reason(_ title: String) -> String? {
        for entry in self {
            switch entry {
            case let .off(t, why) where t == title: return why
            case let .sub(_, inner), let .sub2(_, _, inner): if let why = inner.reason(title) { return why }
            default: continue
            }
        }
        return nil
    }

    /// The second line of an item or a submenu.
    func line(_ title: String) -> String? {
        for entry in self {
            switch entry {
            case let .two(t, line, _) where t == title: return line
            case let .sub2(t, line, _) where t == title: return line
            default: continue
            }
        }
        return nil
    }
}
#endif
