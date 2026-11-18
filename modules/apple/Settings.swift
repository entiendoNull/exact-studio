#if os(macOS)
import Foundation

enum Settings {
    private(set) static var store = UserDefaults.standard
    static let foldedKey = "ExactStudio.foldedGroups"
    static let emptyLanesKey = "ExactStudio.showEmptyLanes"

    static var showEmptyLanes: Bool {
        get { store.bool(forKey: emptyLanesKey) }
        set { store.set(newValue, forKey: emptyLanesKey) }
    }

    static func isolate(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = UserDefaults(suiteName: folder.appendingPathComponent("settings").path)!
    }

    // @ref LLP 0005#fold-everything-pick-a-size
    static var folded: Set<String> {
        if let groups = store.stringArray(forKey: foldedKey) { return Set(groups) }
        let kept = Set(store.stringArray(forKey: "ExactStudio.folded") ?? []).subtracting(["video"])
        store.set(kept.sorted(), forKey: foldedKey)
        store.removeObject(forKey: "ExactStudio.folded")
        store.removeObject(forKey: "ExactStudio.videoClosed")
        return kept
    }
}
#endif
