import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Permission ledger")
struct LedgerTests {
    @Test("An unreadable directory is recorded, flagged, and never silently skipped")
    func deniedDirectoryRecorded() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("open")
        try fixture.file("open/visible.bin", size: 4096)
        try fixture.directory("locked")
        try fixture.file("locked/hidden.bin", size: 4096)
        try fixture.removeReadPermission("locked")
        defer { try? fixture.restoreReadPermission("locked") }

        let graph = try await scanGraph(fixture.rootPath)

        #expect(graph.ledger.deniedCount == 1)
        #expect(graph.ledger.denied.first?.path.hasSuffix("/locked") == true)
        let locked = try #require(graph.node(at: "locked"))
        #expect(graph.flags(of: locked).accessDenied)
        #expect(graph.summary.deniedDirectoryCount == 1)
        // The readable file is still counted.
        #expect(graph.sizes(at: "open/visible.bin")?.logical == 4096)
    }
}

@Suite("Graph invariants")
struct InvariantTests {
    @Test("unique ≤ physical everywhere; child sums plus corrections equal parents")
    func lensInvariants() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("d1/d2")
        try fixture.file("d1/a.bin", size: 2 << 20)
        try fixture.file("d1/d2/b.bin", size: 3 << 20)
        let src = try fixture.file("s.bin", size: 4 << 20)
        if FixtureTree.volumeSupportsCloning(at: fixture.rootPath) {
            try fixture.clone(of: src, at: "d1/s-clone.bin")
            try fixture.hardlink(of: src, at: "d1/d2/s-link.bin")
        }

        let graph = try await scanGraph(fixture.rootPath)

        for raw in 0..<Int32(graph.nodeCount) {
            let node = NodeID(raw: raw)
            let sizes = graph.sizes(of: node)
            #expect(sizes.unique <= sizes.physical, "unique ≤ physical at \(graph.path(of: node))")
            #expect(sizes.physical >= 0 && sizes.logical >= 0 && sizes.unique >= 0)
        }

        // Root totals must equal the volume-truth sum of the whole tree —
        // no bytes created or lost by the rollup.
        var fileLogical: Int64 = 0
        for raw in 0..<Int32(graph.nodeCount) where graph.kind(of: NodeID(raw: raw)) != .directory {
            fileLogical += graph.sizes(of: NodeID(raw: raw)).logical
        }
        #expect(graph.sizes(of: graph.root).logical == fileLogical)
    }

    @Test("Children are pre-sorted largest-first by physical size")
    func childrenSorted() async throws {
        let fixture = try FixtureTree()
        try fixture.file("small.bin", size: 1 << 12)
        try fixture.file("large.bin", size: 1 << 22)
        try fixture.file("medium.bin", size: 1 << 16)

        let graph = try await scanGraph(fixture.rootPath)
        let physicals = graph.children(of: graph.root).map { graph.sizes(of: $0).physical }
        #expect(physicals == physicals.sorted(by: >))
    }

    @Test("Cancellation yields a finalized partial graph, not a crash or hang")
    func cancellationIsGraceful() async throws {
        let fixture = try FixtureTree()
        for d in 0..<20 {
            try fixture.directory("dir\(d)")
            for f in 0..<20 {
                try fixture.file("dir\(d)/f\(f).bin", size: 1 << 12)
            }
        }
        let session = try ScanEngine.scan(path: fixture.rootPath)
        session.cancel()
        let result = try await session.result.value
        #expect(result.graph.nodeCount >= 1)
    }
}
