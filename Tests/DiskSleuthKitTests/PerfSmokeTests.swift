import DiskSleuthKit
import FixtureSupport
import Foundation
import Testing

extension Tag {
    @Tag static var performance: Tag
}

@Suite("Performance smoke", .tags(.performance))
struct PerfSmokeTests {
    @Test("20k files scan quickly and byte-exactly", .timeLimit(.minutes(2)))
    func mediumTreeScan() async throws {
        let fixture = try FixtureTree(name: "disksleuth-perf")
        var expectedLogical: Int64 = 0
        for d in 0..<100 {
            try fixture.directory("dir\(d)")
            for f in 0..<200 {
                let size = 1024 + (d * 200 + f) % 4096
                try fixture.file("dir\(d)/file\(f).bin", size: size)
                expectedLogical += Int64(size)
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        let graph = try await scanGraph(fixture.rootPath)
        let elapsed = start.duration(to: clock.now)

        #expect(graph.summary.fileCount == 20_000)
        #expect(graph.summary.directoryCount == 100)
        #expect(graph.summary.totalLogical == expectedLogical, "byte-exact logical total")
        #expect(elapsed < .seconds(30), "20k files should scan in well under 30s (took \(elapsed))")
    }
}
