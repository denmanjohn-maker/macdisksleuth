import Foundation

/// Persistent storage for scan history and scheduled scans.
/// Uses a simple JSON-based file store in `~/.macdisksleuth`.
public final class ScanStore {
    private let dataDir: URL

    /// - Parameter directory: Override the storage directory (tests); defaults to `~/.macdisksleuth`.
    ///   Like git and most CLIs, `~` honors a `HOME` override so scripts can isolate state.
    public init(directory: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        if let directory {
            self.dataDir = directory
        } else {
            let homeURL = URL(fileURLWithPath: home)
            self.dataDir = homeURL.appendingPathComponent(".macdisksleuth")
            ScanStore.migrateLegacyDirectory(from: homeURL.appendingPathComponent(".disksleuth"), to: dataDir)
        }
    }

    /// One-time migration from the pre-rename `~/.disksleuth` directory. Moves the
    /// old directory into place if the new path does not exist yet. Only a real
    /// directory is moved, and failures are ignored, so a stray file can never
    /// prevent the tool from running.
    private static func migrateLegacyDirectory(from old: URL, to new: URL) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard !fm.fileExists(atPath: new.path),
              fm.fileExists(atPath: old.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }
        try? fm.moveItem(at: old, to: new)
    }

    private var scansFile: URL { dataDir.appendingPathComponent("scans.json") }
    private var schedulesFile: URL { dataDir.appendingPathComponent("schedules.json") }

    // MARK: - Scan History

    /// Record a completed scan's headline numbers for later `diff` comparisons.
    /// The full graph is not persisted — it can be millions of nodes.
    @discardableResult
    public func storeScanResult(_ result: ScanResult, options: ScanOptions) throws -> ScanRecord {
        let record = ScanRecord(
            id: UUID().uuidString,
            path: result.graph.rootPath,
            timestamp: Date().timeIntervalSince1970,
            options: options,
            summary: result.graph.summary
        )

        var records = try loadScanRecords()
        records.append(record)
        records.sort { $0.timestamp > $1.timestamp }

        try saveScanRecords(records)
        return record
    }

    /// All stored scan records, newest first.
    public func loadScanRecords() throws -> [ScanRecord] {
        try load([ScanRecord].self, from: scansFile)
    }

    /// A specific scan record by ID.
    public func loadScanRecord(id: String) throws -> ScanRecord? {
        try loadScanRecords().first(where: { $0.id == id })
    }

    /// The most recent scan record, optionally restricted to one scan root.
    public func loadLatestScan(path: String? = nil) throws -> ScanRecord? {
        let records = try loadScanRecords()
        guard let path else { return records.first }
        return records.first(where: { $0.path == path })
    }

    /// The last N scan records.
    public func loadRecentScans(count: Int = 10) throws -> [ScanRecord] {
        Array(try loadScanRecords().prefix(count))
    }

    // MARK: - Schedules

    /// Create a new scan schedule.
    @discardableResult
    public func createSchedule(_ schedule: ScanSchedule) throws -> ScanSchedule {
        var schedules = try loadSchedules()
        schedules.append(schedule)
        try saveSchedules(schedules)
        return schedule
    }

    /// All scheduled scans.
    public func loadSchedules() throws -> [ScanSchedule] {
        try load([ScanSchedule].self, from: schedulesFile)
    }

    /// Replace a schedule (matched by ID) — used to advance its next run time.
    public func updateSchedule(_ schedule: ScanSchedule) throws {
        var schedules = try loadSchedules()
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
            try saveSchedules(schedules)
        }
    }

    /// Remove a schedule by ID.
    public func removeSchedule(id: String) throws {
        var schedules = try loadSchedules()
        schedules.removeAll { $0.id == id }
        try saveSchedules(schedules)
    }

    // MARK: - Persistence

    private func load<T: Decodable>(_ type: T.Type, from file: URL) throws -> T where T: ExpressibleByArrayLiteral {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    private func saveScanRecords(_ records: [ScanRecord]) throws {
        try save(records, to: scansFile)
    }

    private func saveSchedules(_ schedules: [ScanSchedule]) throws {
        try save(schedules, to: schedulesFile)
    }

    private func save<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: [.atomic])
    }
}

// MARK: - ScanRecord

/// Headline numbers from one past scan, enough to diff against a fresh one.
public struct ScanRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let timestamp: TimeInterval
    public let options: ScanOptions
    public let summary: ScanSummary

    public init(id: String, path: String, timestamp: TimeInterval, options: ScanOptions, summary: ScanSummary) {
        self.id = id
        self.path = path
        self.timestamp = timestamp
        self.options = options
        self.summary = summary
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
}

// MARK: - ScanSchedule

public struct ScanSchedule: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var path: String
    /// Seconds between runs.
    public var interval: TimeInterval
    public let createdAt: TimeInterval
    public var nextRun: TimeInterval?
    public var lastRun: TimeInterval?

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        interval: TimeInterval,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        nextRun: TimeInterval? = nil,
        lastRun: TimeInterval? = nil
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
