import ArgumentParser
import DiskSleuthKit
import Foundation

struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Local Time Machine snapshots — the invisible tenant holding your freed space."
    )

    @Argument(help: "Volume to inspect (default: the boot disk).")
    var volume: String = "/"

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    func run() async throws {
        let identity = try VolumeService.identity(ofPath: (volume as NSString).expandingTildeInPath)
        let snapshots = try await VolumeService.snapshots(ofVolume: identity.mountPoint)

        if json {
            struct Payload: Codable {
                var schemaVersion = 1
                var volume: String
                var snapshots: [SnapshotInfo]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(
                String(
                    decoding: try encoder.encode(
                        Payload(volume: identity.mountPoint, snapshots: snapshots)),
                    as: UTF8.self))
            return
        }

        let style = Style(noColor: noColor)
        if snapshots.isEmpty {
            print("No local snapshots on \(identity.mountPoint).")
            if !identity.isAPFS {
                print(style.dim("(\(identity.fsTypeName) volumes don't have APFS snapshots)"))
            }
            return
        }

        print(style.bold("\(snapshots.count) local snapshot\(snapshots.count == 1 ? "" : "s") on \(identity.mountPoint)"))
        print()
        for snap in snapshots {
            var line = "  ◷ " + style.cyan(snap.timeMachineDate ?? snap.name)
            if snap.timeMachineDate != nil { line += style.dim("  \(snap.name)") }
            if snap.purgeable == true { line += style.green("  purgeable") }
            print(line)
        }
        print()
        print(style.dim("Deleted files these snapshots reference are not freed until snapshots thin."))
        print(style.dim("macOS thins them automatically under disk pressure, or:"))
        print(style.dim("  tmutil deletelocalsnapshots <date>   (per snapshot)"))
        print(style.dim("  tmutil thinlocalsnapshots / 999999999999 4   (reclaim aggressively)"))
    }
}
