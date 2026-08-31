import AppKit
import DiskSleuthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
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
    private var scanGeneration = 0

    var windowTitle: String {
        switch phase {
        case .welcome: "DiskSleuth"
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

    /// Move to Trash and patch the graph. Returns an error message, or nil on success.
    func moveToTrash(_ node: NodeID) -> String? {
        guard let graph else { return "No scan loaded." }
        let path = graph.path(of: node)
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
        return nil
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

func errnoString2(_ code: Int32) -> String {
    String(cString: strerror(code))
}
