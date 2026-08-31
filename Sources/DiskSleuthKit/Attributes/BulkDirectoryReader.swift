import Darwin

/// Streams a directory's entries via getattrlistbulk(2) — one syscall returns
/// metadata for hundreds of entries at once, the technique that makes fast Mac
/// scanners fast. The fd is borrowed, not owned; the caller closes it.
/// Not thread-safe; use from a single task.
final class BulkDirectoryReader {
    private let fd: CInt
    private var attrList = RequestedAttrs.makeList()
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var batchesRead = 0

    init(fd: CInt) {
        self.fd = fd
        self.buffer = .allocate(byteCount: bufferSize, alignment: 8)
    }

    deinit {
        buffer.deallocate()
    }

    /// Next batch of entries; empty array means the directory is exhausted.
    /// Throws `.bulkUnsupported` if the very first call fails in a way that
    /// suggests the filesystem can't do bulk reads (caller falls back).
    func nextBatch() throws(ScanError) -> [RawEntry] {
        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOptions.attrCmnExtended))
            if count > 0 {
                batchesRead += 1
                return AttrEntryParser.parseBatch(buffer: buffer, count: Int(count), capacity: bufferSize)
            }
            if count == 0 { return [] }
            let code = errno
            if code == EINTR { continue }
            if batchesRead == 0 && (code == ENOTSUP || code == EINVAL || code == EOPNOTSUPP) {
                throw ScanError.bulkUnsupported
            }
            throw ScanError.attrReadFailed(code: code)
        }
    }
}
