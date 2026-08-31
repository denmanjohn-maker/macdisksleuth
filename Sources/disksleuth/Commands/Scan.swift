import ArgumentParser
import Darwin
import DiskSleuthKit
import Foundation

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a folder or volume and show where the space really went."
    )

    @Argument(help: "Directory to scan (default: current directory).")
    var path: String = "."

    @Option(name: .customLong("depth"), help: "Tree depth to display.")
    var depth: Int = 2

    @Option(name: .customLong("top"), help: "Children shown per directory.")
    var top: Int = 10

    @Option(name: .customLong("size-mode"), help: "Lens: logical, physical, or unique (freeable).")
    var sizeMode: SizeLens = .physical

    @Flag(name: .customLong("one-file-system"), inversion: .prefixedNo, help: "Stay on the starting volume (default: on; the system↔Data pair counts as one).")
    var oneFileSystem = true

    @Flag(name: .customLong("force-fallback"), help: "Use the slow readdir path (debugging).")
    var forceFallback = false

    @Option(name: .customLong("concurrency"), help: ArgumentHelp("Concurrent directory readers.", visibility: .hidden))
    var concurrency: Int?

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        var options = ScanOptions()
        options.crossVolumes = !oneFileSystem
        options.forceFallback = forceFallback
        if let concurrency { options.maxConcurrency = concurrency }

        // Snapshot presence is fetched concurrently with the scan; it changes
        // what "freeable" means for the caveat line.
        let snapshotTask = Task { () -> Int in
            let mount = (try? VolumeService.identity(ofPath: target))?.mountPoint ?? "/"
            return ((try? await VolumeService.snapshots(ofVolume: mount)) ?? []).count
        }

        let result = try await ScanRunner.run(path: target, options: options)
        let snapshotCount = await snapshotTask.value

        if json {
            try printJSON(result: result, snapshotCount: snapshotCount)
        } else {
            printHuman(result: result, snapshotCount: snapshotCount)
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCount.format(bytes, binary: binaryUnits)
    }

    private func printHuman(result: ScanResult, snapshotCount: Int) {
        let style = Style(noColor: noColor)
        let graph = result.graph
        let summary = graph.summary

        let counts =
            "\(summary.fileCount.formatted()) files · \(summary.directoryCount.formatted()) folders"
        let timing = String(format: "%.1fs", summary.wallSeconds)
        print(style.bold("DiskSleuth") + style.dim(" · \(counts) · \(timing)\(summary.partial ? " · PARTIAL (cancelled)" : "")"))

        let lensLine =
            "logical \(fmt(summary.totalLogical)) · physical \(fmt(summary.totalPhysical))"
            + " · freeable now \(fmt(summary.totalUnique))"
        print(style.dim(lensLine))

        var notes: [String] = []
        if summary.cloneFileCount > 0 { notes.append("\(summary.cloneFileCount.formatted()) clones ⧉") }
        if summary.hardlinkedFileCount > 0 { notes.append("\(summary.hardlinkedFileCount.formatted()) hardlinks ⛓") }
        if summary.sparseFileCount > 0 { notes.append("\(summary.sparseFileCount.formatted()) sparse ▤") }
        if summary.datalessFileCount > 0 { notes.append("\(summary.datalessFileCount.formatted()) in-cloud ☁") }
        if !notes.isEmpty { print(style.dim(notes.joined(separator: " · "))) }
        print()

        TreePrinter(
            graph: graph, lens: sizeMode, style: style, binaryUnits: binaryUnits,
            maxDepth: depth, topPerLevel: top
        ).printTree()

        if summary.deniedDirectoryCount > 0 {
            print()
            var warning =
                "⚠ \(summary.deniedDirectoryCount) folder\(summary.deniedDirectoryCount == 1 ? "" : "s") could not be read — totals undercount."
            if graph.ledger.likelyNeedsFullDiskAccess {
                warning += " Grant your terminal Full Disk Access in System Settings → Privacy & Security."
            }
            print(style.yellow(warning))
        }
        if snapshotCount > 0 && sizeMode == .unique {
            print(
                style.dim(
                    "◷ \(snapshotCount) local Time Machine snapshot\(snapshotCount == 1 ? "" : "s") exist — freed space may appear gradually."
                ))
        }
        if summary.usedFallback {
            print(style.dim("(slow directory-listing fallback was used on this filesystem)"))
        }
    }

    private struct JSONNode: Codable {
        var name: String
        var kind: String
        var logical: Int64
        var physical: Int64
        var freeable: Int64
        var badges: [String]
        var children: [JSONNode]?
        var collapsedChildren: Int?
    }

    private func printJSON(result: ScanResult, snapshotCount: Int) throws {
        struct Payload: Codable {
            var schemaVersion = 1
            var root: String
            var filesystem: String
            var files: Int
            var directories: Int
            var totalLogical: Int64
            var totalPhysical: Int64
            var totalFreeable: Int64
            var cloneFiles: Int
            var hardlinkedFiles: Int
            var sparseFiles: Int
            var datalessFiles: Int
            var deniedDirectories: Int
            var localSnapshots: Int
            var partial: Bool
            var wallSeconds: Double
            var tree: JSONNode
        }

        let graph = result.graph
        let summary = graph.summary
        let payload = Payload(
            root: graph.rootPath,
            filesystem: result.volume.fsTypeName,
            files: summary.fileCount,
            directories: summary.directoryCount,
            totalLogical: summary.totalLogical,
            totalPhysical: summary.totalPhysical,
            totalFreeable: summary.totalUnique,
            cloneFiles: summary.cloneFileCount,
            hardlinkedFiles: summary.hardlinkedFileCount,
            sparseFiles: summary.sparseFileCount,
            datalessFiles: summary.datalessFileCount,
            deniedDirectories: summary.deniedDirectoryCount,
            localSnapshots: snapshotCount,
            partial: summary.partial,
            wallSeconds: summary.wallSeconds,
            tree: jsonNode(graph: graph, node: graph.root, depth: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }

    private func jsonNode(graph: FileGraph, node: NodeID, depth: Int) -> JSONNode {
        let sizes = graph.sizes(of: node)
        let flags = graph.flags(of: node)
        var badges: [String] = []
        if flags.cloned { badges.append("clone") }
        if flags.sparse { badges.append("sparse") }
        if flags.hardlinked { badges.append("hardlink") }
        if flags.dataless { badges.append("dataless") }
        if flags.compressed { badges.append("compressed") }
        if flags.accessDenied { badges.append("denied") }
        if flags.otherVolume { badges.append("otherVolume") }
        if flags.duplicate { badges.append("duplicate") }
        if flags.firmlinkSkipped { badges.append("firmlinkTarget") }
        if flags.externalLinks { badges.append("sharedOutside") }

        var children: [JSONNode]?
        var collapsed: Int?
        if flags.kind == .directory && depth < self.depth {
            let all = graph.children(of: node)
            let ranked = all.sorted { graph.size(of: $0, lens: sizeMode) > graph.size(of: $1, lens: sizeMode) }
            children = ranked.prefix(top).map { jsonNode(graph: graph, node: $0, depth: depth + 1) }
            if all.count > top { collapsed = all.count - top }
        }

        return JSONNode(
            name: depth == 0 ? graph.rootPath : graph.name(of: node),
            kind: flags.kind == .directory ? "directory" : flags.kind == .symlink ? "symlink" : "file",
            logical: sizes.logical,
            physical: sizes.physical,
            freeable: sizes.unique,
            badges: badges,
            children: children,
            collapsedChildren: collapsed
        )
    }
}

extension SizeLens: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "logical", "l": self = .logical
        case "physical", "p": self = .physical
        case "unique", "freeable", "u", "f": self = .unique
        default: return nil
        }
    }
}
