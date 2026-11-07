import ArgumentParser
import MacDiskSleuthKit
import Foundation

struct Cleanup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reclaim space held by local APFS snapshots and purgeable content.",
        discussion: """
            Deleting snapshots is irreversible. Pass --dry-run first to see exactly what
            would be removed. Deleting local snapshots usually requires `sudo`.
            """
    )

    @Argument(help: "Volume to clean (default: the boot disk).")
    var volume: String = "/"

    @Flag(name: .customLong("remove-snapshots"), help: "Delete local Time Machine snapshots.")
    var removeSnapshots = false

    @Flag(name: .customLong("purgeable"), help: "Report purgeable space and how to reclaim it.")
    var purgeable = false

    @Flag(name: .customLong("dry-run"), help: "Show what would be done without changing anything.")
    var dryRun = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    func validate() throws {
        guard removeSnapshots || purgeable else {
            throw ValidationError("Nothing to do. Pass --remove-snapshots and/or --purgeable.")
        }
    }

    func run() async throws {
        let style = Style(noColor: noColor)
        let identity = try VolumeService.identity(ofPath: (volume as NSString).expandingTildeInPath)

        if removeSnapshots {
            try await cleanSnapshots(on: identity.mountPoint, style: style)
        }
        if purgeable {
            try reportPurgeable(on: identity.mountPoint, style: style)
        }
    }

    private func cleanSnapshots(on mountPoint: String, style: Style) async throws {
        let snapshots = try await VolumeService.snapshots(ofVolume: mountPoint)
        let deletable = snapshots.filter { $0.timeMachineDate != nil }

        print(style.bold("Local snapshots on \(mountPoint)"))
        if deletable.isEmpty {
            print("  None to remove.")
            if snapshots.count > deletable.count {
                print(style.dim("  (\(snapshots.count - deletable.count) non-Time-Machine snapshot(s) left alone)"))
            }
            return
        }

        var failures = 0
        for snapshot in deletable {
            guard let date = snapshot.timeMachineDate else { continue }
            if dryRun {
                print("  would delete  \(style.cyan(date))  \(style.dim(snapshot.name))")
                continue
            }
            do {
                try await VolumeService.deleteLocalSnapshot(date: date)
                print("  deleted  \(style.cyan(date))")
            } catch {
                failures += 1
                print("  " + style.red("failed   \(date): \(error.localizedDescription)"))
            }
        }

        print()
        if dryRun {
            print(style.dim("Dry run — nothing changed. Re-run without --dry-run to delete \(deletable.count) snapshot\(deletable.count == 1 ? "" : "s")."))
        } else if failures > 0 {
            print(style.yellow("\(failures) of \(deletable.count) deletions failed. Try again with sudo."))
        } else {
            print(style.green("Removed \(deletable.count) snapshot\(deletable.count == 1 ? "" : "s"). Freed space appears as the filesystem thins."))
        }
    }

    private func reportPurgeable(on mountPoint: String, style: Style) throws {
        let capacities = try VolumeService.capacities(ofVolume: mountPoint)
        print(style.bold("Purgeable space on \(mountPoint)"))
        print("  purgeable now  \(style.green(ByteCount.format(capacities.purgeable)))")
        print(style.dim("  macOS has no public API to force a purge. It reclaims this automatically under"))
        print(style.dim("  disk pressure, or sooner after local snapshots are removed (--remove-snapshots)."))
    }
}
