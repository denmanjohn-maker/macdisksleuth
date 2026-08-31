import Darwin

/// Single-writer accumulator for the scan: workers stream batches of parsed
/// entries in; it appends to compact struct-of-arrays storage, feeds the
/// hardlink/clone registries, and at the end resolves shared-bytes accounting
/// and rolls sizes up the tree.
///
/// Accounting model ("shared bytes are counted once, in the deepest folder
/// that contains all files sharing them"):
/// - Per-file values are individual truth: physical = the file's own allocated
///   bytes; unique = what deleting that one path frees (0 for hardlinks with
///   other links; ~0 for undiverged clones via ATTR_CMNEXT_PRIVATESIZE).
/// - Directory rollups would multi-count shared extents, so corrections are
///   charged at the lowest common ancestor (LCA) of each sharing group:
///   duplicate hardlink bytes subtracted from physical; freed-if-all-deleted
///   bytes added to unique when the whole group lies inside the tree.
actor GraphBuilder {
    // Struct-of-arrays node storage.
    private var nameArena: [UInt8] = []
    private var nameOffsets: [UInt32] = []
    private var nameLengths: [UInt16] = []
    private var parents: [Int32] = []
    private var depths: [UInt16] = []
    private var logicalArr: [Int64] = []
    private var physicalArr: [Int64] = []
    private var uniqueArr: [Int64] = []
    private var flagsArr: [UInt16] = []

    // Sharing registries, consumed at finalize.
    private struct HardlinkKey: Hashable {
        var device: UInt64
        var fileID: UInt64
    }
    private struct HardlinkAcc {
        var nodes: [Int32] = []
        var totalLinks: UInt32 = 0
        var physical: Int64 = 0
        var privateSize: Int64 = -1
    }
    private var hardlinks: [HardlinkKey: HardlinkAcc] = [:]

    private struct CloneKey: Hashable {
        var device: UInt64
        var cloneID: UInt64
    }
    private struct CloneAcc {
        var nodes: [Int32] = []
        /// Distinct inodes seen — hard links of one file are a single clone-family
        /// member, not several (registering per-entry over-subtracts at the LCA).
        var inodes: Set<UInt64> = []
        var sharedSum: Int64 = 0
        var sharedMax: Int64 = 0
        var refcntMax: UInt32 = 0
    }
    private var clones: [CloneKey: CloneAcc] = [:]

    private var ledger = PermissionLedger()
    private var summary = ScanSummary()
    private var directoriesScanned = 0
    private var progressLogical: Int64 = 0
    private var progressPhysical: Int64 = 0
    private var lastPath = ""

    func addRoot(name: String) -> Int32 {
        appendNode(name: name, parent: -1, depth: 0, flags: NodeFlags(kind: .directory), logical: 0, physical: 0, unique: 0)
    }

    /// Append one batch of a directory's entries; returns the node IDs
    /// assigned to each entry, in order.
    func addChildren(parent: Int32, device: UInt64, entries: [RawEntry]) -> [Int32] {
        var ids: [Int32] = []
        ids.reserveCapacity(entries.count)
        let childDepth = depths[Int(parent)] + 1

        for entry in entries {
            let kind: NodeKind =
                entry.isDirectory
                ? .directory : entry.isSymlink ? .symlink : entry.isRegularFile ? .file : .other
            var flags = NodeFlags(kind: kind)

            var logical: Int64 = 0
            var physical: Int64 = 0
            var unique: Int64 = 0

            if kind != .directory {
                logical = max(entry.logical, 0)
                physical = max(entry.physical, 0)
                unique = entry.hasPrivateSize ? max(entry.privateSize, 0) : physical

                if entry.isDataless { flags.dataless = true; summary.datalessFileCount += 1 }
                if entry.isCompressed { flags.compressed = true }
                if entry.isSparse { flags.sparse = true; summary.sparseFileCount += 1 }
                if entry.isPurgeable { flags.purgeable = true }

                if entry.linkCount > 1 {
                    // Deleting one of several hard links frees nothing.
                    unique = 0
                    flags.hardlinked = true
                    summary.hardlinkedFileCount += 1
                }
                if entry.maySharesBlocks && kind == .file {
                    flags.cloned = true
                    summary.cloneFileCount += 1
                }
                summary.fileCount += kind == .symlink ? 0 : 1
                if kind == .symlink { summary.symlinkCount += 1 }
                progressLogical += logical
                progressPhysical += physical
            } else {
                summary.directoryCount += 1
            }

            let id = appendNode(
                name: entry.name, parent: parent, depth: childDepth, flags: flags,
                logical: logical, physical: physical, unique: unique)
            ids.append(id)

            if kind != .directory {
                if entry.linkCount > 1 {
                    let key = HardlinkKey(device: device, fileID: entry.fileID)
                    var acc = hardlinks[key] ?? HardlinkAcc()
                    acc.nodes.append(id)
                    acc.totalLinks = max(acc.totalLinks, entry.linkCount)
                    acc.physical = max(acc.physical, physical)
                    acc.privateSize = max(acc.privateSize, entry.privateSize)
                    hardlinks[key] = acc
                }
                if entry.maySharesBlocks && kind == .file && entry.cloneID != 0 {
                    let key = CloneKey(device: device, cloneID: entry.cloneID)
                    var acc = clones[key] ?? CloneAcc()
                    if acc.inodes.insert(entry.fileID).inserted {
                        acc.nodes.append(id)
                        let shared =
                            entry.hasPrivateSize ? max(physical - max(entry.privateSize, 0), 0) : 0
                        acc.sharedSum += shared
                        acc.sharedMax = max(acc.sharedMax, shared)
                        acc.refcntMax = max(acc.refcntMax, entry.cloneRefcnt)
                        clones[key] = acc
                    }
                }
            }
        }
        return ids
    }

    private func appendNode(
        name: String, parent: Int32, depth: UInt16, flags: NodeFlags,
        logical: Int64, physical: Int64, unique: Int64
    ) -> Int32 {
        let id = Int32(parents.count)
        let utf8 = Array(name.utf8)
        nameOffsets.append(UInt32(nameArena.count))
        nameLengths.append(UInt16(min(utf8.count, Int(UInt16.max))))
        nameArena.append(contentsOf: utf8)
        parents.append(parent)
        depths.append(depth)
        flagsArr.append(flags.rawValue)
        logicalArr.append(logical)
        physicalArr.append(physical)
        uniqueArr.append(unique)
        return id
    }

    func dirFinished(path: String) {
        directoriesScanned += 1
        lastPath = path
    }

    func markDenied(node: Int32, path: String, code: Int32) {
        ledger.record(path: path, code: code)
        var flags = NodeFlags(rawValue: flagsArr[Int(node)])
        flags.accessDenied = true
        flagsArr[Int(node)] = flags.rawValue
    }

    func markOtherVolume(node: Int32) {
        var flags = NodeFlags(rawValue: flagsArr[Int(node)])
        flags.otherVolume = true
        flagsArr[Int(node)] = flags.rawValue
    }

    func markDuplicate(node: Int32) {
        var flags = NodeFlags(rawValue: flagsArr[Int(node)])
        flags.duplicate = true
        flagsArr[Int(node)] = flags.rawValue
    }

    func markFirmlinkSkipped(node: Int32) {
        var flags = NodeFlags(rawValue: flagsArr[Int(node)])
        flags.firmlinkSkipped = true
        flagsArr[Int(node)] = flags.rawValue
    }

    func markUsedFallback() {
        summary.usedFallback = true
    }

    func progress() -> ScanProgress {
        ScanProgress(
            directoriesScanned: directoriesScanned,
            filesSeen: summary.fileCount + summary.symlinkCount,
            logicalBytes: progressLogical,
            physicalBytes: progressPhysical,
            deniedCount: ledger.deniedCount,
            currentPath: lastPath
        )
    }

    // MARK: - Finalize: CSR + LCA corrections + rollup

    func finalize(rootPath: String, partial: Bool, wallSeconds: Double) -> FileGraph {
        let n = parents.count

        // Children in CSR form.
        var childCount = [Int32](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n { childCount[Int(parents[i])] += 1 }
        }
        var childStart = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { childStart[i + 1] = childStart[i] + childCount[i] }
        var insertion = Array(childStart[0..<n])
        var childItems = [Int32](repeating: 0, count: max(n - 1, 0))
        if n > 1 {
            for i in 1..<n {
                let p = Int(parents[i])
                childItems[Int(insertion[p])] = Int32(i)
                insertion[p] += 1
            }
        }

        // Shared-bytes corrections charged at group LCAs.
        var physicalAdjust: [Int32: Int64] = [:]
        var uniqueAdjust: [Int32: Int64] = [:]

        for (_, acc) in hardlinks {
            let seen = acc.nodes.count
            guard seen >= 1 else { continue }
            let anchor = lowestCommonAncestor(of: acc.nodes)
            if seen > 1 {
                // Rollups above the LCA must count this inode's bytes once, not `seen` times.
                physicalAdjust[anchor, default: 0] -= Int64(seen - 1) * acc.physical
            }
            if UInt32(seen) == acc.totalLinks {
                // Every link is inside this subtree: deleting it all really frees the content.
                let freeable = acc.privateSize >= 0 ? acc.privateSize : acc.physical
                uniqueAdjust[anchor, default: 0] += freeable
            } else {
                for node in acc.nodes {
                    var flags = NodeFlags(rawValue: flagsArr[Int(node)])
                    flags.externalLinks = true
                    flagsArr[Int(node)] = flags.rawValue
                }
            }
        }

        for (_, acc) in clones {
            guard acc.sharedMax > 0, !acc.nodes.isEmpty else { continue }
            let members = acc.nodes.count

            // An APFS clone family (one cloneID) is a set of files WHOLLY
            // sharing their extents; a written-to clone leaves the family (new
            // cloneID, refcnt drops) while its old extents stay physically
            // shared with content we can no longer link to. For such a
            // singleton, per-file privateSize is already the exact deletion
            // truth and no group correction is possible — only honesty:
            // flag it as sharing bytes with content elsewhere.
            guard members > 1 else {
                var flags = NodeFlags(rawValue: flagsArr[Int(acc.nodes[0])])
                flags.externalLinks = true
                flagsArr[Int(acc.nodes[0])] = flags.rawValue
                continue
            }

            let anchor = lowestCommonAncestor(of: acc.nodes)
            // Each member's rollup carried its own shared estimate; keep one.
            physicalAdjust[anchor, default: 0] -= acc.sharedSum - acc.sharedMax
            // Divergent chains make the single-figure estimate inexact; label it.
            if acc.sharedSum != Int64(members) * acc.sharedMax {
                var flags = NodeFlags(rawValue: flagsArr[Int(anchor)])
                flags.sharedEstimate = true
                flagsArr[Int(anchor)] = flags.rawValue
            }
            let familyComplete = acc.refcntMax > 0 && members >= Int(acc.refcntMax)
            if familyComplete {
                // Whole clone family inside this subtree: deleting it frees the shared base too.
                uniqueAdjust[anchor, default: 0] += acc.sharedMax
            } else {
                for node in acc.nodes {
                    var flags = NodeFlags(rawValue: flagsArr[Int(node)])
                    flags.externalLinks = true
                    flagsArr[Int(node)] = flags.rawValue
                }
            }
        }

        // Bottom-up rollup. Nodes are appended parent-before-child, so reverse
        // index order visits every child before its parent.
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) {
                let id = Int32(i)
                if !physicalAdjust.isEmpty, let adjust = physicalAdjust[id] { physicalArr[i] += adjust }
                if !uniqueAdjust.isEmpty, let adjust = uniqueAdjust[id] { uniqueArr[i] += adjust }
                let p = Int(parents[i])
                logicalArr[p] += logicalArr[i]
                physicalArr[p] += physicalArr[i]
                uniqueArr[p] += uniqueArr[i]
            }
        }
        if n > 0 {
            if let adjust = physicalAdjust[0] { physicalArr[0] += adjust }
            if let adjust = uniqueAdjust[0] { uniqueArr[0] += adjust }
        }

        // Largest-first children for every consumer of the graph.
        for i in 0..<n where childCount[i] > 1 {
            let range = Int(childStart[i])..<Int(childStart[i + 1])
            childItems[range].sort { physicalArr[Int($0)] > physicalArr[Int($1)] }
        }

        summary.deniedDirectoryCount = ledger.deniedCount
        summary.partial = partial
        summary.wallSeconds = wallSeconds
        if n > 0 {
            summary.totalLogical = logicalArr[0]
            summary.totalPhysical = physicalArr[0]
            summary.totalUnique = uniqueArr[0]
        }

        return FileGraph(
            nameArena: nameArena,
            nameOffsets: nameOffsets,
            nameLengths: nameLengths,
            parents: parents,
            depths: depths,
            logicalArr: logicalArr,
            physicalArr: physicalArr,
            uniqueArr: uniqueArr,
            flagsArr: flagsArr,
            childStart: childStart,
            childItems: childItems,
            rootPath: rootPath,
            ledger: ledger,
            summary: summary
        )
    }

    private func lowestCommonAncestor(of nodes: [Int32]) -> Int32 {
        guard var current = nodes.first else { return 0 }
        for node in nodes.dropFirst() {
            current = lowestCommonAncestor(current, node)
            if current == 0 { break }
        }
        return current
    }

    private func lowestCommonAncestor(_ a: Int32, _ b: Int32) -> Int32 {
        var x = a
        var y = b
        while depths[Int(x)] > depths[Int(y)] { x = parents[Int(x)] }
        while depths[Int(y)] > depths[Int(x)] { y = parents[Int(y)] }
        while x != y {
            x = parents[Int(x)]
            y = parents[Int(y)]
        }
        return x
    }
}
