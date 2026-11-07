import ArgumentParser
import DiskSleuthKit
import Foundation

struct WhatIf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "what-if",
        abstract: "Estimate how much space a cleanup scenario would really free."
    )

    enum Scenario: String, ExpressibleByArgument, CaseIterable {
        case clones, duplicates, purgeable
    }

    @Argument(help: "Directory to analyze (default: current directory).")
    var path: String = "."

    @Option(name: .customLong("scenario"), help: "clones, duplicates, or purgeable.")
    var scenario: Scenario = .clones

    @Option(name: .customLong("top"), help: "Largest matching files to list.")
    var top: Int = 10

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        let style = Style(noColor: noColor)
        print(style.bold("What if: \(scenario.rawValue)") + style.dim(" · \(target)"))
        print()

        switch scenario {
        case .clones:
            let result = try await ScanRunner.run(path: target)
            try reportFlagged(result.graph, style: style, matching: { $0.cloned },
                              noun: "APFS clone",
                              explanation: "Clones share blocks with their source. Deleting a clone frees only its unique blocks.")
        case .duplicates:
            let result = try await ScanRunner.run(path: target)
            try reportFlagged(result.graph, style: style, matching: { $0.duplicate },
                              noun: "duplicate",
                              explanation: "Duplicates are full copies, so deleting all but one copy frees their physical size.")
        case .purgeable:
            try await reportPurgeable(target, style: style)
        }
    }

    private func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }

    private func reportFlagged(
        _ graph: FileGraph, style: Style, matching: (NodeFlags) -> Bool, noun: String, explanation: String
    ) throws {
        var matches: [NodeID] = []
        var logical: Int64 = 0, physical: Int64 = 0, unique: Int64 = 0
        for raw in 0..<graph.nodeCount {
            let node = NodeID(raw: Int32(raw))
            let flags = graph.flags(of: node)
            guard flags.kind == .file, matching(flags) else { continue }
            matches.append(node)
            let sizes = graph.sizes(of: node)
            logical += sizes.logical
            physical += sizes.physical
            unique += sizes.unique
        }

        if matches.isEmpty {
            print("No \(noun) files under \(graph.rootPath).")
            return
        }

        print("  \(matches.count.formatted()) \(noun) file\(matches.count == 1 ? "" : "s")")
        print("  logical \(fmt(logical)) · physical \(fmt(physical)) · " + style.green("freeable now \(fmt(unique))"))
        print(style.dim("  " + explanation))
        print()

        let ranked = graph.sorted(matches, by: NodeSort(keys: [NodeSort.Key(lens: .unique)]))
        for node in ranked.prefix(top) {
            let sizes = graph.sizes(of: node)
            print("  \(style.cyan(fmt(sizes.unique).padding(toLength: 10, withPad: " ", startingAt: 0)))  \(graph.path(of: node))")
        }
        if ranked.count > top { print(style.dim("  … \(ranked.count - top) more")) }
    }

    private func reportPurgeable(_ target: String, style: Style) async throws {
        let identity = try VolumeService.identity(ofPath: target)
        let capacities = try VolumeService.capacities(ofVolume: identity.mountPoint)
        let snapshots = try await VolumeService.snapshots(ofVolume: identity.mountPoint)

        print("  Volume \(identity.mountPoint) (\(identity.fsTypeName))")
        print("  available now        \(fmt(capacities.availableNow))")
        print("  available if purged  \(fmt(capacities.availableForImportantUsage))")
        print("  " + style.green("purgeable            \(fmt(capacities.purgeable))"))
        print()
        if snapshots.isEmpty {
            print(style.dim("  No local Time Machine snapshots."))
        } else {
            print(style.dim("  \(snapshots.count) local Time Machine snapshot\(snapshots.count == 1 ? "" : "s") hold much of this; see `disksleuth cleanup --remove-snapshots --dry-run`."))
        }
        print(style.dim("  macOS reclaims purgeable space automatically under disk pressure."))
    }
}
