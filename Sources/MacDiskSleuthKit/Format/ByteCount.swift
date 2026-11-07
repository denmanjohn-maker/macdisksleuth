import Foundation

/// Human-readable byte formatting shared by the CLI and the app.
public enum ByteCount {
    /// "498.1 GB" (decimal, matches Finder) or "463.9 GiB" (binary) styles.
    public static func format(_ bytes: Int64, binary: Bool = false) -> String {
        if bytes < 0 { return "—" }
        let unit: Double = binary ? 1024 : 1000
        let suffixes = binary
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= unit && index < suffixes.count - 1 {
            value /= unit
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, suffixes[index])
    }
}
