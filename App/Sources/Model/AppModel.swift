import AppKit
import MacDiskSleuthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    /// The one model, shared by the SwiftUI scene and the Services provider
    /// (a Finder Quick Action can arrive before any view exists).
    static let shared = AppModel()

    enum Phase {
        case welcome
        case scanning
        case results
    }

    var phase: Phase = .welcome
    var progress = ScanProgress.zero
    var graph: FileGraph?
    var volume: VolumeIdentity?
    var scanError: String?
    /// "Top things to delete" for the current graph; nil while being computed.
    var recommendations: RecommendationReport?
    /// The context the current recommendations were computed with (paths display relative to it).
    var recommendationContext = RecommendationContext()
    /// Whether the recommendations sheet is showing over the results.
    var showRecommendations = false
    /// Post a macOS notification with the top finds when a scan completes. Persisted.
    var notifyOnScanComplete: Bool = UserDefaults.standard.object(forKey: "notifyOnScanComplete") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyOnScanComplete, forKey: "notifyOnScanComplete") }
    }
    /// Bumped whenever `graph` is replaced (fresh scan, deletion) so views
    /// with cached derived layout know to recompute.
    var graphStamp = 0

    var lens: SizeLens = .physical
    var focus = NodeID(raw: 0)
    var selection: NodeID?
    var hovered: NodeID?
    /// Results open on the volume-level view (total vs used); drilling in
    /// enters the folder sunburst, and going up from the scan root returns here.
    var atOverview = true

    /// User-set text scale, persisted. 1.0 = stock macOS sizes; the default
    /// leans larger on purpose.
    var textScale: Double = AppModel.loadTextScale() {
        didSet {
            let clamped = min(max(textScale, Self.minTextScale), Self.maxTextScale)
            if clamped != textScale {
                textScale = clamped
                return
            }
            UserDefaults.standard.set(textScale, forKey: "textScale")
        }
    }

    static let minTextScale = 0.8
    static let maxTextScale = 2.0

    private static func loadTextScale() -> Double {
        let stored = UserDefaults.standard.object(forKey: "textScale") as? Double ?? 1.2
        return min(max(stored, minTextScale), maxTextScale)
    }

    func increaseTextSize() { textScale += 0.1 }
    func decreaseTextSize() { textScale -= 0.1 }
    func resetTextSize() { textScale = 1.2 }

    // Sidebar facts, refreshed on launch and after scans.
    var fdaStatus: FDAStatus = .unknown
    var capacities: VolumeCapacities?
    var snapshots: [SnapshotInfo] = []
    var scannedPath: String = ""

    private var session: ScanSession?
    /// Guards against a cancelled scan's late result clobbering a newer one.
    /// Views that snapshot NodeIDs (the Fix sheet) pin them to this value:
    /// ids stay valid across edits of one scan, never across a rescan.
    private(set) var scanGeneration = 0

    /// SwiftUI's window opener, captured by whichever scene appears first, so
    /// AppKit-side code (the Finder Quick Action) can reopen the results window.
    var openWindow: OpenWindowAction?

    var windowTitle: String {
        switch phase {
        case .welcome: "MacDiskSleuth"
        case .scanning: "Scanning \(scannedPath)…"
        case .results: scannedPath
        }
    }

    init() {
        refreshFacts()
    }

    func refreshFacts() {
        fdaStatus = FDAProbe.status()
        capacities = try? VolumeService.capacities(ofVolume: "/")
        Task {
            self.snapshots = (try? await VolumeService.snapshots(ofVolume: "/")) ?? []
        }
    }

    // MARK: - Scanning

    func pickAndScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(path: url.path)
        }
    }

    func startScan(path: String) {
        cancelScan()
        scanError = nil
        scannedPath = path
        progress = ScanProgress.zero

        let newSession: ScanSession
        do {
            newSession = try ScanEngine.scan(path: path)
        } catch let error as ScanError {
            switch error {
            case .openFailed(let p, let code):
                scanError = "Cannot open \(p): \(errnoString2(code))"
            case .notADirectory(let p):
                scanError = "\(p) is not a folder."
            default:
                scanError = "Scan failed to start."
            }
            phase = .welcome
            return
        } catch {
            scanError = error.localizedDescription
            phase = .welcome
            return
        }

        session = newSession
        phase = .scanning
        scanGeneration += 1
        let generation = scanGeneration

        Task { [weak self] in
            for await update in newSession.progress {
                guard let self, self.scanGeneration == generation else { break }
                self.progress = update
            }
        }
        Task { [weak self] in
            do {
                let result = try await newSession.result.value
                guard let self, self.scanGeneration == generation else { return }
                self.graph = result.graph
                self.volume = result.volume
                self.focus = result.graph.root
                self.selection = nil
                self.atOverview = true
                self.graphStamp += 1
                self.phase = .results
                self.refreshFacts()
                self.refreshRecommendations(announce: true)
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.scanError = "Scan failed: \(error.localizedDescription)"
                self.phase = .welcome
            }
        }
    }

    func cancelScan() {
        session?.cancel()
        session = nil
    }

    // MARK: - Recommendations

    /// Rank what to delete, off the main thread (the graph may hold millions
    /// of nodes). `announce` marks a fresh scan: the old list is dropped at
    /// once and the system notification is posted. After an edit (a trash),
    /// the previous list stays visible until the new one arrives.
    func refreshRecommendations(announce: Bool = false) {
        guard let graph else {
            recommendations = nil
            return
        }
        if announce { recommendations = nil }
        let generation = scanGeneration
        let stamp = graphStamp
        let scanned = scannedPath
        let mountPoint = volume?.mountPoint ?? "/"
        let notify = announce && notifyOnScanComplete
        Task.detached(priority: .userInitiated) {
            // Facts for the volume that was actually scanned — an external
            // drive's snapshots, not the boot disk's.
            let volumeSnapshots = (try? await VolumeService.snapshots(ofVolume: mountPoint)) ?? []
            let purgeable = (try? VolumeService.capacities(ofVolume: mountPoint))?.purgeable
            let context = RecommendationContext(
                snapshots: volumeSnapshots, purgeableBytes: purgeable, volumeMountPoint: mountPoint)
            let report = Recommender.recommend(graph: graph, context: context)
            let accepted = await MainActor.run { () -> Bool in
                guard self.scanGeneration == generation, self.graphStamp == stamp else { return false }
                self.recommendationContext = context
                self.recommendations = report
                return true
            }
            if notify && accepted {
                await ScanNotifier.post(report: report, scannedPath: scanned)
            }
        }
    }

    func rescan() {
        guard !scannedPath.isEmpty else { return }
        startScan(path: scannedPath)
    }

    // MARK: - Navigation

    func drill(to node: NodeID) {
        guard let graph, graph.kind(of: node) == .directory else {
            selection = node
            return
        }
        atOverview = false
        focus = node
        selection = node
    }

    /// Leave the volume overview and enter the scanned folder's sunburst.
    func drillIntoScan() {
        guard let graph else { return }
        atOverview = false
        focus = graph.root
        selection = nil
    }

    func goToOverview() {
        atOverview = true
        selection = nil
        hovered = nil
    }

    func up() {
        guard let graph, !atOverview else { return }
        guard let parent = graph.parent(of: focus) else {
            goToOverview()
            return
        }
        focus = parent
        selection = focus
    }

    var canGoUp: Bool {
        graph != nil && !atOverview
    }

    func drillIntoSelection() {
        guard let selection else { return }
        drill(to: selection)
    }

    /// Jump to an item from a recommendation: open its folder, select it, and
    /// hand it to the inspector (which has the real "Move to Trash" with the
    /// honest freeable figure).
    func show(_ node: NodeID) {
        guard let graph else { return }
        showRecommendations = false
        atOverview = false
        focus = graph.parent(of: node) ?? graph.root
        selection = node
        hovered = nil
    }

    /// Root-to-focus path for the breadcrumb bar.
    var breadcrumbs: [NodeID] {
        guard let graph else { return [] }
        var trail: [NodeID] = []
        var current: NodeID? = focus
        while let node = current {
            trail.append(node)
            current = graph.parent(of: node)
        }
        return trail.reversed()
    }

    // MARK: - Deletion

    func revealInFinder(_ node: NodeID) {
        guard let graph else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: graph.path(of: node))])
    }

    // MARK: - Windows

    /// Bring the results window forward, reopening it if the user closed it
    /// while a recommendation window stayed open. False when no results window
    /// exists and no scene has handed us `openWindow` yet (cold launch).
    @discardableResult
    func showResultsWindow() -> Bool {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && Self.isResultsWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        guard let openWindow else { return false }
        openWindow(id: MacDiskSleuthApp.mainWindowID)
        return true
    }

    /// SwiftUI names a scene's windows "<scene id>-AppWindow-N".
    static func isResultsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MacDiskSleuthApp.mainWindowID) ?? false
    }

    static func isRecommendationWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MacDiskSleuthApp.recommendationWindowID) ?? false
    }

    /// Why the app refuses to trash this node, or nil when it may: an
    /// Applications folder or anything inside one, a home folder, /Users.
    /// Checked by every deletion path, so the Inspector can't do what the
    /// recommendations won't.
    func trashRefusal(for node: NodeID) -> String? {
        guard let graph else { return nil }
        return recommendationContext.trashRefusal(for: graph.path(of: node))
    }

    /// Move to Trash and patch the graph. Returns an error message, or nil on success.
    func moveToTrash(_ node: NodeID) -> String? {
        guard let graph else { return "No scan loaded." }
        let path = graph.path(of: node)
        if let refusal = recommendationContext.trashRefusal(for: path) { return refusal }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return "Couldn't move to Trash: \(error.localizedDescription)"
        }
        if focus == node || isDescendant(focus, of: node) {
            focus = graph.parent(of: node) ?? graph.root
        }
        self.graph = graph.removing(node)
        graphStamp += 1
        if selection == node { selection = nil }
        if hovered == node { hovered = nil }
        refreshRecommendations()
        return nil
    }

    /// Move several items to the Trash in one go (the Fix flow), then patch
    /// the graph once. `generation` is the `scanGeneration` the NodeIDs came
    /// from: a rescan since then means they name other files, so nothing is
    /// touched. Items already removed count as moved with nothing freed; a
    /// file that vanished since the scan counts the same way.
    func moveToTrash(_ nodes: [NodeID], from generation: Int) async -> BatchTrashResult {
        guard let graph, generation == scanGeneration else {
            let message =
                graph == nil
                ? "No scan loaded."
                : "The scan changed since this list was built; nothing was moved. Open Fix again."
            return BatchTrashResult(failures: nodes.map { TrashFailure(node: $0, path: "", message: message) })
        }

        var result = BatchTrashResult()
        var pending: [TrashWorkItem] = []
        var seen: Set<NodeID> = []
        for node in nodes where seen.insert(node).inserted {
            let path = graph.path(of: node)
            if graph.isRemoved(node) {
                result.trashed.append(node)
            } else if let refusal = recommendationContext.trashRefusal(for: path) {
                // Never, whatever the list said: Applications folders, apps and homes stay.
                result.failures.append(TrashFailure(node: node, path: path, message: refusal))
            } else {
                pending.append(TrashWorkItem(node: node, path: path, unique: graph.sizes(of: node).unique))
            }
        }

        // Trashing fifty items is fifty Finder round trips; keep the UI responsive.
        let work = pending
        let outcomes = await Task.detached(priority: .userInitiated) { () -> [TrashOutcome] in
            work.map { item in
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    return TrashOutcome(node: item.node, path: item.path, freed: item.unique, error: nil)
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    return TrashOutcome(node: item.node, path: item.path, freed: 0, error: nil)
                } catch {
                    return TrashOutcome(node: item.node, path: item.path, freed: 0, error: error.localizedDescription)
                }
            }
        }.value

        var trashedNow: [NodeID] = []
        for outcome in outcomes {
            if let message = outcome.error {
                result.failures.append(TrashFailure(node: outcome.node, path: outcome.path, message: message))
            } else {
                trashedNow.append(outcome.node)
                result.freed += outcome.freed
            }
        }
        result.trashed.append(contentsOf: trashedNow)

        // A rescan that landed meanwhile already reflects the disk; never patch
        // a stale graph. Edits of the same scan (an inspector delete) keep
        // NodeIDs valid, so the current graph is patched regardless of them.
        guard scanGeneration == generation, let current = self.graph, !trashedNow.isEmpty
        else { return result }
        for node in trashedNow where focus == node || isDescendant(focus, of: node) {
            focus = current.parent(of: node) ?? current.root
        }
        self.graph = current.removing(all: trashedNow)
        graphStamp += 1
        if let selection, trashedNow.contains(selection) { self.selection = nil }
        if let hovered, trashedNow.contains(hovered) { self.hovered = nil }
        refreshRecommendations()
        return result
    }

    private func isDescendant(_ node: NodeID, of ancestor: NodeID) -> Bool {
        guard let graph else { return false }
        var current: NodeID? = node
        while let n = current {
            if n == ancestor { return true }
            current = graph.parent(of: n)
        }
        return false
    }
}

/// One member a batch trash could not move.
struct TrashFailure: Sendable, Identifiable {
    var id: NodeID { node }
    var node: NodeID
    var path: String
    var message: String
}

/// Outcome of a batch trash: what moved, what didn't, and the honest
/// freeable total of what moved.
struct BatchTrashResult: Sendable {
    var trashed: [NodeID] = []
    var failures: [TrashFailure] = []
    var freed: Int64 = 0
}

private struct TrashWorkItem: Sendable {
    var node: NodeID
    var path: String
    var unique: Int64
}

private struct TrashOutcome: Sendable {
    var node: NodeID
    var path: String
    var freed: Int64
    var error: String?
}

func errnoString2(_ code: Int32) -> String {
    String(cString: strerror(code))
}
