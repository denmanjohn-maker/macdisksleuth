import ArgumentParser
import DiskSleuthKit
import Foundation

struct Overview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Why is my disk full? Capacity, purgeable space, snapshots — and with --deep, where every gigabyte went."
    )

    @Argument(help: "Volume to inspect (default: the boot disk).")
    var volume: String = "/"

    @Flag(name: .customLong("deep"), help: "Scan and attribute Data-volume usage (takes a minute).")
    var deep = false

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        var overview = try await VolumeService.overview(ofVolume: volume)

        if deep && (overview.volume.mountPoint == "/" || overview.volume.mountPoint == "/System/Volumes/Data") {
            var buckets: [StorageBucket] = []
            for (label, paths) in VolumeService.bootDiskBucketRoots {
                var bytes: Int64 = 0
                var denied = 0
                for path in paths where FileManager.default.fileExists(atPath: path) {
                    if !json {
                        FileHandle.standardError.write(Data("scanning \(path)…\n".utf8))
                    }
                    let result = try await ScanRunner.run(path: path)
                    bytes += result.graph.summary.totalPhysical
                    denied += result.graph.summary.deniedDirectoryCount
                }
                buckets.append(StorageBucket(label: label, bytes: bytes, deniedDirectories: denied))
            }
            overview.buckets = buckets
            let attributed = buckets.reduce(Int64(0)) { $0 + $1.bytes }
            overview.unattributed = max(VolumeService.dataVolumeUsed() - attributed, 0)
        }

        if json {
            try printJSON(overview)
        } else {
            printHuman(overview)
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCount.format(bytes, binary: binaryUnits)
    }

    private func printHuman(_ overview: DiskOverview) {
        let style = Style(noColor: noColor)
        let vol = overview.volume
        let cap = overview.capacities

        print(style.bold("\(vol.mountPoint == "/" ? "Boot disk" : vol.mountPoint)") + style.dim("  \(vol.deviceName) · \(vol.fsTypeName)"))
        print()

        func row(_ label: String, _ value: String, note: String = "") {
            let paddedLabel = label.padding(toLength: 28, withPad: " ", startingAt: 0)
            let paddedValue = value.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(paddedLabel)\(style.bold(paddedValue))\(style.dim(note))")
        }

        row("Capacity", fmt(cap.totalCapacity))
        if let systemUsed = overview.systemVolumeUsed {
            row("Data volume used", fmt(VolumeService.dataVolumeUsed()))
            row("System (sealed, read-only)", fmt(systemUsed))
            if let vm = overview.vmSwapUsed, vm > 0 {
                row("Swap (VM volume)", fmt(vm))
            }
        } else {
            row("Used", fmt(vol.usedBytes))
        }
        row("Free right now", fmt(cap.availableNow))
        if cap.purgeable > 0 {
            row(
                "… purgeable on demand", "+" + fmt(cap.purgeable),
                note: "Finder calls \(fmt(cap.availableForImportantUsage)) \"available\"")
        }

        let snapshotCount = overview.snapshots.count
        if snapshotCount > 0 {
            row(
                "Local snapshots", "\(snapshotCount)",
                note: "sizes not reported by macOS — see `disksleuth snapshots`")
        }
        switch overview.fdaStatus {
        case .granted:
            print(style.dim("\n  Full Disk Access: granted"))
        case .denied:
            print(style.yellow("\n  Full Disk Access: NOT granted — scans will undercount protected folders."))
        case .unknown:
            break
        }

        if !overview.buckets.isEmpty {
            print()
            print(style.bold("  Where the Data volume went"))
            let maxBytes = max(overview.buckets.map(\.bytes).max() ?? 1, overview.unattributed ?? 0, 1)
            var rows = overview.buckets.map { ($0.label, $0.bytes, $0.deniedDirectories) }
            rows.sort { $0.1 > $1.1 }
            for (label, bytes, denied) in rows {
                bucketRow(label: label, bytes: bytes, maxBytes: maxBytes, denied: denied, style: style)
            }
            if let unattributed = overview.unattributed {
                bucketRow(
                    label: "\"System Data\" (unattributed)", bytes: unattributed,
                    maxBytes: maxBytes, denied: 0, style: style)
                print(
                    style.dim(
                        "    snapshots, Spotlight, unscanned & purgeable content — the bucket Apple's Storage pane won't itemize"
                    ))
            }
        } else if overview.volume.mountPoint == "/" {
            print(style.dim("\n  Run with --deep to attribute Data-volume usage bucket by bucket."))
        }
    }

    private func bucketRow(label: String, bytes: Int64, maxBytes: Int64, denied: Int, style: Style) {
        let width = 18
        let filled = Int((Double(bytes) / Double(maxBytes) * Double(width)).rounded())
        let bar = String(repeating: "█", count: max(filled, 0))
            + String(repeating: "·", count: max(width - filled, 0))
        let paddedValue = fmt(bytes).padding(toLength: 11, withPad: " ", startingAt: 0)
        var line = "  \(style.cyan(bar)) \(style.bold(paddedValue))\(label)"
        if denied > 0 { line += style.yellow("  (⛔ \(denied) unreadable)") }
        print(line)
    }

    private func printJSON(_ overview: DiskOverview) throws {
        struct Payload: Codable {
            var schemaVersion = 1
            var mountPoint: String
            var device: String
            var filesystem: String
            var totalCapacity: Int64
            var usedBytes: Int64
            var dataVolumeUsed: Int64?
            var systemVolumeUsed: Int64?
            var vmSwapUsed: Int64?
            var freeNow: Int64
            var purgeable: Int64
            var finderAvailable: Int64
            var localSnapshots: Int
            var fullDiskAccess: String
            var buckets: [StorageBucket]?
            var unattributed: Int64?
        }
        let payload = Payload(
            mountPoint: overview.volume.mountPoint,
            device: overview.volume.deviceName,
            filesystem: overview.volume.fsTypeName,
            totalCapacity: overview.capacities.totalCapacity,
            usedBytes: overview.volume.usedBytes,
            dataVolumeUsed: overview.systemVolumeUsed != nil ? VolumeService.dataVolumeUsed() : nil,
            systemVolumeUsed: overview.systemVolumeUsed,
            vmSwapUsed: overview.vmSwapUsed,
            freeNow: overview.capacities.availableNow,
            purgeable: overview.capacities.purgeable,
            finderAvailable: overview.capacities.availableForImportantUsage,
            localSnapshots: overview.snapshots.count,
            fullDiskAccess: {
                switch overview.fdaStatus {
                case .granted: "granted"
                case .denied: "denied"
                case .unknown: "unknown"
                }
            }(),
            buckets: overview.buckets.isEmpty ? nil : overview.buckets,
            unattributed: overview.unattributed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }
}
