import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

func scanGraph(_ path: String, options: ScanOptions = ScanOptions()) async throws -> FileGraph {
    try await ScanEngine.scan(path: path, options: options).result.value.graph
}

extension FileGraph {
    /// Locate a node by slash-separated path relative to the root.
    func node(at relativePath: String) -> NodeID? {
        var current = root
        for component in relativePath.split(separator: "/") {
            guard let next = children(of: current).first(where: { name(of: $0) == String(component) })
            else { return nil }
            current = next
        }
        return current
    }

    func sizes(at relativePath: String) -> Sizes? {
        node(at: relativePath).map { sizes(of: $0) }
    }
}

/// Physical sizes on APFS come in 4 KiB block granularity; metadata wiggle
/// (inline extents, xattrs) stays well under this.
func within(_ actual: Int64, of expected: Int64, tolerance: Int64 = 64 * 1024) -> Bool {
    abs(actual - expected) <= tolerance
}
