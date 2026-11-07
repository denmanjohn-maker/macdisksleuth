import Darwin
import Foundation

/// One attributed slice of disk usage in the "why is my disk full" story.
public struct StorageBucket: Sendable, Codable {
    public var label: String
    public var bytes: Int64
    public var detail: String?
    public var deniedDirectories: Int

    public init(label: String, bytes: Int64, detail: String? = nil, deniedDirectories: Int = 0) {
        self.label = label
        self.bytes = bytes
        self.detail = detail
        self.deniedDirectories = deniedDirectories
    }
}

/// Capacity truth for the boot disk (or any volume): the numbers Finder,
/// du, and Apple's Storage pane each show differently, reconciled.
public struct DiskOverview: Sendable {
    public var volume: VolumeIdentity
    public var capacities: VolumeCapacities
    public var snapshots: [SnapshotInfo]
    public var fdaStatus: FDAStatus
    /// Boot-disk extras (nil when inspecting a non-boot volume).
    public var systemVolumeUsed: Int64?
    public var vmSwapUsed: Int64?
    /// Deep attribution of the Data volume; empty unless requested.
    public var buckets: [StorageBucket]
    /// used − attributed − known = the "System Data" mystery, named.
    public var unattributed: Int64?
}

extension VolumeService {
    /// Quick facts for the volume containing `path` (default: boot disk).
    /// Never scans; completes in under a second.
    public static func overview(ofVolume path: String = "/") async throws -> DiskOverview {
        let identity = try identity(ofPath: path)
        let capacities = try capacities(ofVolume: identity.mountPoint)
        let snapshots = (try? await snapshots(ofVolume: identity.mountPoint)) ?? []

        var systemUsed: Int64?
        var vmUsed: Int64?
        if identity.mountPoint == "/" || identity.mountPoint == "/System/Volumes/Data" {
            systemUsed = volumeSpaceUsed(at: "/")
            vmUsed = volumeSpaceUsed(at: "/System/Volumes/VM")
        }

        return DiskOverview(
            volume: identity,
            capacities: capacities,
            snapshots: snapshots,
            fdaStatus: FDAProbe.status(),
            systemVolumeUsed: systemUsed,
            vmSwapUsed: vmUsed,
            buckets: [],
            unattributed: nil
        )
    }

    /// The boot-disk bucket set for deep attribution. Each is scanned with the
    /// truth engine; the remainder becomes the named "System Data" bucket.
    public static let bootDiskBucketRoots: [(label: String, paths: [String])] = [
        ("Applications", ["/Applications"]),
        ("Users", ["/Users"]),
        ("Library", ["/Library"]),
        ("System caches & logs (/private)", ["/private"]),
        ("Dev tools (/usr/local, /opt)", ["/usr/local", "/opt"]),
    ]

    /// Bytes used on the Data volume, the quantity deep attribution explains.
    public static func dataVolumeUsed() -> Int64 {
        volumeSpaceUsed(at: "/System/Volumes/Data")
            ?? volumeSpaceUsed(at: "/")
            ?? 0
    }
}
