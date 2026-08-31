import DiskSleuthKit
import Foundation

/// One annular sector of the sunburst. Pure geometry — no drawing.
struct SunburstSegment: Identifiable {
    enum Target {
        case node(NodeID)
        /// Collapsed tail of a directory's small children.
        case other(parent: NodeID, count: Int)
    }

    var id: String
    var target: Target
    var ring: Int
    var startFraction: Double
    var endFraction: Double
    /// Hue inherited from the ring-0 ancestor for stable family coloring.
    var hue: Double
    var isDirectory: Bool
    var flags: NodeFlags
    var bytes: Int64
    var name: String

    var midFraction: Double { (startFraction + endFraction) / 2 }
    var span: Double { endFraction - startFraction }
}

enum SunburstLayout {
    /// Lay out `rings` rings of descendants of `focus`, each segment's angular
    /// span proportional to its share of the focus subtree in the active lens.
    /// Children below `minFraction` of the circle collapse into an "other" arc.
    static func segments(
        graph: FileGraph, focus: NodeID, lens: SizeLens,
        rings: Int = 4, minFraction: Double = 0.004
    ) -> [SunburstSegment] {
        let focusSize = graph.size(of: focus, lens: lens)
        guard focusSize > 0 else { return [] }
        var result: [SunburstSegment] = []

        func layout(parent: NodeID, ring: Int, start: Double, end: Double, hue: Double?) {
            guard ring < rings, end - start > 0.0005 else { return }
            let children = graph.children(of: parent)
            guard !children.isEmpty else { return }

            let ranked = lens == .physical
                ? children
                : children.sorted { graph.size(of: $0, lens: lens) > graph.size(of: $1, lens: lens) }

            var cursor = start
            var otherBytes: Int64 = 0
            var otherCount = 0
            for (index, child) in ranked.enumerated() {
                let bytes = max(graph.size(of: child, lens: lens), 0)
                let fraction = Double(bytes) / Double(focusSize) * 1.0
                // Scale to the parent's window share of the whole circle.
                let span = fraction
                if span < minFraction || cursor + span > end + 0.000001 {
                    otherBytes += bytes
                    otherCount += 1
                    continue
                }
                let segmentHue = hue ?? Double((index * 5) % 13) / 13.0
                let flags = graph.flags(of: child)
                result.append(
                    SunburstSegment(
                        id: "n\(child.raw)-r\(ring)",
                        target: .node(child),
                        ring: ring,
                        startFraction: cursor,
                        endFraction: cursor + span,
                        hue: segmentHue,
                        isDirectory: flags.kind == .directory,
                        flags: flags,
                        bytes: bytes,
                        name: graph.name(of: child)
                    ))
                if flags.kind == .directory {
                    layout(parent: child, ring: ring + 1, start: cursor, end: cursor + span, hue: segmentHue)
                }
                cursor += span
            }
            if otherCount > 0 && otherBytes > 0 {
                let span = min(Double(otherBytes) / Double(focusSize), max(end - cursor, 0))
                if span > 0.0005 {
                    result.append(
                        SunburstSegment(
                            id: "o\(parent.raw)-r\(ring)",
                            target: .other(parent: parent, count: otherCount),
                            ring: ring,
                            startFraction: cursor,
                            endFraction: cursor + span,
                            hue: hue ?? 0,
                            isDirectory: false,
                            flags: NodeFlags(kind: .other),
                            bytes: otherBytes,
                            name: "\(otherCount) smaller items"
                        ))
                }
            }
        }

        layout(parent: focus, ring: 0, start: 0, end: 1, hue: nil)
        return result
    }

    /// Segment under a point in polar coordinates (fraction 0..1 from 12
    /// o'clock clockwise; ring index from radii), or nil.
    static func hitTest(
        segments: [SunburstSegment], fraction: Double, ring: Int
    ) -> SunburstSegment? {
        segments.first { $0.ring == ring && fraction >= $0.startFraction && fraction < $0.endFraction }
    }
}
