import ArgumentParser
import MacDiskSleuthKit
import Foundation

struct Schedule: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a recurring scan so `diff` has a steady baseline.",
        discussion: """
            Schedules are stored in ~/.macdisksleuth/schedules.json. MacDiskSleuth does not
            run a background agent; pair a schedule with launchd or cron that invokes
            `macdisksleuth diff <path>` to keep the history current.
            """
    )

    @Argument(help: "Directory to scan (default: /).")
    var path: String = "/"

    @Option(name: .customLong("interval"), help: "Seconds between runs (default: 86400 = daily).")
    var interval: Int = 86_400

    @Option(name: .customLong("name"), help: "Human-readable schedule name.")
    var name: String?

    @Flag(name: .customLong("now"), help: "Also run a scan immediately and store it as a baseline.")
    var now = false

    @Flag(name: .customLong("list"), help: "List existing schedules and exit.")
    var list = false

    @Option(name: .customLong("remove"), help: "Remove the schedule with this ID and exit.")
    var remove: String?

    func validate() throws {
        guard interval > 0 else { throw ValidationError("--interval must be positive.") }
    }

    func run() async throws {
        let store = ScanStore()

        if let remove {
            try store.removeSchedule(id: remove)
            print("Removed schedule \(remove).")
            return
        }

        if list {
            let schedules = try store.loadSchedules()
            if schedules.isEmpty {
                print("No schedules. Create one with: macdisksleuth schedule ~ --interval 86400")
                return
            }
            for schedule in schedules {
                let next = schedule.nextRun.map { Date(timeIntervalSince1970: $0).formatted(.dateTime) } ?? "—"
                print("\(schedule.id)  \(schedule.name)  \(schedule.path)  every \(Int(schedule.interval))s  next: \(next)")
            }
            return
        }

        let target = (path as NSString).expandingTildeInPath
        let seconds = TimeInterval(interval)
        var schedule = ScanSchedule(
            name: name ?? "Scan of \(target)",
            path: target,
            interval: seconds,
            nextRun: Date().timeIntervalSince1970 + seconds
        )

        if now {
            let result = try await ScanRunner.run(path: target)
            try store.storeScanResult(result, options: ScanOptions())
            schedule.lastRun = Date().timeIntervalSince1970
            print("Baseline stored: \(result.graph.summary.fileCount.formatted()) files, "
                + "\(ByteCount.format(result.graph.summary.totalPhysical)) physical.")
        }

        try store.createSchedule(schedule)
        print("Schedule created: \(schedule.name) (ID: \(schedule.id))")
        print("  Path:     \(schedule.path)")
        print("  Interval: \(Int(schedule.interval)) seconds")
        print("  Next run: \(Date(timeIntervalSince1970: schedule.nextRun ?? 0).formatted(.dateTime))")
    }
}
