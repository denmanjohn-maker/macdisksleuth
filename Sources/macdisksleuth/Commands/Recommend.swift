import ArgumentParser
import MacDiskSleuthKit
import Foundation

struct Recommend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The top things to delete to free space — ranked by what deleting really frees.",
        discussion: """
            Scans the path and ranks what could go: regenerable caches and build artifacts,
            installers and old downloads, container and VM images, device backups, duplicate
            copies, local snapshots. Every figure is freeable bytes — clones and hard links
            that would free nothing are skipped and reported as skipped. Nothing is deleted.

            Each recommendation carries a safety level: "safe" regenerates itself, "likely
            safe" deserves a glance, "review first" is content only you can judge.

            Examples:
              macdisksleuth recommend                 # your home folder, top 5
              macdisksleuth recommend / -n 10 --items 5
              macdisksleuth recommend ~ --json | jq '.recommendations[0]'
              macdisksleuth recommend ~ --notify      # also post a macOS notification
            """
    )

    @Argument(help: "Directory to scan (default: your home folder).")
    var path: String = "~"

    @Option(name: .shortAndLong, help: "How many recommendations to show.")
    var number: Int = 5

    @Option(name: .customLong("items"), help: "Paths listed under each recommendation.")
    var items: Int = 3

    @Option(name: .customLong("min-size"), help: "Ignore candidates smaller than this (default: 50MB).")
    var minSize: SizeArgument?

    @Flag(name: .customLong("one-file-system"), inversion: .prefixedNo, help: "Stay on the starting volume (default: on).")
    var oneFileSystem = true

    @Flag(name: .customLong("notify"), help: "Post a macOS notification with the top recommendations.")
    var notify = false

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func validate() throws {
        if number < 0 { throw ValidationError("--number must be 0 or more.") }
        if items < 0 { throw ValidationError("--items must be 0 or more.") }
    }

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        var options = ScanOptions()
        options.crossVolumes = !oneFileSystem

        let factsTask = Task { await VolumeFacts.gather(forPath: target) }
        let result = try await ScanRunner.run(path: target, options: options)
        let facts = await factsTask.value

        var context = RecommendationContext(
            limit: number, snapshots: facts.snapshots, purgeableBytes: facts.purgeable,
            volumeMountPoint: facts.mountPoint)
        if let minSize { context.minimumBytes = minSize.bytes }
        let report = Recommender.recommend(graph: result.graph, context: context)

        if json {
            struct Payload: Codable {
                var schemaVersion = 1
                var root: String
                var filesystem: String
                var files: Int
                var totalPhysical: Int64
                var totalFreeable: Int64
                var localSnapshots: Int
                var purgeable: Int64?
                var deniedDirectories: Int
                var partial: Bool
                var report: RecommendationReportJSON
            }
            let summary = result.graph.summary
            let payload = Payload(
                root: result.graph.rootPath,
                filesystem: result.volume.fsTypeName,
                files: summary.fileCount,
                totalPhysical: summary.totalPhysical,
                totalFreeable: summary.totalUnique,
                localSnapshots: facts.snapshots.count,
                purgeable: facts.purgeable,
                deniedDirectories: summary.deniedDirectoryCount,
                partial: summary.partial,
                report: RecommendationReportJSON(report: report))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        } else {
            let style = Style(noColor: noColor)
            let summary = result.graph.summary
            print(
                style.dim(
                    "\(result.graph.rootPath) · \(summary.fileCount.formatted()) files · "
                        + "physical \(ByteCount.format(summary.totalPhysical, binary: binaryUnits)) · "
                        + "freeable \(ByteCount.format(summary.totalUnique, binary: binaryUnits))"))
            print()
            var printer = RecommendationPrinter(report: report, context: context, style: style, binaryUnits: binaryUnits)
            printer.itemsShown = items
            printer.printReport()
        }

        if notify {
            await RecommendationPrinter.notify(report: report, scannedPath: result.graph.rootPath)
        }
    }
}
