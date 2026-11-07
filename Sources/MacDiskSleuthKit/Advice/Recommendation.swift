import Foundation

/// What kind of thing a cleanup recommendation points at. Categories carry
/// the knowledge of *why* something is disposable; the ranking uses them to
/// decide whether staleness should sway the order.
public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case trash
    case applicationCaches = "application-caches"
    case developerCaches = "developer-caches"
    case deviceSupport = "device-support"
    case buildArtifacts = "build-artifacts"
    case packageCaches = "package-caches"
    case containers
    case virtualMachines = "virtual-machines"
    case aiModels = "ai-models"
    case toolchains
    case logs
    case installers
    case downloads
    case deviceBackups = "device-backups"
    case applications
    case media
    case mediaCaches = "media-caches"
    case archives
    case ciWorkspaces = "ci-workspaces"
    case largeFile = "large-file"
    case duplicates
    case systemManaged = "system-managed"
    case snapshots

    public var displayName: String {
        switch self {
        case .trash: "Trash"
        case .applicationCaches: "Application caches"
        case .developerCaches: "Developer caches"
        case .deviceSupport: "Device support & simulators"
        case .buildArtifacts: "Build artifacts"
        case .packageCaches: "Package manager caches"
        case .containers: "Containers"
        case .virtualMachines: "Virtual machines"
        case .aiModels: "AI models"
        case .toolchains: "Toolchains"
        case .logs: "Logs"
        case .installers: "Installers & archives"
        case .downloads: "Downloads"
        case .deviceBackups: "Device backups"
        case .applications: "Applications"
        case .media: "Media"
        case .mediaCaches: "Media render caches"
        case .archives: "Xcode archives"
        case .ciWorkspaces: "CI workspaces"
        case .largeFile: "Large files"
        case .duplicates: "Duplicates"
        case .systemManaged: "System managed"
        case .snapshots: "Local snapshots"
        }
    }

    /// Whether "how long since anything here changed" should sway the ranking.
    /// A cache nobody touched in a year is a better bet than one written this
    /// morning; an app or a VM is used without being modified, so age says nothing.
    public var ageMatters: Bool {
        switch self {
        case .trash, .applications, .containers, .virtualMachines, .deviceBackups,
            .snapshots, .systemManaged, .duplicates, .aiModels, .toolchains:
            false
        default:
            true
        }
    }
}

/// How confidently a recommendation can be acted on without looking first.
public enum CleanupSafety: String, Codable, Sendable, Comparable {
    /// Only you can judge: personal content, apps, backups.
    case review
    /// Disposable in nearly every case, but worth a glance (installers, logs, old downloads).
    case likelySafe = "likely-safe"
    /// Regenerated automatically; deleting costs nothing but a rebuild or re-download.
    case safe

    private var rank: Int {
        switch self {
        case .review: 0
        case .likelySafe: 1
        case .safe: 2
        }
    }

    public static func < (lhs: CleanupSafety, rhs: CleanupSafety) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .safe: "safe"
        case .likelySafe: "likely safe"
        case .review: "review first"
        }
    }

    /// Ranking weight: a safe gigabyte beats a gigabyte you'd have to think about.
    var weight: Double {
        switch self {
        case .safe: 1.0
        case .likelySafe: 0.7
        case .review: 0.4
        }
    }
}

/// One suggested deletion — a single item, or a group of related items that
/// make sense as one action ("your build artifacts", "application caches").
public struct Recommendation: Sendable, Identifiable {
    public struct Item: Sendable, Identifiable {
        public var id: String { path }
        /// Graph node, when the item is in the scanned tree (nil for synthesized items).
        public var node: NodeID?
        public var path: String
        public var sizes: Sizes
        /// Newest change anywhere inside the item; nil when unknown.
        public var newestModified: Date?
        /// Per-item context: which cache this is, how to clear it, what it duplicates.
        public var note: String?

        public init(node: NodeID?, path: String, sizes: Sizes, newestModified: Date?, note: String? = nil) {
            self.node = node
            self.path = path
            self.sizes = sizes
            self.newestModified = newestModified
            self.note = note
        }
    }

    public var id: String
    public var category: CleanupCategory
    public var title: String
    public var safety: CleanupSafety
    /// Why this is disposable — one or two sentences.
    public var reason: String
    /// How to reclaim it — a command, a menu path, or plain advice.
    public var action: String
    /// The single node this recommendation is about, when there is one
    /// (a cache folder, a large file). nil for groups and synthesized items.
    public var node: NodeID?
    /// Members, largest first. For a folder recommended as a whole this is
    /// its breakdown; for a group it is every matched location.
    public var items: [Item]
    /// Members before truncation to the storage cap.
    public var itemCount: Int
    /// Totals across every member. `unique` is what deleting them all frees now.
    public var sizes: Sizes
    public var newestModified: Date?
    /// Honesty notes: shared bytes that stay on disk, unreadable folders inside, sparse claims.
    public var caveats: [String]
    /// 0…1 — how sure the engine is that this is worth acting on.
    public var confidence: Double
    /// Whether the GUI may offer "Move to Trash" for the primary node.
    public var canMoveToTrash: Bool
    /// Internal ranking key: freeable bytes weighted by safety and staleness.
    var score: Double

    public var freeable: Int64 { sizes.unique }
}

/// The outcome of asking "what should I delete?" about one scan.
public struct RecommendationReport: Sendable {
    public var recommendations: [Recommendation]
    /// Sum of freeable bytes across the recommendations shown.
    public var totalFreeable: Int64
    /// Candidates that cleared the size floor, before ranking and truncation.
    public var consideredCount: Int
    /// Report-level honesty notes (skipped clones, unreadable folders, snapshots).
    public var notes: [String]
    public var generatedAt: Date
    /// Advice about the volume itself — local Time Machine snapshots — whose
    /// savings macOS does not report. Kept out of the ranked list and its total
    /// rather than ranked on an invented number.
    public var volumeAdvice: Recommendation?

    public init(
        recommendations: [Recommendation], totalFreeable: Int64, consideredCount: Int,
        notes: [String], generatedAt: Date, volumeAdvice: Recommendation? = nil
    ) {
        self.recommendations = recommendations
        self.totalFreeable = totalFreeable
        self.consideredCount = consideredCount
        self.notes = notes
        self.generatedAt = generatedAt
        self.volumeAdvice = volumeAdvice
    }

    /// The same report showing only the first `count` recommendations, with
    /// the headline total recomputed to match.
    public func limited(to count: Int) -> RecommendationReport {
        guard count < recommendations.count else { return self }
        var copy = self
        copy.recommendations = Array(recommendations.prefix(max(count, 0)))
        copy.totalFreeable = copy.recommendations.reduce(Int64(0)) { $0 + $1.freeable }
        return copy
    }
}

/// Everything the recommender needs to know beyond the graph itself.
public struct RecommendationContext: Sendable {
    /// The user's home, so "~/Library/Caches" rules resolve. Defaults to the
    /// `HOME` override if set (like ScanStore), else the account home.
    public var homeDirectory: String
    /// "Now" for staleness math; injectable for tests.
    public var now: Date
    /// How many recommendations to return.
    public var limit: Int
    /// Candidates smaller than this are never worth a slot.
    public var minimumBytes: Int64
    /// Local APFS snapshots on the scanned volume (they pin deleted blocks).
    public var snapshots: [SnapshotInfo]
    /// Purgeable space on the scanned volume, when known.
    public var purgeableBytes: Int64?
    /// Mount point of the scanned volume, so snapshot advice targets it.
    public var volumeMountPoint: String?
    /// How many members a recommendation keeps (the largest).
    public var maxItems: Int

    public init(
        homeDirectory: String? = nil,
        now: Date = Date(),
        limit: Int = 5,
        minimumBytes: Int64 = 50_000_000,
        snapshots: [SnapshotInfo] = [],
        purgeableBytes: Int64? = nil,
        volumeMountPoint: String? = nil,
        maxItems: Int = 50
    ) {
        let home = homeDirectory
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        self.homeDirectory = Self.canonical(home)
        self.now = now
        self.limit = limit
        self.minimumBytes = minimumBytes
        self.snapshots = snapshots
        self.purgeableBytes = purgeableBytes
        self.volumeMountPoint = volumeMountPoint
        self.maxItems = maxItems
    }

    /// Local snapshots Time Machine made (system-update snapshots are not
    /// something `tmutil deletelocalsnapshots` removes).
    public var timeMachineSnapshots: [SnapshotInfo] {
        snapshots.filter { $0.timeMachineDate != nil }
    }

    /// "~/Library/Caches" for paths under the home directory.
    public func displayPath(_ path: String) -> String {
        if path == homeDirectory { return "~" }
        let prefix = homeDirectory.hasSuffix("/") ? homeDirectory : homeDirectory + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    /// Resolve symlinks the way the scanner does for its root, so a home such
    /// as /var/root or a relocated ~ compares equal to graph paths.
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBytes { raw in
            realpath(expanded, raw.baseAddress?.assumingMemoryBound(to: CChar.self)) != nil
        }
        var result = resolved
            ? String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            : expanded
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// Human-friendly "how long ago" for staleness lines.
public enum AgeText {
    /// "today", "3 days", "6 weeks", "7 months", "2 years".
    public static func describe(since date: Date, now: Date) -> String {
        let days = now.timeIntervalSince(date) / 86_400
        if days < 1 { return "today" }
        if days < 2 { return "yesterday" }
        if days < 14 { return "\(Int(days)) days" }
        if days < 60 { return "\(Int(days / 7)) weeks" }
        if days < 548 { return "\(max(Int((days / 30.44).rounded()), 2)) months" }
        return "\(Int((days / 365.25).rounded())) years"
    }

    /// "untouched for 7 months" / "changed today".
    public static func staleness(since date: Date, now: Date) -> String {
        let text = describe(since: date, now: now)
        switch text {
        case "today": return "changed today"
        case "yesterday": return "changed yesterday"
        default: return "untouched for \(text)"
        }
    }
}

// MARK: - Acting on a recommendation

extension CleanupCategory {
    /// Whether a recommendation's members may be moved to the Trash from the
    /// app. Container disk images and system-managed temp folders carry
    /// "prune from inside the tool" / "let macOS handle it" advice, and
    /// snapshot advice has no files at all.
    public var membersAreTrashable: Bool {
        switch self {
        case .systemManaged, .containers, .snapshots: false
        default: true
        }
    }
}

extension Recommendation {
    /// Members that exist in the scanned tree and so can be acted on.
    public var actionableItems: [Item] { items.filter { $0.node != nil } }

    /// Whether the guided "Fix" flow (pick members, move them to the Trash)
    /// applies. Independent of `canMoveToTrash`, which is about the primary
    /// node: a per-app cache breakdown or a duplicates group has no single
    /// trashable node yet is exactly what Fix is for.
    public var isFixable: Bool { category.membersAreTrashable && !actionableItems.isEmpty }

    /// Members the Fix flow starts with checked: everything for a `safe`
    /// recommendation, nothing for one that deserves a look first.
    public var preselectedItemIDs: Set<String> {
        safety == .safe ? Set(actionableItems.map(\.id)) : []
    }

    /// Members beyond the storage cap that are not listed.
    public var hiddenItemCount: Int { max(itemCount - items.count, 0) }
}
