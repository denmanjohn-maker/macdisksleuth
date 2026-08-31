import DiskSleuthKit
import Foundation

/// Renders a FileGraph as an indented tree with honest sizes.
struct TreePrinter {
    var graph: FileGraph
    var lens: SizeLens
    var style: Style
    var binaryUnits: Bool
    var maxDepth: Int
    var topPerLevel: Int

    private func fmt(_ bytes: Int64) -> String {
        ByteCount.format(bytes, binary: binaryUnits)
    }

    static func badges(for flags: NodeFlags, style: Style) -> String {
        var parts: [String] = []
        if flags.cloned { parts.append("⧉") }
        if flags.sparse { parts.append("▤") }
        if flags.hardlinked { parts.append("⛓") }
        if flags.dataless { parts.append("☁") }
        if flags.compressed { parts.append("▣") }
        if flags.accessDenied { parts.append("⛔") }
        if flags.otherVolume { parts.append("⇥ other volume") }
        if flags.duplicate { parts.append("↩ already counted") }
        if flags.firmlinkSkipped { parts.append("→ counted at firmlink") }
        if flags.externalLinks { parts.append("✳ shared outside") }
        return parts.isEmpty ? "" : "  " + style.dim(parts.joined(separator: " "))
    }

    func printTree() {
        let rootSize = max(graph.size(of: graph.root, lens: lens), 1)
        printNode(graph.root, depth: 0, rootSize: rootSize)
    }

    private func bar(_ size: Int64, rootSize: Int64) -> String {
        let width = 10
        let fraction = Double(size) / Double(rootSize)
        let filled = Int((fraction * Double(width)).rounded())
        let blocks = String(repeating: "█", count: max(filled, 0))
            + String(repeating: "·", count: max(width - filled, 0))
        return style.dim("▕") + style.cyan(blocks) + style.dim("▏")
    }

    private func printNode(_ node: NodeID, depth: Int, rootSize: Int64) {
        let size = graph.size(of: node, lens: lens)
        let flags = graph.flags(of: node)
        let isDir = flags.kind == .directory
        let displayName = depth == 0 ? graph.rootPath : graph.name(of: node)
        let sizeText = fmt(size).padding(toLength: 11, withPad: " ", startingAt: 0)

        let indent = String(repeating: "  ", count: depth)
        let name = isDir ? style.boldBlue(displayName + "/") : displayName
        print("\(bar(size, rootSize: rootSize)) \(style.bold(sizeText))\(indent)\(name)\(Self.badges(for: flags, style: style))")

        guard isDir, depth < maxDepth else { return }
        let children = graph.children(of: node)
        // Children come sorted by physical; re-rank by the active lens.
        let ranked = lens == .physical
            ? children
            : children.sorted { graph.size(of: $0, lens: lens) > graph.size(of: $1, lens: lens) }

        var shown = 0
        var restCount = 0
        var restBytes: Int64 = 0
        for child in ranked {
            if shown < topPerLevel {
                printNode(child, depth: depth + 1, rootSize: rootSize)
                shown += 1
            } else {
                restCount += 1
                restBytes += graph.size(of: child, lens: lens)
            }
        }
        if restCount > 0 {
            let indent = String(repeating: "  ", count: depth + 1)
            let sizeText = fmt(restBytes).padding(toLength: 11, withPad: " ", startingAt: 0)
            print(
                "\(bar(restBytes, rootSize: rootSize)) \(style.dim(sizeText))\(indent)"
                    + style.dim("… \(restCount) more"))
        }
    }
}
