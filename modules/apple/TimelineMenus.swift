// @ref LLP 0005#add-where-it-goes
#if os(macOS)
import Foundation

enum MenuEntry {
    case title(String)
    case item(String, () -> Void)
    case off(String, String)
    case sub(String, [MenuEntry])
    case line
}

enum Plus {
    case menu([MenuEntry])
    case direct(() -> Void)
}

enum TimelineRow: Equatable {
    case position
    case header(String)
    case lane(Int, Int)
    case imagePosition(String)
    case imageEffects(String, Int)
}

enum TimelineMenus {
    static func clock(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d.%d", m, sec, Int((s - floor(s)) * 10))
    }

    static func kindName(_ space: Int) -> String {
        space == 1 ? "Text" : space == 2 ? "Image" : space == 3 ? "Whole Frame" : space == Edits.soundSpace ? "Sound" : "Effects"
    }

    static func laneName(_ space: Int, _ lane: Int) -> String { "\(kindName(space)) \(lane + 1)" }

    static func scope(_ space: Int) -> String {
        space == 1 || space == 2 ? "Sits on top of the video" : space == 3 ? "Changes the whole picture"
            : space == Edits.soundSpace ? "Plays over the video" : "Changes the video only"
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
        let frame: [MenuEntry] = [.item("Blur") { editor.add("blur-frame") }, .item("Black & White") { editor.add("mono-frame") }]
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
            return .menu([.title("Move the video at \(at)"), .title("Then drag the video where it should go."), .line,
                          .item("Add Move Here") { editor.addMove() },
                          .sub("Motion Patterns", [.item("Side to Side") { editor.pattern("side") }, .item("Zoom Tour") { editor.pattern("tour") },
                                                   .item("Entrance") { editor.pattern("entrance") }, .item("Bounce") { editor.pattern("bounce") },
                                                   .item("Slow Push In") { editor.pattern("drift") }]),
                          .sub("3D Patterns", [.item("Turntable") { editor.pattern("turntable") }, .item("Orbit") { editor.pattern("orbit") },
                                               .item("Hero Reveal") { editor.pattern("reveal") }, .item("Flip In") { editor.pattern("flip") },
                                               .item("Float") { editor.pattern("float") }])])
        case .header("top"):
            return .menu([.title("Add on top of the video at \(at)"), .title("It goes on the first free lane of its kind."), .line,
                          .item("Text") { editor.add("text") }, .item("Image…") { Pictures.pick { editor.addImage($0) } }])
        case .header("sound"):
            return .direct { Sounds.pick { editor.addSound($0) } }
        case .header("frame"):
            return .menu([.title("Add over the whole frame at \(at)"), .title("It goes on the first free lane."), .line] + frame)
        case .header:
            return nil
        case let .lane(space, lane):
            guard lane < editor.edits.laneCount(space: space) else { return nil }
            switch space {
            case 1: return .direct { editor.onLane(lane) { editor.add("text") } }
            case 2: return .direct { Pictures.pick { url in editor.onLane(lane) { editor.addImage(url) } } }
            case Edits.soundSpace: return .direct { Sounds.pick { url in editor.onLane(lane) { editor.addSound(url) } } }
            default:
                return .menu([.title("Add to \(laneName(space, lane)) at \(at) · \(scope(space))"), .line] + on(lane, space == 3 ? frame : effects))
            }
        case let .imagePosition(id):
            return .direct { editor.select(id); editor.addImageMove() }
        case let .imageEffects(id, lane):
            guard lane == 0 else { return nil }
            let name = URL(fileURLWithPath: editor.edits.images.first { $0.id == id }?.file ?? "").lastPathComponent
            let add = { (kind: String) in { editor.select(id); editor.addImageEffect(kind) } }
            return .menu([.title("Add to \(name) at \(at) · Changes this image only"), .line,
                          .item("Blur", add("blur")), .item("Black & White", add("mono")), .item("Fade", add("fade")), .line,
                          .item("Pulse", add("pulse")), .item("Float", add("float")), .item("Wiggle", add("wiggle"))])
        }
    }
}

extension Array where Element == MenuEntry {
    var choices: [String] {
        flatMap { entry -> [String] in
            switch entry {
            case let .item(title, _), let .off(title, _): return [title]
            case let .sub(title, inner): return inner.choices.map { "\(title) › \($0)" }
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
            case let .sub(title, inner) where parts.count > 1 && title == parts[0]: return inner.run(parts.dropFirst().joined(separator: " › "))
            default: continue
            }
        }
        return false
    }

    func reason(_ title: String) -> String? {
        for case let .off(t, why) in self where t == title { return why }
        return nil
    }
}
#endif
