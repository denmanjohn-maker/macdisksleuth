import ArgumentParser
import Foundation
import DiskSleuthKit

@main
struct Disksleuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disksleuth",
        abstract: "The disk analyzer that tells you the truth on APFS.",
        version: DiskSleuthVersion.string,
        subcommands: [Scan.self, Top.self, Info.self, Overview.self, Snapshots.self, Schedule.self, Export.self, Diff.self, WhatIf.self, Cleanup.self]
    )
}

// MARK: - Schedule Subcommand

/// Records a recurring-scan schedule in `~/.disksleuth/schedules.json`.
/// Nothing runs the schedule yet; this only stores it.
struct Schedule: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Record a recurring scan schedule (stored only; nothing runs it yet)."
    )

    @Argument(help: "Path to scan.")
    var path: String = "/"

    @Option(name: .customLong("interval"), help: "Scan interval in seconds (default: 86400 = daily).")
    var interval: Int = 86400

    @Option(name: .customLong("name"), help: "Schedule name.")
    var name: String?

    func run() throws {
        guard interval > 0 else { throw ValidationError("--interval must be positive.") }
        let now = Date().timeIntervalSince1970
        let schedule = ScanSchedule(
            id: UUID().uuidString,
            name: name ?? "Daily Scan",
            path: (path as NSString).expandingTildeInPath,
            interval: TimeInterval(interval),
            createdAt: now,
            nextRun: now + TimeInterval(interval),
            lastRun: nil
        )
        let created = try ScanStore().createSchedule(schedule)
        print("Schedule recorded: \(created.name) (ID: \(created.id))")
        print("  Path: \(created.path)")
        print("  Interval: \(Int(created.interval)) seconds")
        print("  Note: nothing runs schedules yet; this is stored only.")
    }
}

// MARK: - Export Subcommand

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Scan a folder and export the summary as JSON."
    )

    @Argument(help: "Path to scan.")
    var path: String = "."

    @Option(name: .customLong("format"), help: "Export format (only json is implemented).")
    var format: String = "json"

    @Option(name: .customLong("output"), help: "Output file path (default: stdout).")
    var output: String?

    func run() async throws {
        guard format.lowercased() == "json" else {
            throw NotImplementedError(feature: "export --format \(format)")
        }
        let target = (path as NSString).expandingTildeInPath
        let result = try await ScanRunner.run(path: target)

        struct Payload: Codable {
            var schemaVersion = 1
            var root: String
            var filesystem: String
            var summary: ScanSummary
        }
        let payload = Payload(
            root: result.graph.rootPath,
            filesystem: result.volume.fsTypeName,
            summary: result.graph.summary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        if let output {
            try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath), options: [.atomic])
            print("Exported to \(output)")
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

// MARK: - Not-yet-implemented subcommands

/// Raised by commands that are declared but not built yet, so they fail
/// loudly instead of reporting results they never computed.
struct NotImplementedError: LocalizedError {
    var feature: String
    var errorDescription: String? { "`\(feature)` is not implemented yet." }
}

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff", abstract: "Compare scan results (not implemented yet).", shouldDisplay: false)
    func run() throws { throw NotImplementedError(feature: "diff") }
}

struct WhatIf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "what-if", abstract: "Analyze what-if scenarios (not implemented yet).", shouldDisplay: false)
    func run() throws { throw NotImplementedError(feature: "what-if") }
}

struct Cleanup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup", abstract: "Clean up snapshots and purgeable space (not implemented yet).", shouldDisplay: false)
    func run() throws { throw NotImplementedError(feature: "cleanup") }
}
