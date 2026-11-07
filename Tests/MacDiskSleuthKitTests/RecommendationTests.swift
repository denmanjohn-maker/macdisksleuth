import MacDiskSleuthKit
import FixtureSupport
import Foundation
import Testing

@Suite("Cleanup recommendations")
struct RecommendationTests {
    static let kib = 1 << 10

    /// A miniature home folder with one of everything the recommender knows about.
    ///
    /// home/
    ///   Library/Caches/Homebrew/bottle.bin   300K   safe cache, 200 days stale (hint: brew cleanup)
    ///   Library/Caches/pip/wheel.bin         100K   safe cache (hint: pip cache purge)
    ///   Library/Mail/V10/huge.bin            900K   NEVER recommended
    ///   Pictures/Photos Library.photoslibrary/huge.bin 900K  NEVER recommended
    ///   proj/package.json + proj/node_modules/dep.bin 200K   build artifact
    ///   notproj/node_modules/dep.bin          40K   not a project (no package.json) and below the floor
    ///   .Trash/gone.bin                      150K   trash
    ///   Downloads/old.dmg (60 days old)      250K   stale download
    ///   Downloads/new.dmg (today)            250K   too recent to suggest
    ///   Downloads/Old.photoslibrary/pic.bin (60 days old) 300K  protected even inside Downloads
    ///   Movies/a/clip.mov + Movies/b/clip.mov 300K each, same size, different bytes → duplicates
    ///   Documents/image.iso (60 days old)    400K   generic installer
    static func homeFixture() throws -> (FixtureTree, home: String) {
        let fixture = try FixtureTree()
        try fixture.directory("home")
        try fixture.directory("home/Library/Caches/Homebrew")
        try fixture.file("home/Library/Caches/Homebrew/bottle.bin", size: 300 * kib)
        try fixture.setModificationDate("home/Library/Caches/Homebrew/bottle.bin", to: Date(timeIntervalSinceNow: -200 * 86_400))
        try fixture.setModificationDate("home/Library/Caches/Homebrew", to: Date(timeIntervalSinceNow: -200 * 86_400))
        try fixture.directory("home/Library/Caches/pip")
        try fixture.file("home/Library/Caches/pip/wheel.bin", size: 100 * kib)
        try fixture.directory("home/Library/Mail/V10")
        try fixture.file("home/Library/Mail/V10/huge.bin", size: 900 * kib)
        try fixture.directory("home/Pictures/Photos Library.photoslibrary")
        try fixture.file("home/Pictures/Photos Library.photoslibrary/huge.bin", size: 900 * kib)
        try fixture.directory("home/proj/node_modules")
        try fixture.file("home/proj/package.json", size: 64)
        try fixture.file("home/proj/node_modules/dep.bin", size: 200 * kib)
        try fixture.directory("home/notproj/node_modules")
        try fixture.file("home/notproj/node_modules/dep.bin", size: 40 * kib)
        try fixture.directory("home/.Trash")
        try fixture.file("home/.Trash/gone.bin", size: 150 * kib)
        try fixture.directory("home/Downloads")
        try fixture.file("home/Downloads/old.dmg", size: 250 * kib)
        try fixture.file("home/Downloads/new.dmg", size: 250 * kib)
        try fixture.setModificationDate("home/Downloads/old.dmg", to: Date(timeIntervalSinceNow: -60 * 86_400))
        try fixture.directory("home/Downloads/Old.photoslibrary")
        try fixture.file("home/Downloads/Old.photoslibrary/pic.bin", size: 300 * kib)
        try fixture.setModificationDate("home/Downloads/Old.photoslibrary/pic.bin", to: Date(timeIntervalSinceNow: -60 * 86_400))
        try fixture.setModificationDate("home/Downloads/Old.photoslibrary", to: Date(timeIntervalSinceNow: -60 * 86_400))
        try fixture.directory("home/Movies/a")
        try fixture.directory("home/Movies/b")
        try fixture.file("home/Movies/a/clip.mov", size: 300 * kib)
        try fixture.file("home/Movies/b/clip.mov", size: 300 * kib)
        try fixture.directory("home/Documents")
        try fixture.file("home/Documents/image.iso", size: 400 * kib)
        try fixture.setModificationDate("home/Documents/image.iso", to: Date(timeIntervalSinceNow: -60 * 86_400))
        return (fixture, fixture.path("home"))
    }

    static func context(home: String, limit: Int = 20) -> RecommendationContext {
        RecommendationContext(homeDirectory: home, limit: limit, minimumBytes: Int64(100 * kib))
    }

    func recommendation(_ category: CleanupCategory, in report: RecommendationReport) -> Recommendation? {
        report.recommendations.first { $0.category == category }
    }

    @Test("Every kind of disposable content is found, and protected content never is")
    func findsTheRightThings() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let categories = Set(report.recommendations.map(\.category))
        #expect(categories.isSuperset(of: [.trash, .applicationCaches, .buildArtifacts, .downloads, .duplicates, .installers]))

        // Nothing under Mail or a Photos library, ever — not even as a generic large file.
        let everyPath = report.recommendations.flatMap { $0.items.map(\.path) }
        #expect(!everyPath.contains { $0.contains("/Library/Mail/") || $0.contains(".photoslibrary") })

        // Totals are freeable bytes, and the headline is their sum.
        #expect(report.totalFreeable == report.recommendations.reduce(Int64(0)) { $0 + $1.freeable })
        #expect(report.recommendations.allSatisfy { $0.freeable >= Int64(100 * Self.kib) })
        _ = fixture
    }

    @Test("Caches are grouped per app with the right purge hints")
    func cachesGroupedWithHints() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let caches = try #require(recommendation(.applicationCaches, in: report))
        #expect(caches.safety == .safe)
        let names = caches.items.map { ($0.path as NSString).lastPathComponent }
        #expect(names == ["Homebrew", "pip"], "largest first")
        #expect(caches.items[0].note == "brew cleanup --prune=all")
        #expect(caches.items[1].note == "pip cache purge")
        #expect(within(caches.freeable, of: Int64(400 * Self.kib)))
        #expect(caches.node == nil, "a per-app breakdown is not one trashable node")
        #expect(!caches.canMoveToTrash)
        _ = fixture
    }

    @Test("node_modules only counts next to a package.json")
    func projectMarkers() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let artifacts = try #require(recommendation(.buildArtifacts, in: report))
        #expect(artifacts.items.count == 1)
        #expect(artifacts.items[0].path.hasSuffix("/proj/node_modules"))
        #expect(!report.recommendations.flatMap(\.items).contains { $0.path.contains("notproj") })
        _ = fixture
    }

    @Test("Downloads surface only once they've gone stale, with what they are")
    func staleDownloads() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let downloads = try #require(recommendation(.downloads, in: report))
        #expect(downloads.items.map { ($0.path as NSString).lastPathComponent } == ["old.dmg"], "new.dmg is too recent and the Photos library is protected")
        #expect(downloads.items[0].note?.contains("installer") == true)
        #expect(downloads.items[0].note?.contains("untouched for") == true)
        #expect(within(downloads.freeable, of: Int64(250 * Self.kib)))
        #expect(downloads.node != nil, "the Downloads folder itself can be revealed")
        #expect(!downloads.canMoveToTrash, "but never trashed wholesale")
        _ = fixture
    }

    @Test("Same name and size in different folders is a duplicate; the older copy is kept")
    func duplicates() async throws {
        let (fixture, home) = try Self.homeFixture()
        try fixture.setModificationDate("home/Movies/a/clip.mov", to: Date(timeIntervalSinceNow: -30 * 86_400))
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let duplicates = try #require(recommendation(.duplicates, in: report))
        #expect(duplicates.items.count == 1)
        #expect(duplicates.items[0].path.hasSuffix("/Movies/b/clip.mov"), "the newer copy is the one to delete")
        #expect(duplicates.items[0].note?.contains("~/Movies/a/clip.mov") == true)
        #expect(duplicates.safety == .review)
        _ = fixture
    }

    @Test("Generic large files are classified by what they are")
    func genericFiles() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let iso = try #require(report.recommendations.first { $0.title.hasSuffix("image.iso") })
        #expect(iso.category == .installers)
        #expect(iso.safety == .likelySafe, "60 days old")
        #expect(iso.canMoveToTrash)
        #expect(iso.node != nil)

        // One clip.mov is the kept original, the other is listed once — as a
        // duplicate, not again as a large video — so the total never counts it twice.
        let videos = report.recommendations.filter { $0.title.hasPrefix("Large video:") }
        #expect(videos.count == 1)
        #expect(videos.allSatisfy { $0.safety == .review })
        let duplicates = try #require(recommendation(.duplicates, in: report))
        let listedTwice = Set(videos.flatMap { $0.items.map(\.path) })
            .intersection(duplicates.items.map(\.path))
        #expect(listedTwice.isEmpty)
        _ = fixture
    }

    @Test("Limiting a report trims the list and its headline total together")
    func limitedReport() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let full = Recommender.recommend(graph: graph, context: Self.context(home: home))
        let two = full.limited(to: 2)
        #expect(two.recommendations.count == 2)
        #expect(two.recommendations.map(\.id) == Array(full.recommendations.prefix(2).map(\.id)))
        #expect(two.totalFreeable == two.recommendations.reduce(Int64(0)) { $0 + $1.freeable })
        #expect(full.limited(to: 100).recommendations.count == full.recommendations.count)
        _ = fixture
    }

    @Test("Ranking prefers safe, stale bytes over merely big ones; limit truncates")
    func ranking() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let full = Recommender.recommend(graph: graph, context: Self.context(home: home))

        // Scores never increase down the list, and every entry clears the floor.
        let freeable = full.recommendations.map(\.freeable)
        #expect(full.recommendations.first?.category == .applicationCaches, "400K of safe, stale caches outranks a 400K likely-safe iso")
        let isoIndex = try #require(full.recommendations.firstIndex(where: { $0.category == .installers }))
        let videoIndices = full.recommendations.indices.filter { full.recommendations[$0].category == .media }
        #expect(!videoIndices.isEmpty)
        #expect(videoIndices.allSatisfy { $0 > isoIndex }, "likely-safe installer outranks review-first videos of comparable size")
        #expect(freeable.allSatisfy { $0 >= Int64(100 * Self.kib) })

        let five = Recommender.recommend(graph: graph, context: Self.context(home: home, limit: 5))
        #expect(five.recommendations.count == 5)
        #expect(five.recommendations.map(\.id) == Array(full.recommendations.prefix(5).map(\.id)))
        #expect(five.totalFreeable == five.recommendations.reduce(Int64(0)) { $0 + $1.freeable })
        _ = fixture
    }

    @Test("Scanning a cache folder directly recommends its contents")
    func rootMatchesRule() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home + "/Library/Caches")
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let caches = try #require(recommendation(.applicationCaches, in: report))
        #expect(Set(caches.items.map { ($0.path as NSString).lastPathComponent }) == ["Homebrew", "pip"])
        _ = fixture
    }

    @Test("Scanning protected content — or anything inside it — yields no recommendations, and says why")
    func excludedRoot() async throws {
        let (fixture, home) = try Self.homeFixture()
        for root in [home + "/Library/Mail", home + "/Library/Mail/V10"] {
            let graph = try await scanGraph(root)
            let report = Recommender.recommend(graph: graph, context: Self.context(home: home))
            #expect(report.recommendations.isEmpty, "\(root)")
            #expect(report.volumeAdvice == nil)
            #expect(report.notes.contains { $0.contains("never suggests") }, "\(root)")
        }
        _ = fixture
    }

    @Test("Time Machine snapshots become volume advice with no invented size, targeting the scanned volume")
    func snapshots() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let timeMachine = SnapshotInfo(name: "com.apple.TimeMachine.2026-01-01-000000.local")
        let systemUpdate = SnapshotInfo(name: "com.apple.os.update-ABC123")

        var context = Self.context(home: home)
        context.snapshots = [systemUpdate]
        var report = Recommender.recommend(graph: graph, context: context)
        #expect(report.volumeAdvice == nil, "an OS update snapshot is not something tmutil can remove")
        #expect(!report.notes.contains { $0.contains("Time Machine") })

        context.snapshots = [timeMachine, systemUpdate]
        context.purgeableBytes = 5_000_000_000
        context.volumeMountPoint = "/Volumes/My Disk"
        report = Recommender.recommend(graph: graph, context: context)
        let advice = try #require(report.volumeAdvice)
        #expect(advice.category == .snapshots)
        #expect(advice.title.contains("(1)"), "only the Time Machine snapshot counts")
        #expect(advice.freeable == 0, "macOS reports no snapshot sizes, so none is claimed")
        #expect(advice.action.contains("'/Volumes/My Disk'"))
        #expect(advice.caveats.contains { $0.contains("5.00 GB") })
        #expect(!advice.canMoveToTrash)
        #expect(!advice.isFixable, "nothing to tick: snapshot advice has no files")
        #expect(recommendation(.snapshots, in: report) == nil, "never in the ranked list")
        #expect(report.totalFreeable == report.recommendations.reduce(Int64(0)) { $0 + $1.freeable })
        #expect(report.notes.contains { $0.contains("1 local Time Machine snapshot exists") })
        _ = fixture
    }

    @Test("Safe recommendations pre-check every member for Fix; others start unchecked")
    func fixPreselection() async throws {
        let (fixture, home) = try Self.homeFixture()
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(graph: graph, context: Self.context(home: home))

        let caches = try #require(recommendation(.applicationCaches, in: report))
        #expect(caches.isFixable, "a per-app breakdown is exactly what Fix is for")
        #expect(!caches.canMoveToTrash, "even though it has no single trashable node")
        #expect(caches.preselectedItemIDs == Set(caches.items.map(\.id)))

        let downloads = try #require(recommendation(.downloads, in: report))
        #expect(downloads.isFixable)
        #expect(downloads.preselectedItemIDs.isEmpty, "likely safe deserves a look first")

        let duplicates = try #require(recommendation(.duplicates, in: report))
        #expect(duplicates.isFixable)
        #expect(duplicates.preselectedItemIDs.isEmpty)
        #expect(duplicates.hiddenItemCount == 0)

        let notTrashable = CleanupCategory.allCases.filter { !$0.membersAreTrashable }
        #expect(Set(notTrashable) == [.systemManaged, .containers, .snapshots])
        _ = fixture
    }

    @Test("Paths display relative to home")
    func displayPaths() {
        let context = RecommendationContext(homeDirectory: "/Users/sleuth")
        #expect(context.displayPath("/Users/sleuth/Library/Caches") == "~/Library/Caches")
        #expect(context.displayPath("/Users/sleuth") == "~")
        #expect(context.displayPath("/Users/other/x") == "/Users/other/x")
    }

    @Test("Ages read naturally")
    func ageText() {
        let now = Date()
        func age(_ days: Double) -> String { AgeText.describe(since: now.addingTimeInterval(-days * 86_400), now: now) }
        #expect(age(0.2) == "today")
        #expect(age(1.5) == "yesterday")
        #expect(age(5) == "5 days")
        #expect(age(21) == "3 weeks")
        #expect(age(200) == "7 months")
        #expect(age(800) == "2 years")
        #expect(AgeText.staleness(since: now.addingTimeInterval(-200 * 86_400), now: now) == "untouched for 7 months")
    }
}

@Suite("Recommendations honour APFS sharing", .enabled(if: FixtureTree.volumeSupportsCloning(at: FileManager.default.temporaryDirectory.path)))
struct RecommendationSharingTests {
    @Test("Clones are skipped — and said to be skipped — instead of promised as savings")
    func clonesSkipped() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("home/Documents")
        let original = try fixture.file("home/Documents/original.bin", size: 2 << 20)
        try fixture.clone(of: original, at: "home/Documents/copy.bin")
        try fixture.file("home/Documents/plain.bin", size: 1 << 20)

        let home = fixture.path("home")
        let graph = try await scanGraph(home)
        let report = Recommender.recommend(
            graph: graph, context: RecommendationContext(homeDirectory: home, limit: 10, minimumBytes: 512 * 1024))

        let paths = report.recommendations.flatMap { $0.items.map(\.path) }
        #expect(paths.contains { $0.hasSuffix("/plain.bin") })
        #expect(!paths.contains { $0.hasSuffix("/original.bin") || $0.hasSuffix("/copy.bin") })
        #expect(report.notes.contains { $0.hasPrefix("Skipped 2 large files") })
        // Clone twins have the same name? No — different names, so they are not duplicates either.
        #expect(report.recommendations.first { $0.category == .duplicates } == nil)
    }
}
