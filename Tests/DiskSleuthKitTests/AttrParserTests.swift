import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Attribute layer")
struct AttrParserTests {
    @Test("Names, kinds, and sizes match FileManager ground truth — including UTF-8 edge cases")
    func parseCorrectness() async throws {
        let fixture = try FixtureTree()
        try fixture.file("plain.bin", size: 8192)
        try fixture.file("émoji 🎉 name.bin", size: 4096)
        try fixture.file(String(repeating: "n", count: 250) + ".bin", size: 1024)
        try fixture.directory("subdir")
        try fixture.file("subdir/nested.bin", size: 2048)

        let graph = try await scanGraph(fixture.rootPath)

        // The regression that must never return: requesting the full attribute
        // set while parsing in the wrong order yields empty names with sizes
        // still "working". Every name must be present and exact.
        let names = Set(graph.children(of: graph.root).map { graph.name(of: $0) })
        #expect(names.contains("plain.bin"))
        #expect(names.contains("émoji 🎉 name.bin"))
        #expect(names.contains(String(repeating: "n", count: 250) + ".bin"))
        #expect(names.contains("subdir"))

        let plain = try #require(graph.node(at: "plain.bin"))
        #expect(graph.kind(of: plain) == .file)
        #expect(graph.sizes(of: plain).logical == 8192)

        let subdir = try #require(graph.node(at: "subdir"))
        #expect(graph.kind(of: subdir) == .directory)
        let nested = try #require(graph.node(at: "subdir/nested.bin"))
        #expect(graph.sizes(of: nested).logical == 2048)
    }

    @Test("Symlinks are recorded, never followed")
    func symlinksNotFollowed() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("real")
        try fixture.file("real/big.bin", size: 1 << 20)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.path("shortcut"), withDestinationPath: fixture.path("real"))

        let graph = try await scanGraph(fixture.rootPath)
        let link = try #require(graph.node(at: "shortcut"))
        #expect(graph.kind(of: link) == .symlink)
        #expect(graph.childCount(of: link) == 0)
        // The megabyte is charged to real/, not double-counted through the link.
        let total = graph.sizes(of: graph.root).physical
        #expect(within(total, of: 1 << 20))
    }

    @Test("Readdir fallback produces the same names and logical sizes as the bulk path")
    func fallbackAgreesWithBulk() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", size: 4096)
        try fixture.directory("d")
        try fixture.file("d/b.bin", size: 12288)

        let bulk = try await scanGraph(fixture.rootPath)
        let fallback = try await scanGraph(fixture.rootPath, options: ScanOptions(forceFallback: true))

        #expect(bulk.summary.fileCount == fallback.summary.fileCount)
        #expect(bulk.summary.totalLogical == fallback.summary.totalLogical)
        #expect(fallback.summary.usedFallback)
        #expect(fallback.sizes(at: "d/b.bin")?.logical == 12288)
    }
}
