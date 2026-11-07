import ArgumentParser
import MacDiskSleuthKit
import Foundation

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan and compare the totals against a stored baseline.",
        discussion: """
            Every `diff`, `export`, and `schedule --now` run stores its totals in
            ~/.macdisksleuth/scans.json. The first `diff` of a path has nothing to compare
            against, so it just records a baseline.
            """
    )

    @Argument(help: "Directory to scan (default: /).")
    var path: String = "/"

    @Option(name: .customLong("baseline"), help: "Baseline scan ID, or 'latest' for the newest scan of this path.")
    var baseline: String = "latest"

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        let store = ScanStore()

        // Validate an explicit ID before paying for the scan.
        var baselineRecord: ScanRecord?
        if baseline != "latest" {
            guard let record = try store.loadScanRecord(id: baseline) else {
                throw ValidationError("No stored scan with ID \(baseline).")
            }
            baselineRecord = record
        }

        let result = try await ScanRunner.run(path: target)
        // Records store the engine's canonical root (symlinks such as /var → /private/var
        // resolved), so match "latest" on that rather than on the raw argument.
        if baseline == "latest" {
            baselineRecord = try store.loadLatestScan(path: result.graph.rootPath)
        }
        let current = try store.storeScanResult(result, options: ScanOptions())

        guard let baselineRecord else {
            print("No baseline for \(target) yet — stored this scan as one (ID: \(current.id)).")
            print("Run `macdisksleuth diff \(shellQuote(path))` again later to see what changed.")
            return
        }

        if json {
            try printJSON(baseline: baselineRecord, current: current)
        } else {
            printHuman(baseline: baselineRecord, current: current)
        }
    }

    private func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }

    /// "+1.2 GB" / "−300 MB" / "no change".
    private func delta(_ bytes: Int64) -> String {
        if bytes == 0 { return "no change" }
        return (bytes > 0 ? "+" : "−") + fmt(abs(bytes))
    }

    private func delta(_ count: Int) -> String {
        if count == 0 { return "no change" }
        return (count > 0 ? "+" : "−") + abs(count).formatted()
    }

    private func printHuman(baseline: ScanRecord, current: ScanRecord) {
        let style = Style(noColor: noColor)
        let before = baseline.summary
        let after = current.summary

        print(style.bold("MacDiskSleuth diff") + style.dim(" · \(current.path)"))
        print(style.dim("baseline \(baseline.date.formatted(.dateTime)) → now \(current.date.formatted(.dateTime))"))
        print()

        func line(_ label: String, _ before: Int64, _ after: Int64) {
            let change = after - before
            let colored = change > 0 ? style.yellow(delta(change)) : change < 0 ? style.green(delta(change)) : style.dim(delta(change))
            print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(fmt(before)) → \(fmt(after))   \(colored)")
        }
        line("logical", before.totalLogical, after.totalLogical)
        line("physical", before.totalPhysical, after.totalPhysical)
        line("freeable", before.totalUnique, after.totalUnique)
        print()
        print("  files          \(before.fileCount.formatted()) → \(after.fileCount.formatted())   \(style.dim(delta(after.fileCount - before.fileCount)))")
        print("  folders        \(before.directoryCount.formatted()) → \(after.directoryCount.formatted())   \(style.dim(delta(after.directoryCount - before.directoryCount)))")
        print("  clones         \(before.cloneFileCount.formatted()) → \(after.cloneFileCount.formatted())   \(style.dim(delta(after.cloneFileCount - before.cloneFileCount)))")

        if before.partial || after.partial || before.deniedDirectoryCount != after.deniedDirectoryCount {
            print()
            print(style.yellow("⚠ Unreadable folders differ (\(before.deniedDirectoryCount) → \(after.deniedDirectoryCount)); totals are not directly comparable."))
        }
    }

    private func printJSON(baseline: ScanRecord, current: ScanRecord) throws {
        struct Payload: Codable {
            var schemaVersion = 1
            var path: String
            var baseline: ScanRecord
            var current: ScanRecord
            var logicalDelta: Int64
            var physicalDelta: Int64
            var freeableDelta: Int64
            var fileCountDelta: Int
        }
        let payload = Payload(
            path: current.path, baseline: baseline, current: current,
            logicalDelta: current.summary.totalLogical - baseline.summary.totalLogical,
            physicalDelta: current.summary.totalPhysical - baseline.summary.totalPhysical,
            freeableDelta: current.summary.totalUnique - baseline.summary.totalUnique,
            fileCountDelta: current.summary.fileCount - baseline.summary.fileCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }
}
