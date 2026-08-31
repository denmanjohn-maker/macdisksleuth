import Foundation

/// One local APFS snapshot. Per-snapshot on-disk size is not cheaply knowable —
/// we report it as unknown rather than fabricating a number.
public struct SnapshotInfo: Sendable, Codable, Identifiable {
    public var name: String
    public var uuid: String?
    public var xid: UInt64?
    public var purgeable: Bool?

    public var id: String { uuid ?? name }

    /// Time Machine snapshot names embed a timestamp: com.apple.TimeMachine.2026-08-30-101112.local
    public var timeMachineDate: String? {
        guard name.hasPrefix("com.apple.TimeMachine.") else { return nil }
        let trimmed = name
            .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension VolumeService {
    /// Enumerate local snapshots via `diskutil apfs listSnapshots -plist`,
    /// falling back to `tmutil listlocalsnapshots`. Returns [] when the volume
    /// has none or isn't APFS; only unexpected subprocess failures throw.
    public static func snapshots(ofVolume mountPoint: String) async throws -> [SnapshotInfo] {
        if let viaDiskutil = try? await snapshotsViaDiskutil(mountPoint), !viaDiskutil.isEmpty {
            return viaDiskutil
        }
        return (try? await snapshotsViaTmutil(mountPoint)) ?? []
    }

    private struct DiskutilSnapshotList: Decodable {
        struct Snapshot: Decodable {
            var SnapshotName: String?
            var SnapshotUUID: String?
            var SnapshotXID: UInt64?
            var Purgeable: Bool?
        }
        var Snapshots: [Snapshot]?
    }

    private static func snapshotsViaDiskutil(_ mountPoint: String) async throws -> [SnapshotInfo] {
        let output = try await Subprocess.run(
            "/usr/sbin/diskutil", ["apfs", "listSnapshots", "-plist", mountPoint])
        guard output.status == 0, !output.stdout.isEmpty else { return [] }
        let list = try PropertyListDecoder().decode(DiskutilSnapshotList.self, from: output.stdout)
        return (list.Snapshots ?? []).compactMap { snap in
            guard let name = snap.SnapshotName else { return nil }
            return SnapshotInfo(
                name: name, uuid: snap.SnapshotUUID, xid: snap.SnapshotXID, purgeable: snap.Purgeable)
        }
    }

    private static func snapshotsViaTmutil(_ mountPoint: String) async throws -> [SnapshotInfo] {
        let output = try await Subprocess.run("/usr/bin/tmutil", ["listlocalsnapshots", mountPoint])
        guard output.status == 0 else { return [] }
        return String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(".") && !$0.hasPrefix("Snapshots for ") }
            .map { SnapshotInfo(name: $0, uuid: nil, xid: nil, purgeable: nil) }
    }
}
