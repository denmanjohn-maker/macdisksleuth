/// Identifier of a node in a FileGraph. Raw index into the graph's arrays.
public struct NodeID: Hashable, Sendable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
}

/// The three honest size lenses.
public enum SizeLens: String, Sendable, CaseIterable, Codable {
    case logical
    case physical
    case unique

    public var displayName: String {
        switch self {
        case .logical: "Logical"
        case .physical: "Physical"
        case .unique: "Freeable"
        }
    }
}

public struct Sizes: Sendable, Equatable {
    public var logical: Int64
    public var physical: Int64
    public var unique: Int64

    public subscript(lens: SizeLens) -> Int64 {
        switch lens {
        case .logical: logical
        case .physical: physical
        case .unique: unique
        }
    }
}

/// Directories the scan could not read — recorded, never silently skipped.
public struct PermissionLedger: Sendable, Codable {
    public struct DeniedEntry: Sendable, Codable {
        public var path: String
        public var code: Int32
    }

    /// First N denials with full paths (capped to bound memory).
    public var denied: [DeniedEntry] = []
    public var deniedCount: Int = 0
    static let maxRecorded = 2000

    mutating func record(path: String, code: Int32) {
        deniedCount += 1
        if denied.count < Self.maxRecorded {
            denied.append(DeniedEntry(path: path, code: code))
        }
    }

    /// Heuristic: denials under ~/Library or /Library strongly suggest the
    /// scanning process lacks Full Disk Access.
    public var likelyNeedsFullDiskAccess: Bool {
        denied.contains { $0.path.contains("/Library/") }
    }
}

/// Immutable scan result: the whole tree in struct-of-arrays form.
/// ~46 bytes per node plus name bytes — millions of files fit comfortably.
public struct FileGraph: Sendable {
    // Hot parallel arrays, indexed by NodeID.raw.
    var nameArena: [UInt8]
    var nameOffsets: [UInt32]
    var nameLengths: [UInt16]
    var parents: [Int32]  // -1 for root
    var depths: [UInt16]
    var logicalArr: [Int64]
    var physicalArr: [Int64]
    var uniqueArr: [Int64]
    var flagsArr: [UInt16]
    // CSR children layout: children(of: i) = childItems[childStart[i]..<childStart[i+1]]
    var childStart: [Int32]
    var childItems: [Int32]

    public var rootPath: String
    public var ledger: PermissionLedger
    public var summary: ScanSummary

    public var root: NodeID { NodeID(raw: 0) }
    public var nodeCount: Int { parents.count }

    public func name(of node: NodeID) -> String {
        let i = Int(node.raw)
        let start = Int(nameOffsets[i])
        let length = Int(nameLengths[i])
        return String(decoding: nameArena[start..<(start + length)], as: UTF8.self)
    }

    public func parent(of node: NodeID) -> NodeID? {
        let p = parents[Int(node.raw)]
        return p >= 0 ? NodeID(raw: p) : nil
    }

    public func depth(of node: NodeID) -> Int { Int(depths[Int(node.raw)]) }

    public func flags(of node: NodeID) -> NodeFlags {
        NodeFlags(rawValue: flagsArr[Int(node.raw)])
    }

    public func kind(of node: NodeID) -> NodeKind { flags(of: node).kind }

    public func sizes(of node: NodeID) -> Sizes {
        let i = Int(node.raw)
        return Sizes(logical: logicalArr[i], physical: physicalArr[i], unique: uniqueArr[i])
    }

    public func size(of node: NodeID, lens: SizeLens) -> Int64 {
        let i = Int(node.raw)
        switch lens {
        case .logical: return logicalArr[i]
        case .physical: return physicalArr[i]
        case .unique: return uniqueArr[i]
        }
    }

    /// Children, sorted by physical size descending. Tombstoned entries
    /// (deleted via `removing(_:)`) are skipped.
    public func children(of node: NodeID) -> [NodeID] {
        let i = Int(node.raw)
        let range = Int(childStart[i])..<Int(childStart[i + 1])
        return childItems[range].compactMap { $0 >= 0 ? NodeID(raw: $0) : nil }
    }

    public func childCount(of node: NodeID) -> Int {
        children(of: node).count
    }

    /// Absolute path of a node (root carries the full scan-root path).
    public func path(of node: NodeID) -> String {
        var components: [String] = []
        var current = node
        while let parent = parent(of: current) {
            components.append(name(of: current))
            current = parent
        }
        var path = rootPath
        if path.hasSuffix("/") { path.removeLast() }
        for component in components.reversed() {
            path += "/" + component
        }
        return path.isEmpty ? "/" : path
    }
}

/// Headline numbers for a completed scan.
public struct ScanSummary: Sendable, Codable {
    public var fileCount: Int = 0
    public var directoryCount: Int = 0
    public var symlinkCount: Int = 0
    public var totalLogical: Int64 = 0
    public var totalPhysical: Int64 = 0
    public var totalUnique: Int64 = 0
    public var cloneFileCount: Int = 0
    public var hardlinkedFileCount: Int = 0
    public var sparseFileCount: Int = 0
    public var datalessFileCount: Int = 0
    public var deniedDirectoryCount: Int = 0
    public var partial: Bool = false
    public var usedFallback: Bool = false
    public var wallSeconds: Double = 0
}
