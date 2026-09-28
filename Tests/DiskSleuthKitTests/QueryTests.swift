import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Size parsing")
struct SizeParsingTests {
    static let validSizes: [(String, Int64)] = [
        ("123", 123),
        ("0", 0),
        ("4k", 4_000),
        ("4K", 4_000),
        ("100MB", 100_000_000),
        ("100 mb", 100_000_000),
        ("1.5GB", 1_500_000_000),
        ("2GiB", 2 * 1024 * 1024 * 1024),
        ("1Ki", 1024),
        ("512b", 512),
        ("1TB", 1_000_000_000_000),
    ]

    @Test("Human sizes parse with decimal and binary units", arguments: validSizes)
    func parses(text: String, expected: Int64) {
        #expect(ByteCount.parse(text) == expected)
    }

    @Test("Garbage is rejected", arguments: ["", "MB", "abc", "1XB", "-5MB", "1iB", "10EB"])
    func rejects(text: String) {
        #expect(ByteCount.parse(text) == nil)
    }
}

@Suite("Sort key parsing")
struct SortKeyParsingTests {
    @Test("Comma-separated keys and aliases parse; unknown keys fail")
    func parseKeys() {
        #expect(NodeSort.parseKeys("freeable,logical") == [.freeable, .logical])
        #expect(NodeSort.parseKeys("unique, Name") == [.freeable, .name])
        #expect(NodeSort.parseKeys("size") == nil)
        #expect(NodeSort.parseKeys("") == nil)
    }

    @Test("File extensions ignore leading-dot hidden names")
    func extensions() {
        #expect(NodeFilter.fileExtension(of: "movie.MOV") == "mov")
        #expect(NodeFilter.fileExtension(of: "archive.tar.gz") == "gz")
        #expect(NodeFilter.fileExtension(of: ".DS_Store") == nil)
        #expect(NodeFilter.fileExtension(of: "README") == nil)
        #expect(NodeFilter.fileExtension(of: "trailing.") == nil)
        #expect(NodeFilter.normalizedExtension(".MP4") == "mp4")
    }
}

@Suite("Graph queries")
struct QueryTests {
    static let kib = 1 << 10

    /// big.mov 400K · clip.mp4 200K · notes.txt 40K · cache/blob.tmp 100K · cache/.DS_Store 8K
    static func mixedFixture() throws -> FixtureTree {
        let fixture = try FixtureTree()
        try fixture.directory("media")
        try fixture.directory("cache")
        try fixture.file("media/big.mov", size: 400 * kib)
        try fixture.file("media/clip.mp4", size: 200 * kib)
        try fixture.file("notes.txt", size: 40 * kib)
        try fixture.file("cache/blob.tmp", size: 100 * kib)
        try fixture.file("cache/.DS_Store", size: 8 * kib)
        return fixture
    }

    func names(_ nodes: [NodeID], in graph: FileGraph) -> [String] {
        nodes.map { graph.name(of: $0) }
    }

    @Test("An empty filter returns every file, largest first, never the root")
    func unfiltered() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let result = graph.query(kind: .file)
        #expect(names(result.nodes, in: graph) == ["big.mov", "clip.mp4", "blob.tmp", "notes.txt", ".DS_Store"])
        #expect(result.matchedCount == 5)
        #expect(result.candidateCount == 5)

        let dirs = graph.query(kind: .directory)
        #expect(!dirs.nodes.contains(graph.root))
        #expect(Set(names(dirs.nodes, in: graph)) == ["media", "cache"])
    }

    @Test("Extension include/exclude, case-insensitive")
    func extensionFilters() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)

        var filter = NodeFilter()
        filter.includeExtensions = ["mov", "mp4"]
        #expect(names(graph.query(kind: .file, filter: filter).nodes, in: graph) == ["big.mov", "clip.mp4"])

        filter = NodeFilter()
        filter.excludeExtensions = ["tmp", "txt"]
        #expect(names(graph.query(kind: .file, filter: filter).nodes, in: graph) == ["big.mov", "clip.mp4", ".DS_Store"])
    }

    @Test("Name globs vs path globs")
    func globFilters() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)

        var filter = NodeFilter()
        filter.excludeGlobs = [".DS_Store", "*.TMP"]
        #expect(names(graph.query(kind: .file, filter: filter).nodes, in: graph) == ["big.mov", "clip.mp4", "notes.txt"])

        filter = NodeFilter()
        filter.includeGlobs = ["*/cache/*"]
        #expect(Set(names(graph.query(kind: .file, filter: filter).nodes, in: graph)) == ["blob.tmp", ".DS_Store"])

        // A name-only glob must not match against parent folders.
        filter = NodeFilter()
        filter.includeGlobs = ["cache"]
        #expect(graph.query(kind: .file, filter: filter).nodes.isEmpty)
    }

    @Test("Size bounds and percent of total use the chosen lens")
    func sizeFilters() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)

        var filter = NodeFilter()
        filter.lens = .logical
        filter.minSize = Int64(100 * Self.kib)
        filter.maxSize = Int64(300 * Self.kib)
        #expect(names(graph.query(kind: .file, filter: filter).nodes, in: graph) == ["clip.mp4", "blob.tmp"])

        // big.mov is 400 of 748 KiB logical (~53%); nothing else clears 30%.
        filter = NodeFilter()
        filter.lens = .logical
        filter.minPercent = 30
        let result = graph.query(kind: .file, filter: filter)
        #expect(names(result.nodes, in: graph) == ["big.mov"])
        #expect(result.matchedTotals.logical == Int64(400 * Self.kib))
    }

    @Test("Multi-key sort, reverse, text keys, and limit")
    func sorting() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)

        let byName = graph.query(kind: .file, sort: NodeSort(keys: [.name]))
        #expect(names(byName.nodes, in: graph) == [".DS_Store", "big.mov", "blob.tmp", "clip.mp4", "notes.txt"])

        let smallestFirst = graph.query(kind: .file, sort: NodeSort(keys: [.logical], reverse: true), limit: 2)
        #expect(names(smallestFirst.nodes, in: graph) == [".DS_Store", "notes.txt"])
        #expect(smallestFirst.matchedCount == 5, "limit truncates output, not the match count")

        let byPath = graph.query(kind: .file, sort: NodeSort(keys: [.path]))
        let paths = byPath.nodes.map { graph.path(of: $0) }
        #expect(paths == paths.sorted())
    }

    @Test("Equal primary keys fall through to the secondary key")
    func tiebreak() async throws {
        let fixture = try FixtureTree()
        try fixture.file("b.bin", size: 64 * Self.kib)
        try fixture.file("a.bin", size: 64 * Self.kib)
        try fixture.file("c.bin", size: 128 * Self.kib)
        let graph = try await scanGraph(fixture.rootPath)

        let result = graph.query(kind: .file, sort: NodeSort(keys: [.logical, .name]))
        #expect(names(result.nodes, in: graph) == ["c.bin", "a.bin", "b.bin"])
    }

    @Test("Items under a deleted folder are never returned")
    func skipsTombstonedSubtrees() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        let media = try #require(graph.node(at: "media"))
        let edited = graph.removing(media)

        let result = edited.query(kind: .file)
        #expect(Set(names(result.nodes, in: edited)) == ["blob.tmp", "notes.txt", ".DS_Store"])
    }

    @Test("File-only criteria never match folders")
    func fileOnlyCriteria() async throws {
        let fixture = try Self.mixedFixture()
        let graph = try await scanGraph(fixture.rootPath)
        var filter = NodeFilter()
        filter.includeExtensions = ["mov"]
        #expect(filter.hasFileOnlyCriteria)
        #expect(graph.query(kind: .directory, filter: filter).nodes.isEmpty)
    }
}

@Suite("Attribute queries", .enabled(if: FixtureTree.volumeSupportsCloning(at: FileManager.default.temporaryDirectory.path)))
struct AttributeQueryTests {
    @Test("--only clone / hardlink select exactly those files")
    func attributes() async throws {
        let fixture = try FixtureTree()
        let original = try fixture.file("original.bin", size: 1 << 20)
        try fixture.clone(of: original, at: "copy.bin")
        let linked = try fixture.file("linked.bin", size: 1 << 20)
        try fixture.hardlink(of: linked, at: "link2.bin")
        try fixture.file("plain.bin", size: 1 << 20)
        let graph = try await scanGraph(fixture.rootPath)

        func matching(_ attribute: NodeFilter.Attribute) -> Set<String> {
            var filter = NodeFilter()
            filter.requiredAttributes = [attribute]
            return Set(graph.query(kind: .file, filter: filter).nodes.map { graph.name(of: $0) })
        }

        #expect(matching(.clone) == ["original.bin", "copy.bin"])
        #expect(matching(.hardlink) == ["linked.bin", "link2.bin"])
    }
}
