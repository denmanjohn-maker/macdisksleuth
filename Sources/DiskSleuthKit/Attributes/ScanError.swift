import Darwin

public enum ScanError: Error, Sendable {
    case openFailed(path: String, code: Int32)
    case notADirectory(path: String)
    case attrReadFailed(code: Int32)
    /// getattrlistbulk is not usable on this filesystem; caller should fall back.
    case bulkUnsupported
    case cancelled

    public var errnoCode: Int32? {
        switch self {
        case .openFailed(_, let code), .attrReadFailed(let code): code
        default: nil
        }
    }
}

func errnoString(_ code: Int32) -> String {
    String(cString: strerror(code))
}
