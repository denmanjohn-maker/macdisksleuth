import Darwin
import Foundation

/// Capacity truth for a volume, including the purgeable gap Finder hides.
public struct VolumeCapacities: Sendable, Codable {
    public var totalCapacity: Int64
    /// Space available without evicting anything ("opportunistic").
    public var availableNow: Int64
    /// Space the system can make available for important usage (evicting purgeable content).
    public var availableForImportantUsage: Int64
    public var usedBytes: Int64

    /// The gap between what Finder calls "available" and what is free right now.
    public var purgeable: Int64 { max(availableForImportantUsage - availableNow, 0) }
}

/// statfs-level identity of the volume containing a path.
public struct VolumeIdentity: Sendable, Codable {
    public var mountPoint: String
    public var fsTypeName: String
    public var deviceName: String
    public var isReadOnly: Bool
    public var usedBytes: Int64
    public var totalBytes: Int64

    public var isAPFS: Bool { fsTypeName == "apfs" }
}

public enum VolumeService {
    public static func identity(ofPath path: String) throws -> VolumeIdentity {
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            throw ScanError.openFailed(path: path, code: errno)
        }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let fsType = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let device = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let blockSize = Int64(info.f_bsize)
        return VolumeIdentity(
            mountPoint: mountPoint,
            fsTypeName: fsType,
            deviceName: device,
            isReadOnly: (info.f_flags & UInt32(MNT_RDONLY)) != 0,
            usedBytes: Int64(info.f_blocks - info.f_bfree) * blockSize,
            totalBytes: Int64(info.f_blocks) * blockSize
        )
    }

    public static func capacities(ofVolume mountPoint: String) throws -> VolumeCapacities {
        let url = URL(fileURLWithPath: mountPoint)
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        return VolumeCapacities(
            totalCapacity: total,
            availableNow: available,
            availableForImportantUsage: max(important, available),
            usedBytes: max(total - available, 0)
        )
    }
}
