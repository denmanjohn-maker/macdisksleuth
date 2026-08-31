import os

/// Thread-safe set of directories already traversed, keyed by (device, inode).
/// One mechanism kills firmlink double-traversal, mount loops, and directory-
/// hardlink weirdness.
final class VisitedSet: Sendable {
    private struct Key: Hashable {
        var device: UInt64
        var inode: UInt64
    }

    private let storage = OSAllocatedUnfairLock(initialState: Set<Key>())

    /// Returns true if this directory had not been seen before (caller may traverse).
    func markVisited(device: UInt64, inode: UInt64) -> Bool {
        storage.withLock { $0.insert(Key(device: device, inode: inode)).inserted }
    }
}
