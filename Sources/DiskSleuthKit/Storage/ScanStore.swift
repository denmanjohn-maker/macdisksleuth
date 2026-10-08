import Foundation

/// Persistent storage for scan history and scheduled scans.
/// Uses a simple JSON-based file store in the user's home directory.
public final class ScanStore {
    private let homeDir: URL

    public init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        self.homeDir = home
    }

    private var dataDir: URL {
        let dir = homeDir.appendingPathComponent(".disksleuth")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var scansFile: URL {
        dataDir.appendingPathComponent("scans.json")
    }

    private var schedulesFile: URL {
        dataDir.appendingPathComponent("schedules.json")
    }

    // MARK: - Scan History

    /// Store scan results for history and diff operations.
    func storeScanResult(_ result: ScanResult, options: ScanOptions) throws -> ScanRecord {
        let record = ScanRecord(
            id: UUID().uuidString,
            path: result.graph.rootPath,
            timestamp: Date().timeIntervalSince1970,
            options: options
        )

        var records = try loadScanRecords()
        records.append(record)
        records.sort { $0.timestamp > $1.timestamp }

        try saveScanRecords(records)
        return record
    }

    /// Load all stored scan records.
    func loadScanRecords() throws -> [ScanRecord] {
        guard FileManager.default.fileExists(atPath: scansFile.path) else {
            return []
        }
        let data = try Data(contentsOf: scansFile)
        return try JSONDecoder().decode([ScanRecord].self, from: data)
    }

    /// Load a specific scan record by ID.
    func loadScanRecord(id: String) throws -> ScanRecord? {
        let records = try loadScanRecords()
        return records.first(where: { $0.id == id })
    }

    /// Get the most recent scan record.
    func loadLatestScan() throws -> ScanRecord? {
        let records = try loadScanRecords()
        return records.first
    }

    /// Get the last N scan records.
    func loadRecentScans(count: Int = 10) throws -> [ScanRecord] {
        let records = try loadScanRecords()
        return Array(records.prefix(count))
    }

    // MARK: - Schedules

    /// Create a new scan schedule.
    public func createSchedule(_ schedule: ScanSchedule) throws -> ScanSchedule {
        var schedules = try loadSchedules()
        schedules.append(schedule)
        try saveSchedules(schedules)
        return schedule
    }

    /// Load all scheduled scans.
    func loadSchedules() throws -> [ScanSchedule] {
        guard FileManager.default.fileExists(atPath: schedulesFile.path) else {
            return []
        }
        let data = try Data(contentsOf: schedulesFile)
        return try JSONDecoder().decode([ScanSchedule].self, from: data)
    }

    /// Update a schedule's next run time.
    func updateScheduleNextRun(_ schedule: ScanSchedule) throws {
        var schedules = try loadSchedules()
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
            try saveSchedules(schedules)
        }
    }

    /// Remove a schedule by ID.
    func removeSchedule(id: String) throws {
        var schedules = try loadSchedules()
        schedules.removeAll { $0.id == id }
        try saveSchedules(schedules)
    }

    private func saveScanRecords(_ records: [ScanRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: scansFile, options: [.atomic])
    }

    private func saveSchedules(_ schedules: [ScanSchedule]) throws {
        let data = try JSONEncoder().encode(schedules)
        try data.write(to: schedulesFile, options: [.atomic])
    }
}

// MARK: - ScanRecord

struct ScanRecord: Codable, Sendable {
    let id: String
    let path: String
    let timestamp: TimeInterval
    let options: ScanOptions
}

// MARK: - ScanSchedule

public struct ScanSchedule: Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let interval: TimeInterval // in seconds
    public let createdAt: TimeInterval
    public let nextRun: TimeInterval?
    public let lastRun: TimeInterval?

    public init(
        id: String, name: String, path: String, interval: TimeInterval,
        createdAt: TimeInterval, nextRun: TimeInterval?, lastRun: TimeInterval?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.interval = interval
        self.createdAt = createdAt
        self.nextRun = nextRun
        self.lastRun = lastRun
    }
}
