extension FileGraph {
    /// The graph after `node` is deleted (e.g. moved to Trash): its rolled-up
    /// sizes are subtracted from every ancestor and it disappears from its
    /// parent's children via a tombstone. O(depth); no reindexing. A rescan
    /// refreshes exact shared-bytes accounting.
    public func removing(_ node: NodeID) -> FileGraph {
        guard node.raw != 0 else { return self }
        var copy = self
        let removed = sizes(of: node)

        var ancestor = parents[Int(node.raw)]
        while ancestor >= 0 {
            copy.logicalArr[Int(ancestor)] -= removed.logical
            copy.physicalArr[Int(ancestor)] -= removed.physical
            copy.uniqueArr[Int(ancestor)] -= removed.unique
            ancestor = parents[Int(ancestor)]
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
}
