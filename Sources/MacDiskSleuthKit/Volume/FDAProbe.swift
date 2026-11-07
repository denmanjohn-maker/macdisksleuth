import Darwin
import Foundation

/// Whether the current process has Full Disk Access (TCC).
public enum FDAStatus: Sendable {
    case granted
    case denied
    case unknown
}

public enum FDAProbe {
    /// Try opening known TCC-protected locations. EPERM ⇒ no Full Disk Access;
    /// success on any ⇒ granted. Never reads content.
    public static func status() -> FDAStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let canaries = [
            home + "/Library/Application Support/com.apple.TCC",
            home + "/Library/Application Support/CallHistoryDB",
            home + "/Library/Mail",
            home + "/Library/Safari",
        ]
        var sawDenial = false
        for canary in canaries {
            let fd = open(canary, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { sawDenial = true }
        }
        return sawDenial ? .denied : .unknown
    }
}
