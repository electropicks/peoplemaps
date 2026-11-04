import Foundation

/// Which downloaded region the app loads. `Bundle.dataFile` asks here first, so the graph, map, search index and coverage all come from
/// one region and never from both. The choice is read once per launch (`launchFolder`) and changes only on `reload()`, which the app calls
/// at launch or when the person taps Switch now with no route active.
///
/// On disk: `Regions/selection.json` names the release and region to use; `Regions/<release>/<region>/` holds its files and a `.complete`
/// marker that `RegionStore` writes last. A folder marked `.removed` is waiting for the next launch to be deleted.
public enum RegionSelection {
    struct Chosen: Codable, Equatable { var release: String; var region: String }
    private struct State {
        var root: URL?
        var launch: (folder: URL, region: RegionID)?
        var loaded = false
        var suppressed = false
        var fellBack = false
    }
    nonisolated(unsafe) private static var state = State()
    private static let lock = NSLock()

    static let completeMarker = ".complete", removedMarker = ".removed", selectionFile = "selection.json"

    /// `Application Support/Regions`, or what `configure(root:)` set (UI tests and unit tests use their own).
    public static var root: URL {
        lock.lock(); defer { lock.unlock() }
        return state.root ?? defaultRoot
    }
    public static var defaultRoot: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Regions", isDirectory: true)
    }
    /// Points the app at another folder and forgets what was loaded. Call before the first data file is asked for.
    public static func configure(root: URL?) {
        lock.lock(); defer { lock.unlock() }
        state = State(root: root)
    }

    /// The folder this launch loads from; nil when it loads the bundled Seattle data.
    public static var launchFolder: URL? { ensureLoaded().launch?.folder }
    public static var launchRegion: RegionID? { ensureLoaded().launch?.region }
    /// The downloaded King County map is the one in use.
    public static var usesCounty: Bool { launchRegion == "king-county" }
    /// "King County" once that map is in use, else "Seattle": for labels that name the area on screen.
    public static var areaName: String { usesCounty ? "King County" : "Seattle" }
    /// What the map covers once King County is the map in use. Before then the Seattle wording stays.
    public static let coverageSentence = "PeopleMaps covers King County and a little beyond."
    /// A place inside coverage that no road route reaches.
    public static let noRoadRouteSentence = "No road route to this place in PeopleMaps. It may need a ferry or a road outside the map, as Vashon, the Kitsap shore and Skykomish do."
    /// A region was selected but its files would not load, so Seattle was used instead (set by `suppress()`).
    public static var fellBack: Bool { lock.lock(); defer { lock.unlock() }; return state.fellBack }

    /// A file of the region in use, when there is one and it exists.
    public static func file(_ name: String) -> URL? {
        guard let folder = launchFolder else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Starts over from what is on disk: the next `file(_:)` reads the current selection. Returns whether the folder in use changed.
    @discardableResult public static func reload() -> Bool {
        lock.lock()
        let before = state.launch?.folder
        let root = state.root
        state = State(root: root)
        lock.unlock()
        return before != launchFolder
    }

    /// Stops using the selected region for the rest of this launch because its files failed to load.
    public static func suppress() {
        lock.lock(); defer { lock.unlock() }
        state.launch = nil; state.loaded = true; state.suppressed = true; state.fellBack = true
    }

    /// What is selected on disk right now, if its files are complete.
    public static func current() -> (folder: URL, region: RegionID)? { current(root: Self.root) }

    static func current(root: URL) -> (folder: URL, region: RegionID)? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(selectionFile)),
              let chosen = try? JSONDecoder().decode(Chosen.self, from: data) else { return nil }
        let folder = root.appendingPathComponent(chosen.release, isDirectory: true).appendingPathComponent(chosen.region, isDirectory: true)
        return isUsable(folder) ? (folder, chosen.region) : nil
    }

    /// A different region is selected than the one this launch loaded, so it will load at the next launch.
    public static var switchPending: Bool {
        let launch = ensureLoaded()
        if launch.suppressed { return false }
        return current()?.folder != launch.launch?.folder
    }

    static func select(root: URL, release: String, region: RegionID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Chosen(release: release, region: region)).write(to: root.appendingPathComponent(selectionFile), options: .atomic)
    }

    static func clearSelection(root: URL, ifRegion region: RegionID? = nil) {
        let url = root.appendingPathComponent(selectionFile)
        if let region, let data = try? Data(contentsOf: url), let chosen = try? JSONDecoder().decode(Chosen.self, from: data), chosen.region != region { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isUsable(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(completeMarker).path) && !fm.fileExists(atPath: folder.appendingPathComponent(removedMarker).path)
    }

    private static func ensureLoaded() -> (launch: (folder: URL, region: RegionID)?, suppressed: Bool) {
        lock.lock()
        if state.loaded { defer { lock.unlock() }; return (state.launch, state.suppressed) }
        lock.unlock()
        let chosen = current()
        lock.lock(); defer { lock.unlock() }
        if !state.loaded { state.launch = chosen; state.loaded = true }
        return (state.launch, state.suppressed)
    }
}
