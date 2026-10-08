import Darwin
import Foundation

/// `dev_t` is a signed Int32, and synthetic filesystems (devfs, autofs, …)
/// hand out IDs with the high bit set — negative as Int32. Reinterpret the
/// bits instead of converting, which traps on those values.
@inline(__always)
func deviceID(_ dev: dev_t) -> UInt64 {
    UInt64(UInt32(bitPattern: dev))
}

public struct ScanOptions: Sendable, Codable {
    /// Max directories being read concurrently.
    public var maxConcurrency: Int
    /// Traverse onto other volumes at mount points (the system↔Data volume
    /// group is always traversed when scanning "/", regardless).
    public var crossVolumes: Bool
    /// Force the readdir fallback instead of getattrlistbulk (debugging).
    public var forceFallback: Bool

    /// Scanning is syscall-latency-bound, not CPU-bound: workers spend most of
    /// their time waiting on APFS metadata reads, so the sweet spot is far more
    /// workers than cores (measured: 64 ≈ 1.8× faster than 2×cores; flat beyond).
    public init(
        maxConcurrency: Int = min(64, max(16, ProcessInfo.processInfo.activeProcessorCount * 4)),
        crossVolumes: Bool = false,
        forceFallback: Bool = false
    ) {
        self.maxConcurrency = maxConcurrency
        self.crossVolumes = crossVolumes
        self.forceFallback = forceFallback
    }
}

public struct ScanProgress: Sendable {
    public var directoriesScanned: Int = 0
    public var filesSeen: Int = 0
    public var logicalBytes: Int64 = 0
    public var physicalBytes: Int64 = 0
    public var deniedCount: Int = 0
    public var currentPath: String = ""
    public var finished: Bool = false
}

extension ScanProgress {
    public static let zero = ScanProgress()
}

public struct ScanResult: Sendable {
    public var graph: FileGraph
    public var volume: VolumeIdentity
}

/// One unit of traversal work: a directory awaiting enumeration.
struct DirWork: Sendable {
    var nodeID: Int32
    /// Handle of the parent directory (openat base). nil for the scan root.
    var parent: DirHandle?
    /// Entry name within parent; full path for the root item.
    var name: String
    /// Absolute path (for the permission ledger and progress display).
    var path: String
    /// When traversing the literal /System/Volumes/Data residue during a "/"
    /// scan: path relative to the Data volume root, used to skip firmlink
    /// targets that are attributed to their firmlink positions instead.
    var dataRelativePath: String?
}
