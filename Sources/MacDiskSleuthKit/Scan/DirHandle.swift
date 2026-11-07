import Darwin
import os

/// Refcounted owner of an open directory fd. A directory's handle stays open
/// while any child work item still needs it for openat(2), then closes exactly
/// once — keeping the number of open fds bounded without path re-resolution.
final class DirHandle: Sendable {
    let fd: CInt
    private let refs: OSAllocatedUnfairLock<Int>

    init(fd: CInt, initialRefs: Int = 1) {
        self.fd = fd
        self.refs = OSAllocatedUnfairLock(initialState: initialRefs)
    }

    func retain() {
        refs.withLock { $0 += 1 }
    }

    func release() {
        let remaining = refs.withLock { count -> Int in
            count -= 1
            return count
        }
        if remaining == 0 { close(fd) }
    }
}
