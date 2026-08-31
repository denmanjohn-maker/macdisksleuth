import ArgumentParser
import DiskSleuthKit
import Foundation

struct Top: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The biggest files or folders under a path, with honest sizes."
    )

    @Argument(help: "Directory to scan (default: current directory).")
    var path: String = "."

    @Option(name: .shortAndLong, help: "How many items to show.")
    var number: Int = 25

    @Flag(help: "Rank folders instead of files.")
    var dirs = false

    @Option(name: .customLong("size-mode"), help: "Lens: logical, physical, or unique (freeable).")
    var sizeMode: SizeLens = .physical

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        let result = try await ScanRunner.run(path: target)
        let graph = result.graph

        var candidates: [NodeID] = []
        candidates.reserveCapacity(graph.nodeCount / 4)
        for raw in 0..<Int32(graph.nodeCount) {
            let node = NodeID(raw: raw)
            let kind = graph.kind(of: node)
            if dirs {
                if kind == .directory && raw != 0 { candidates.append(node) }
            } else {
                if kind == .file { candidates.append(node) }
            }
        }
        candidates.sort { graph.size(of: $0, lens: sizeMode) > graph.size(of: $1, lens: sizeMode) }
        let winners = Array(candidates.prefix(number))

        if json {
            struct Row: Codable {
                var path: String
                var logical: Int64
                var physical: Int64
                var freeable: Int64
            }
            struct Payload: Codable {
                var schemaVersion = 1
                var root: String
                var rankedBy: String
                var items: [Row]
            }
            let rows = winners.map { node in
                let sizes = graph.sizes(of: node)
                return Row(
                    path: graph.path(of: node), logical: sizes.logical,
                    physical: sizes.physical, freeable: sizes.unique)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(
                String(
                    decoding: try encoder.encode(
                        Payload(root: graph.rootPath, rankedBy: sizeMode.rawValue, items: rows)),
                    as: UTF8.self))
            return
        }

        let style = Style(noColor: noColor)
        func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }

        let header = "  " + "LOGICAL".padding(toLength: 11, withPad: " ", startingAt: 0)
            + "PHYSICAL".padding(toLength: 11, withPad: " ", startingAt: 0)
            + "FREEABLE".padding(toLength: 11, withPad: " ", startingAt: 0) + "PATH"
    print(style.dim(header))
        for node in winners {
            let sizes = graph.sizes(of: node)
            let flags = graph.flags(of: node)
            let line = "  "
                + fmt(sizes.logical).padding(toLength: 11, withPad: " ", startingAt: 0)
                + style.bold(fmt(sizes.physical).padding(toLength: 11, withPad: " ", startingAt: 0))
                + style.green(fmt(sizes.unique).padding(toLength: 11, withPad: " ", startingAt: 0))
                + graph.path(of: node)
                + TreePrinter.badges(for: flags, style: style)
            print(line)
        }
        if graph.summary.deniedDirectoryCount > 0 {
            print(style.yellow("⚠ \(graph.summary.deniedDirectoryCount) folders unreadable — see `disksleuth scan` for details."))
        }
    }
}
