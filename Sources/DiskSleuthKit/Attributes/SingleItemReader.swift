import Darwin

/// Truth card for a single filesystem item — everything `disksleuth info`
/// and the app inspector show about one path.
public struct ItemInfo: Sendable {
    public var path: String
    public var entry: RawEntry
    public var device: UInt64
    public var volumeMountPoint: String
    public var volumeFSType: String

    public var isAPFS: Bool { volumeFSType == "apfs" }

    /// Best-truth estimate of bytes freed by deleting this item right now
    /// (snapshot pinning excluded — callers surface that caveat separately).
    public var freeableNow: Int64 {
        if entry.linkCount > 1 { return 0 }
        if entry.privateSize >= 0 { return entry.privateSize }
        return max(entry.physical, 0)
    }
}

public enum SingleItemReader {
    /// Read one item's attributes without following a trailing symlink and
    /// without ever opening the file (dataless placeholders stay dataless).
    public static func read(path: String) throws(ScanError) -> ItemInfo {
        let bufferSize = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var attrList = RequestedAttrs.makeList()
        let options: UInt32 = FSOptions.attrCmnExtended | FSOptions.noFollow
        while true {
            let result = getattrlist(path, &attrList, buffer, bufferSize, options)
            if result == 0 { break }
            let code = errno
            if code == EINTR { continue }
            throw ScanError.openFailed(path: path, code: code)
        }
        guard var entry = AttrEntryParser.parseSingle(buffer: buffer, capacity: bufferSize) else {
            throw ScanError.attrReadFailed(code: EINVAL)
        }
        // getattrlist's ATTR_CMN_NAME is the item's canonical name; prefer the
        // path's last component if the name came back empty (root of a volume).
        if entry.name.isEmpty {
            entry.name = path.split(separator: "/").last.map(String.init) ?? path
        }

        var status = stat()
        var device: UInt64 = 0
        if lstat(path, &status) == 0 {
            device = UInt64(status.st_dev)
            // Directories don't return the file group; synthesize sizes for
            // symlinks/specials that a filesystem might short-change.
            if entry.physical < 0 && !entry.isDirectory {
                entry.physical = Int64(status.st_blocks) * 512
            }
            if entry.logical < 0 && !entry.isDirectory {
                entry.logical = Int64(status.st_size)
            }
        }

        var fsInfo = statfs()
        var mountPoint = "/"
        var fsType = ""
        if statfs(path, &fsInfo) == 0 {
            mountPoint = withUnsafeBytes(of: fsInfo.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            fsType = withUnsafeBytes(of: fsInfo.f_fstypename) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }

        return ItemInfo(
            path: path,
            entry: entry,
            device: device,
            volumeMountPoint: mountPoint,
            volumeFSType: fsType
        )
    }
}
