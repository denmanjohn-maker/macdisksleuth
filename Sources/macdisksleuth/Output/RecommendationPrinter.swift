import Foundation
import MacDiskSleuthKit

/// Volume-level facts the recommender wants alongside a scan graph.
struct VolumeFacts: Sendable {
    var mountPoint = "/"
    var snapshots: [SnapshotInfo] = []
    var purgeable: Int64?

    /// Best effort and quick: snapshots via diskutil/tmutil, purgeable via URL resource values.
    static func gather(forPath path: String) async -> VolumeFacts {
        var facts = VolumeFacts()
        let mount = (try? VolumeService.identity(ofPath: path))?.mountPoint ?? "/"
        facts.mountPoint = mount
        facts.snapshots = (try? await VolumeService.snapshots(ofVolume: mount)) ?? []
        if let capacities = try? VolumeService.capacities(ofVolume: mount), capacities.purgeable > 0 {
            facts.purgeable = capacities.purgeable
        }
        return facts
    }
}

/// Renders a RecommendationReport for the terminal.
struct RecommendationPrinter {
    var report: RecommendationReport
    var context: RecommendationContext
    var style: Style
    var binaryUnits: Bool
    /// Member paths listed per recommendation.
    var itemsShown = 3

    private static let indent = String(repeating: " ", count: 15)
    private static let width = 76

    private func fmt(_ bytes: Int64) -> String { ByteCount.format(bytes, binary: binaryUnits) }

    func printReport() {
        let recommendations = report.recommendations
        if recommendations.isEmpty {
            print(style.bold("Ways to free space"))
        } else {
            let count = recommendations.count
            print(
                style.bold("Top \(count) way\(count == 1 ? "" : "s") to free space")
                    + style.dim("  ·  up to ") + style.bold(style.green(fmt(report.totalFreeable))))
        }
        for (index, recommendation) in recommendations.enumerated() {
            printOne(recommendation, rank: index + 1)
        }
        if let advice = report.volumeAdvice {
            let indent = Self.indent
            print()
            print(" " + style.dim("◷ ") + " " + style.dim("size unknown") + " " + style.bold(advice.title)
                + "   \(safetyLabel(advice.safety))")
            print(wrap(advice.reason, firstIndent: indent, indent: indent))
            for caveat in advice.caveats {
                print(wrap(caveat, firstIndent: indent + style.yellow("⚠ "), indent: indent + "  "))
            }
            print(wrap(advice.action, firstIndent: indent + style.dim("→ "), indent: indent + "  "))
        }
        if !report.notes.isEmpty {
            print()
            for note in report.notes { print(style.dim(wrap(note, firstIndent: "  ", indent: "  "))) }
        }
    }

    private func safetyLabel(_ safety: CleanupSafety) -> String {
        switch safety {
        case .safe: style.green("✓ safe")
        case .likelySafe: style.yellow("~ likely safe")
        case .review: style.cyan("? review first")
        }
    }

    private func printOne(_ recommendation: Recommendation, rank: Int) {
        let indent = Self.indent
        print()
        let size = fmt(recommendation.freeable).padding(toLength: 10, withPad: " ", startingAt: 0)
        let rankText = String(rank).padding(toLength: 2, withPad: " ", startingAt: 0)
        print(
            " \(style.bold(rankText)) \(style.bold(style.green(size))) \(style.bold(recommendation.title))"
                + "   \(safetyLabel(recommendation.safety))")

        let items = recommendation.items
        if items.count == 1, recommendation.node != nil, let only = items.first {
            var line = indent + style.cyan(context.displayPath(only.path))
            if let note = only.note, note != recommendation.title { line += style.dim("  — \(note)") }
            print(line + ageSuffix(only.newestModified, recommendation))
        } else if !items.isEmpty {
            for item in items.prefix(itemsShown) {
                var line = indent + style.cyan(context.displayPath(item.path)) + style.dim("  \(fmt(item.sizes.unique))")
                if let note = item.note { line += style.dim("  — \(note)") }
                if recommendation.category.ageMatters, let date = item.newestModified,
                    item.note?.contains("untouched") != true, item.note?.contains("changed") != true
                {
                    line += style.dim("  · \(AgeText.staleness(since: date, now: context.now))")
                }
                print(line)
            }
            let rest = recommendation.itemCount - min(items.count, itemsShown)
            if rest > 0 { print(indent + style.dim("… \(rest) more")) }
        }

        print(wrap(recommendation.reason, firstIndent: indent, indent: indent))
        for caveat in recommendation.caveats {
            print(wrap(caveat, firstIndent: indent + style.yellow("⚠ "), indent: indent + "  "))
        }
        print(wrap(recommendation.action, firstIndent: indent + style.dim("→ "), indent: indent + "  "))
    }

    private func ageSuffix(_ date: Date?, _ recommendation: Recommendation) -> String {
        guard recommendation.category.ageMatters, let date else { return "" }
        return style.dim("  · \(AgeText.staleness(since: date, now: context.now))")
    }

    /// Word-wrap at a fixed column; ANSI codes in the indents don't count.
    private func wrap(_ text: String, firstIndent: String, indent: String) -> String {
        let limit = Self.width - Self.indent.count
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > limit {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.enumerated().map { ($0.offset == 0 ? firstIndent : indent) + $0.element }
            .joined(separator: "\n")
    }

    // MARK: - Notification

    /// "Up to 41.2 GB can be freed" with the top three finds.
    static func notify(report: RecommendationReport, scannedPath: String) async {
        let top = report.recommendations.prefix(3)
        let shown = top.reduce(Int64(0)) { $0 + $1.freeable }
        let title = top.isEmpty
            ? "Scan complete — nothing obvious to delete"
            : "Up to \(ByteCount.format(shown)) can be freed"
        let body = top.isEmpty
            ? scannedPath
            : top.enumerated().map { "\($0.offset + 1). \($0.element.title) — \(ByteCount.format($0.element.freeable))" }
                .joined(separator: "\n")
        await UserNotifier.post(title: title, body: body, subtitle: top.isEmpty ? nil : scannedPath)
    }
}

// MARK: - JSON

struct RecommendationJSON: Codable {
    struct Item: Codable {
        var path: String
        var logical: Int64
        var physical: Int64
        var freeable: Int64
        var lastModified: Date?
        var note: String?
    }

    var rank: Int
    var category: String
    var title: String
    var safety: String
    var confidence: Double
    var logical: Int64
    var physical: Int64
    var freeable: Int64
    var lastModified: Date?
    var reason: String
    var action: String
    var caveats: [String]
    var itemCount: Int
    var items: [Item]
}

struct RecommendationReportJSON: Codable {
    var totalFreeable: Int64
    var considered: Int
    var notes: [String]
    var recommendations: [RecommendationJSON]
    /// Snapshot advice for the volume; its savings are unknown and not in totalFreeable.
    var volumeAdvice: RecommendationJSON?

    init(report: RecommendationReport) {
        totalFreeable = report.totalFreeable
        considered = report.consideredCount
        notes = report.notes
        volumeAdvice = report.volumeAdvice.map { Self.encode($0, rank: 0) }
        recommendations = report.recommendations.enumerated().map { index, recommendation in
            Self.encode(recommendation, rank: index + 1)
        }
    }

    private static func encode(_ recommendation: Recommendation, rank: Int) -> RecommendationJSON {
            RecommendationJSON(
                rank: rank,
                category: recommendation.category.rawValue,
                title: recommendation.title,
                safety: recommendation.safety.rawValue,
                confidence: (recommendation.confidence * 100).rounded() / 100,
                logical: recommendation.sizes.logical,
                physical: recommendation.sizes.physical,
                freeable: recommendation.freeable,
                lastModified: recommendation.newestModified,
                reason: recommendation.reason,
                action: recommendation.action,
                caveats: recommendation.caveats,
                itemCount: recommendation.itemCount,
                items: recommendation.items.map {
                    RecommendationJSON.Item(
                        path: $0.path, logical: $0.sizes.logical, physical: $0.sizes.physical,
                        freeable: $0.sizes.unique, lastModified: $0.newestModified, note: $0.note)
                })
    }
}
