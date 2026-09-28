import ArgumentParser
import DiskSleuthKit
import Foundation

struct Top: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The biggest files or folders under a path, with honest sizes.",
        discussion: """
            Filters combine (all must match). Sizes accept 500MB, 1.5GiB, 4k, or plain bytes.
            --min-size and --min-percent measure with --size-mode.

            Examples:
              disksleuth top ~ --ext mov,mp4 --min-size 500MB
              disksleuth top ~ --only clone --sort freeable,logical
              disksleuth top ~/Library --include '*cache*' --exclude '.DS_Store'
              disksleuth top ~ --dirs --min-percent 2 --reverse
            """
    )

    @Argument(help: "Directory to scan (default: current directory).")
    var path: String = "."

    @Option(name: .shortAndLong, help: "How many items to show.")
    var number: Int = 25

    @Flag(help: "Rank folders instead of files.")
    var dirs = false

    @Option(name: .customLong("size-mode"), help: "Lens: logical, physical, or unique (freeable).")
    var sizeMode: SizeLens = .physical

    @Option(name: .customLong("min-size"), help: "Only items at least this big (e.g. 100MB).")
    var minSize: SizeArgument?

    @Option(name: .customLong("max-size"), help: "Only items at most this big (e.g. 5GB).")
    var maxSize: SizeArgument?

    @Option(name: .customLong("min-percent"), help: "Only items at least this % of the scanned total.")
    var minPercent: Double?

    @Option(name: .customLong("ext"), help: "Only files with these extensions (comma-separated, repeatable).")
    var extensions: [String] = []

    @Option(name: .customLong("exclude-ext"), help: "Skip files with these extensions.")
    var excludeExtensions: [String] = []

    @Option(name: .customLong("include"), help: "Only items matching this glob (repeatable; a pattern with / matches the full path).")
    var includeGlobs: [String] = []

    @Option(name: .customLong("exclude"), help: "Skip items matching this glob (repeatable).")
    var excludeGlobs: [String] = []

    @Option(name: .customLong("only"), help: "Only files that are: clone, hardlink, sparse, dataless, compressed, shared-outside (comma-separated).")
    var onlyAttributes: [String] = []

    @Option(name: .customLong("sort"), help: "Sort keys: logical, physical, freeable, name, path — comma-separated for tiebreaks (default: --size-mode).")
    var sort: String?

    @Flag(name: .customLong("reverse"), help: "Reverse the sort order.")
    var reverse = false

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func validate() throws {
        let filter = try makeFilter()
        _ = try parseSort(sort, default: sizeMode, reverse: reverse)
        if dirs && filter.hasFileOnlyCriteria {
            throw ValidationError("--ext, --exclude-ext, and --only apply to files; drop them or --dirs.")
        }
        if let minSize, let maxSize, minSize.bytes > maxSize.bytes {
            throw ValidationError("--min-size is larger than --max-size.")
        }
        if let minPercent, !(0...100).contains(minPercent) {
            throw ValidationError("--min-percent must be between 0 and 100.")
        }
        if number < 0 { throw ValidationError("--number must be 0 or more.") }
    }

    private func makeFilter() throws -> NodeFilter {
        var filter = NodeFilter()
        filter.lens = sizeMode
        filter.minSize = minSize?.bytes
        filter.maxSize = maxSize?.bytes
        filter.minPercent = minPercent
        filter.includeExtensions = Set(splitList(extensions).map(NodeFilter.normalizedExtension))
        filter.excludeExtensions = Set(splitList(excludeExtensions).map(NodeFilter.normalizedExtension))
        filter.includeGlobs = includeGlobs
        filter.excludeGlobs = excludeGlobs
        filter.requiredAttributes = try parseAttributes(onlyAttributes)
        return filter
    }

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        let filter = try makeFilter()
        let order = try parseSort(sort, default: sizeMode, reverse: reverse)

        let result = try await ScanRunner.run(path: target)
        let graph = result.graph
        let query = graph.query(
            kind: dirs ? .directory : .file, filter: filter, sort: order, limit: number)
        let winners = query.nodes

        let rootSize = graph.size(of: graph.root, lens: sizeMode)
        func percent(_ node: NodeID) -> Double {
            rootSize > 0 ? Double(graph.size(of: node, lens: sizeMode)) / Double(rootSize) * 100 : 0
        }

        if json {
            struct Row: Codable {
                var path: String
                var logical: Int64
                var physical: Int64
                var freeable: Int64
                var percent: Double
            }
            struct Filters: Codable {
                var minSize: Int64?
                var maxSize: Int64?
                var minPercent: Double?
                var extensions: [String]
                var excludeExtensions: [String]
                var include: [String]
                var exclude: [String]
                var only: [String]
            }
            struct Payload: Codable {
                var schemaVersion = 2
                var root: String
                var rankedBy: String
                var sort: [String]
                var reverse: Bool
                var filters: Filters
                var matched: Int
                var candidates: Int
                var items: [Row]
            }
            let rows = winners.map { node in
                let sizes = graph.sizes(of: node)
                return Row(
                    path: graph.path(of: node), logical: sizes.logical,
                    physical: sizes.physical, freeable: sizes.unique,
                    percent: (percent(node) * 100).rounded() / 100)
            }
            let filters = Filters(
                minSize: filter.minSize, maxSize: filter.maxSize, minPercent: filter.minPercent,
                extensions: filter.includeExtensions.sorted(),
                excludeExtensions: filter.excludeExtensions.sorted(),
                include: filter.includeGlobs, exclude: filter.excludeGlobs,
                only: filter.requiredAttributes.map(\.rawValue).sorted())
            let payload = Payload(
                root: graph.rootPath, rankedBy: sizeMode.rawValue,
                sort: order.keys.map(\.rawValue), reverse: order.reverse, filters: filters,
                matched: query.matchedCount, candidates: query.candidateCount, items: rows)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            return
        }

        let style = Style(noColor: noColor)
        func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }
        func column(_ text: String, _ width: Int = 11) -> String {
            text.padding(toLength: width, withPad: " ", startingAt: 0)
        }

        let header = "  " + column("LOGICAL") + column("PHYSICAL") + column("FREEABLE")
            + column("%", 7) + "PATH"
        print(style.dim(header))
        for node in winners {
            let sizes = graph.sizes(of: node)
            let flags = graph.flags(of: node)
            let line = "  "
                + column(fmt(sizes.logical))
                + style.bold(column(fmt(sizes.physical)))
                + style.green(column(fmt(sizes.unique)))
                + style.dim(column(String(format: "%.1f%%", percent(node)), 7))
                + graph.path(of: node)
                + TreePrinter.badges(for: flags, style: style)
            print(line)
        }

        if !filter.isEmpty {
            let noun = dirs ? "folders" : "files"
            var footer = "\(query.matchedCount.formatted()) of \(query.candidateCount.formatted()) \(noun) matched"
            // Nested folder totals overlap, so a sum is only honest for files.
            if !dirs {
                let total = query.matchedTotals[sizeMode]
                footer += " · \(fmt(total)) \(sizeMode.displayName.lowercased()) total"
            }
            print(style.dim(footer))
        }
        if graph.summary.deniedDirectoryCount > 0 {
            print(style.yellow("⚠ \(graph.summary.deniedDirectoryCount) folders unreadable — see `disksleuth scan` for details."))
        }
    }
}
