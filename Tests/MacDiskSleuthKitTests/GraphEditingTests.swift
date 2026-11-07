import MacDiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Graph editing")
struct GraphEditingTests {
    func allSizesNonNegative(_ graph: FileGraph) -> Bool {
        (0..<graph.nodeCount).allSatisfy { raw in
            let sizes = graph.sizes(of: NodeID(raw: Int32(raw)))
            return sizes.logical >= 0 && sizes.physical >= 0 && sizes.unique >= 0
        }
    }

    @Test("Removing several nodes at once equals removing them one by one")
    func batchEqualsSequential() async throws {
        let fixture = try QueryTests.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let big = try #require(graph.node(at: "media/big.mov"))
        let clip = try #require(graph.node(at: "media/clip.mp4"))
        let notes = try #require(graph.node(at: "notes.txt"))

        let batch = graph.removing(all: [big, clip])
        let sequential = graph.removing(big).removing(clip)
        #expect(batch.sizes(of: batch.root) == sequential.sizes(of: sequential.root))
        let media = try #require(graph.node(at: "media"))
        #expect(batch.sizes(of: media) == sequential.sizes(of: media))

        let removedBytes = graph.sizes(of: big).logical + graph.sizes(of: clip).logical
        #expect(batch.sizes(of: batch.root).logical == graph.sizes(of: graph.root).logical - removedBytes)
        #expect(batch.isRemoved(big) && batch.isRemoved(clip))
        #expect(!batch.isRemoved(notes))
        #expect(!graph.isRemoved(big), "the original graph is untouched")
        #expect(allSizesNonNegative(batch))
    }

    @Test("A node and its ancestor in one batch count once")
    func nestedBatch() async throws {
        let fixture = try QueryTests.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let media = try #require(graph.node(at: "media"))
        let big = try #require(graph.node(at: "media/big.mov"))

        let nested = graph.removing(all: [big, media])
        let folderOnly = graph.removing(media)
        #expect(nested.sizes(of: nested.root) == folderOnly.sizes(of: folderOnly.root))
        #expect(nested.isRemoved(media))
        #expect(allSizesNonNegative(nested))
        #expect(nested.query(kind: .file).nodes.map { nested.name(of: $0) } == ["blob.tmp", "notes.txt", ".DS_Store"])
    }

    @Test("Children of a removed folder read as removed, and are never subtracted again")
    func descendantsOfRemovedFolder() async throws {
        let fixture = try QueryTests.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let media = try #require(graph.node(at: "media"))
        let big = try #require(graph.node(at: "media/big.mov"))

        let folderGone = graph.removing(media)
        #expect(folderGone.isRemoved(big), "inside a removed folder")
        #expect(!folderGone.isRemoved(graph.root))

        let again = folderGone.removing(all: [big])
        #expect(again.sizes(of: again.root) == folderGone.sizes(of: folderGone.root), "nothing to subtract twice")
        #expect(allSizesNonNegative(again))
    }

    @Test("Already-removed nodes, the root, and an empty batch are no-ops")
    func noOps() async throws {
        let fixture = try QueryTests.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let big = try #require(graph.node(at: "media/big.mov"))

        let once = graph.removing(big)
        let twice = once.removing(all: [big, big])
        #expect(twice.sizes(of: twice.root) == once.sizes(of: once.root))

        let untouched = graph.removing(all: [NodeID]())
        #expect(untouched.sizes(of: untouched.root) == graph.sizes(of: graph.root))
        let rootKept = graph.removing(all: [graph.root])
        #expect(rootKept.sizes(of: rootKept.root) == graph.sizes(of: graph.root))
        #expect(!rootKept.isRemoved(graph.root))
    }
}

@Suite("Graph editing with shared bytes", .enabled(if: FixtureTree.volumeSupportsCloning(at: FileManager.default.temporaryDirectory.path)))
struct GraphEditingSharingTests {
    @Test("Removing both halves of a hard-link pair never publishes negative or inflated totals")
    func hardlinkPairRemoval() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("a")
        try fixture.directory("b")
        let original = try fixture.file("a/data.bin", size: 6 << 20)
        try fixture.hardlink(of: original, at: "b/link.bin")
        let graph = try await scanGraph(fixture.rootPath)
        let a = try #require(graph.node(at: "a"))
        let b = try #require(graph.node(at: "b"))

        let emptied = graph.removing(all: [a, b])
        for raw in 0..<Int32(emptied.nodeCount) {
            let sizes = emptied.sizes(of: NodeID(raw: raw))
            #expect(sizes.logical >= 0 && sizes.physical >= 0 && sizes.unique >= 0)
            #expect(sizes.unique <= sizes.physical, "unique ≤ physical survives edits")
        }
        // The shared-bytes correction charged at the root cannot be re-derived
        // without a rescan; the invariants above still pin the empty root at zero.
        let root = emptied.sizes(of: emptied.root)
        #expect(root.logical == 0 && root.physical == 0 && root.unique == 0)
    }
}

