import ArgumentParser
import DiskSleuthKit
import Foundation

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan and write the results to a JSON, CSV, or Markdown file."
    )

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case json, csv, markdown
    }

    @Argument(help: "Directory to scan (default: current directory).")
    var path: String = "."

    @Option(name: .customLong("format"), help: "Output format: json, csv, or markdown.")
    var format: Format = .json

    @Option(name: .customLong("output"), help: "Destination file (default: stdout).")
    var output: String?

    @Option(name: .customLong("depth"), help: "How many directory levels to include.")
    var depth: Int = 2

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB) in Markdown.")
    var binaryUnits = false

    func run() async throws {
        let target = (path as NSString).expandingTildeInPath
        let result = try await ScanRunner.run(path: target)
        // History is a convenience here, not the deliverable; a store failure must not block the export.
        _ = try? ScanStore().storeScanResult(result, options: ScanOptions())

        let text: String
        switch format {
        case .json: text = try json(result)
        case .csv: text = csv(result)
        case .markdown: text = markdown(result)
        }

        if let output {
            let destination = (output as NSString).expandingTildeInPath
            try text.write(toFile: destination, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Exported to \(destination)\n".utf8))
        } else {
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        }
    }

    // MARK: - Rows

    private struct Row: Codable {
        var path: String
        var kind: String
        var depth: Int
        var logical: Int64
        var physical: Int64
        var freeable: Int64
    }

    /// Depth-first rows down to `depth`, children in size order.
    private func rows(_ graph: FileGraph) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: NodeID, level: Int) {
            let sizes = graph.sizes(of: node)
            let kind = graph.kind(of: node)
            rows.append(
                Row(
                    path: graph.path(of: node),
                    kind: kind == .directory ? "directory" : kind == .symlink ? "symlink" : "file",
                    depth: level, logical: sizes.logical, physical: sizes.physical, freeable: sizes.unique))
            guard kind == .directory, level < depth else { return }
            for child in graph.children(of: node) { visit(child, level: level + 1) }
        }
        visit(graph.root, level: 0)
        return rows
    }

    // MARK: - Formats

    private func json(_ result: ScanResult) throws -> String {
        struct Payload: Codable {
            var schemaVersion = 1
            var root: String
            var filesystem: String
            var exportedAt: Date
            var summary: ScanSummary
            var rows: [Row]
        }
        let payload = Payload(
            root: result.graph.rootPath, filesystem: result.volume.fsTypeName, exportedAt: Date(),
            summary: result.graph.summary, rows: rows(result.graph))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private func csv(_ result: ScanResult) -> String {
        var lines = ["path,kind,depth,logical,physical,freeable"]
        for row in rows(result.graph) {
            lines.append("\(csvQuote(row.path)),\(row.kind),\(row.depth),\(row.logical),\(row.physical),\(row.freeable)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvQuote(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func markdown(_ result: ScanResult) -> String {
        let summary = result.graph.summary
        func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }

        var md = "# DiskSleuth Export\n\n"
        md += "**Root:** `\(result.graph.rootPath)`  \n"
        md += "**Filesystem:** \(result.volume.fsTypeName)  \n"
        md += "**Scanned:** \(Date().formatted(.dateTime))\n\n"
        md += "## Summary\n\n"
        md += "| Metric | Value |\n|---|---|\n"
        md += "| Files | \(summary.fileCount.formatted()) |\n"
        md += "| Folders | \(summary.directoryCount.formatted()) |\n"
        md += "| Logical | \(fmt(summary.totalLogical)) |\n"
        md += "| Physical | \(fmt(summary.totalPhysical)) |\n"
        md += "| Freeable now | \(fmt(summary.totalUnique)) |\n"
        md += "| Clone files | \(summary.cloneFileCount.formatted()) |\n"
        md += "| Hardlinked files | \(summary.hardlinkedFileCount.formatted()) |\n"
        md += "| Unreadable folders | \(summary.deniedDirectoryCount.formatted()) |\n\n"
        md += "## Contents (depth \(depth))\n\n"
        md += "| Path | Kind | Logical | Physical | Freeable |\n|---|---|---:|---:|---:|\n"
        for row in rows(result.graph) {
            let indent = String(repeating: "&nbsp;&nbsp;", count: row.depth)
            md += "| \(indent)`\(row.path)` | \(row.kind) | \(fmt(row.logical)) | \(fmt(row.physical)) | \(fmt(row.freeable)) |\n"
        }
        return md
    }
}
