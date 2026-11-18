#if os(macOS)
import Foundation

enum Settings {
    private(set) static var store = UserDefaults.standard
    static let emptyLanesKey = "ExactStudio.showEmptyLanes"

    static var showEmptyLanes: Bool {
        get { store.bool(forKey: emptyLanesKey) }
        set { store.set(newValue, forKey: emptyLanesKey) }
    }

    static func isolate(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = UserDefaults(suiteName: folder.appendingPathComponent("settings").path)!
    }

    /// The timeline's groups are gone, so their folds are too: the keys go once, and nothing stays folded.
    // @ref LLP 0005#fold-everything-pick-a-size
    static let oldFoldKeys = ["ExactStudio.foldedGroups", "ExactStudio.folded", "ExactStudio.videoClosed"]

    static func dropOldFolds() {
        oldFoldKeys.forEach { store.removeObject(forKey: $0) }
    }
}
#endif
