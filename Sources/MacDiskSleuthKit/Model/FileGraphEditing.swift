extension FileGraph {
    /// The graph after `node` is deleted (e.g. moved to Trash): its rolled-up
    /// sizes are subtracted from every ancestor and it disappears from its
    /// parent's children via a tombstone. O(depth); no reindexing.
    ///
    /// Shared-byte corrections charged at a common ancestor (hard links or
    /// clones spanning two subtrees) are not re-derived, so totals above a
    /// removed sharing group are approximate until the next scan. The two
    /// invariants every reader relies on are kept regardless: no size is ever
    /// negative, and unique never exceeds physical.
    public func removing(_ node: NodeID) -> FileGraph {
        guard node.raw != 0 else { return self }
        var copy = self
        let removed = sizes(of: node)

        var ancestor = parents[Int(node.raw)]
        while ancestor >= 0 {
            let i = Int(ancestor)
            copy.logicalArr[i] = max(copy.logicalArr[i] - removed.logical, 0)
            copy.physicalArr[i] = max(copy.physicalArr[i] - removed.physical, 0)
            copy.uniqueArr[i] = min(max(copy.uniqueArr[i] - removed.unique, 0), copy.physicalArr[i])
            ancestor = parents[i]
        }

        let index = Int(node.raw)
        copy.logicalArr[index] = 0
        copy.physicalArr[index] = 0
        copy.uniqueArr[index] = 0

        let parent = Int(parents[index])
        if parent >= 0 {
            let range = Int(childStart[parent])..<Int(childStart[parent + 1])
            for i in range where copy.childItems[i] == node.raw {
                copy.childItems[i] = -1
            }
        }

        copy.summary.totalLogical = copy.logicalArr[0]
        copy.summary.totalPhysical = copy.physicalArr[0]
        copy.summary.totalUnique = copy.uniqueArr[0]
        return copy
    }

    /// Whether `node`, or any folder above it, has been tombstoned by
    /// `removing(_:)`. Children of a removed folder keep their entries, so the
    /// walk up is what makes them read as gone. The root is never removed.
    public func isRemoved(_ node: NodeID) -> Bool {
        var current = Int(node.raw)
        guard current > 0, current < parents.count else { return false }
        while current > 0 {
            let parent = Int(parents[current])
            let range = Int(childStart[parent])..<Int(childStart[parent + 1])
            if !childItems[range].contains(Int32(current)) { return true }
            current = parent
        }
        return false
    }

    /// The graph after every node in `nodes` is deleted. Nodes already removed
    /// are skipped, and a node whose ancestor is also in the set is skipped
    /// too: removing the ancestor already takes the descendant's bytes out of
    /// everything above, so applying both would subtract them twice.
    public func removing(all nodes: some Sequence<NodeID>) -> FileGraph {
        let requested = Set(nodes).filter { $0.raw != 0 && !isRemoved($0) }
        var copy = self
        for node in requested.sorted(by: { $0.raw < $1.raw }) where !hasAncestor(of: node, in: requested) {
            copy = copy.removing(node)
        }
        return copy
    }

    private func hasAncestor(of node: NodeID, in set: Set<NodeID>) -> Bool {
        var parent = parents[Int(node.raw)]
        while parent >= 0 {
            if set.contains(NodeID(raw: parent)) { return true }
            parent = parents[Int(parent)]
        }
        return false
    }
}
