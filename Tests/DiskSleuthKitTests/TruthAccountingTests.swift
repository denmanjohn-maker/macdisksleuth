import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Truth accounting", .enabled(if: FixtureTree.volumeSupportsCloning(at: FileManager.default.temporaryDirectory.path)))
struct TruthAccountingTests {
    static let megabyte = 1 << 20

    @Test("A clone family is charged once physically; each member frees ~nothing alone")
    func cloneFamilyCountedOnce() async throws {
        let fixture = try FixtureTree()
        let size = 10 * Self.megabyte
        let original = try fixture.file("original.bin", size: size)
        try fixture.clone(of: original, at: "copy1.bin")
        try fixture.clone(of: original, at: "copy2.bin")

        let graph = try await scanGraph(fixture.rootPath)
        let total = graph.sizes(of: graph.root)

        // Three 10 MB names, 10 MB of real disk.
        #expect(within(total.physical, of: Int64(size)))
        #expect(within(total.logical, of: Int64(3 * size)))
        // Deleting the whole folder really frees the shared 10 MB.
        #expect(within(total.unique, of: Int64(size)))

        for name in ["original.bin", "copy1.bin", "copy2.bin"] {
            let sizes = try #require(graph.sizes(at: name))
            #expect(within(sizes.physical, of: Int64(size)), "per-file physical stays individual truth")
            #expect(within(sizes.unique, of: 0), "deleting one clone frees ~nothing")
            let node = try #require(graph.node(at: name))
            #expect(graph.flags(of: node).cloned)
        }
    }

    @Test("A diverged clone's unique size reflects its rewritten bytes, and orphaned sharing is flagged")
    func divergedClone() async throws {
        let fixture = try FixtureTree()
        let size = 10 * Self.megabyte
        let original = try fixture.file("original.bin", size: size)
        try fixture.clone(of: original, at: "diverged.bin")
        try fixture.overwrite("diverged.bin", offset: 0, length: 2 * Self.megabyte)

        let graph = try await scanGraph(fixture.rootPath)

        // Writing to a clone splits the APFS clone family (new cloneID,
        // refcnt drops to 1) even though ~8 MB stays physically shared.
        // Per-file truth stays exact: each file's unique is its rewritten bytes.
        let diverged = try #require(graph.sizes(at: "diverged.bin"))
        #expect(within(diverged.unique, of: Int64(2 * Self.megabyte), tolerance: 512 * 1024))
        let original2 = try #require(graph.sizes(at: "original.bin"))
        #expect(within(original2.unique, of: Int64(2 * Self.megabyte), tolerance: 512 * 1024))

        // The orphaned sharing can't be linked through available metadata, so
        // both files must carry the "shares bytes with content elsewhere" flag
        // rather than the graph silently over- or under-promising.
        for name in ["original.bin", "diverged.bin"] {
            let node = try #require(graph.node(at: name))
            #expect(graph.flags(of: node).externalLinks, "\(name) should be flagged")
        }
        // Root unique stays conservative: only what deletion provably frees now.
        #expect(within(graph.sizes(of: graph.root).unique, of: Int64(4 * Self.megabyte), tolerance: 1 << 20))
    }

    @Test("Hardlinked content counts once, and becomes freeable only at the folder holding every link")
    func hardlinkLCACharging() async throws {
        let fixture = try FixtureTree()
        let size = 6 * Self.megabyte
        try fixture.directory("a")
        try fixture.directory("b")
        let original = try fixture.file("a/data.bin", size: size)
        try fixture.hardlink(of: original, at: "b/link.bin")

        let graph = try await scanGraph(fixture.rootPath)

        // Each link shows individual truth but frees nothing alone.
        let inA = try #require(graph.sizes(at: "a/data.bin"))
        let inB = try #require(graph.sizes(at: "b/link.bin"))
        #expect(within(inA.physical, of: Int64(size)))
        #expect(within(inB.physical, of: Int64(size)))
        #expect(inA.unique == 0)
        #expect(inB.unique == 0)

        // Neither folder alone can free the bytes...
        #expect(try #require(graph.sizes(at: "a")).unique == 0)
        #expect(try #require(graph.sizes(at: "b")).unique == 0)
        // ...but their common parent holds all links: counted once, freeable once.
        let total = graph.sizes(of: graph.root)
        #expect(within(total.physical, of: Int64(size)))
        #expect(within(total.unique, of: Int64(size)))
    }

    @Test("Sparse files report physical well below logical")
    func sparseFile() async throws {
        let fixture = try FixtureTree()
        try fixture.sparse("holey.bin", dataBytes: Self.megabyte, logicalSize: 100 * Self.megabyte)

        let graph = try await scanGraph(fixture.rootPath)
        let sizes = try #require(graph.sizes(at: "holey.bin"))
        #expect(sizes.logical == Int64(100 * Self.megabyte))
        #expect(within(sizes.physical, of: Int64(Self.megabyte), tolerance: 256 * 1024))
        let expected = try fixture.physicalSize("holey.bin")
        #expect(within(sizes.physical, of: expected), "matches the kernel's own st_blocks")
    }

    @Test("Engine physical totals match st_blocks ground truth on a mixed tree")
    func mixedTreeMatchesKernel() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("x/y")
        try fixture.file("x/a.bin", size: 3 * Self.megabyte)
        try fixture.file("x/y/b.bin", size: 5 * Self.megabyte)
        let src = try fixture.file("big.bin", size: 8 * Self.megabyte)
        try fixture.clone(of: src, at: "x/big-clone.bin")
        try fixture.sparse("x/y/sparse.bin", dataBytes: Self.megabyte / 2, logicalSize: 64 * Self.megabyte)

        let graph = try await scanGraph(fixture.rootPath)
        // Ground truth: 3 + 5 + 8 (clone family once) + 0.5 sparse.
        let expected = Int64((3 + 5 + 8) * Self.megabyte + Self.megabyte / 2)
        #expect(within(graph.sizes(of: graph.root).physical, of: expected, tolerance: 512 * 1024))
    }
}
