import Darwin

/// Unified directory enumerator: tries the getattrlistbulk fast path, falls
/// back to readdir+fstatat if the filesystem rejects bulk reads outright.
final class DirectoryLister {
    private enum Mode {
        case bulk(BulkDirectoryReader)
        case fallback(FallbackDirectoryReader)
    }

    private var mode: Mode
    private let fd: CInt
    private(set) var usedFallback = false

    init(fd: CInt, preferFallback: Bool = false) {
        self.fd = fd
        if preferFallback, let fallback = FallbackDirectoryReader(fd: fd) {
            self.mode = .fallback(fallback)
            self.usedFallback = true
        } else {
            self.mode = .bulk(BulkDirectoryReader(fd: fd))
        }
    }

    func nextBatch() throws(ScanError) -> [RawEntry] {
        switch mode {
        case .bulk(let reader):
            do {
                return try reader.nextBatch()
            } catch ScanError.bulkUnsupported {
                guard let fallback = FallbackDirectoryReader(fd: fd) else {
                    throw ScanError.attrReadFailed(code: ENOTSUP)
                }
                usedFallback = true
                mode = .fallback(fallback)
                return fallback.nextBatch()
            }
        case .fallback(let reader):
            return reader.nextBatch()
        }
    }
}
