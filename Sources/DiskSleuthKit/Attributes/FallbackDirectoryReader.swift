import Darwin

/// readdir + fstatat fallback for filesystems where getattrlistbulk is
/// unavailable (some network/FUSE mounts). Slower, and returns no APFS
/// extended attributes — the `returned` masks reflect that, so downstream
/// accounting degrades honestly. The fd is borrowed; this reader dups it.
final class FallbackDirectoryReader {
    private let dirFD: CInt
    private var dir: UnsafeMutablePointer<DIR>?

    init?(fd: CInt) {
        self.dirFD = fd
        let duped = dup(fd)
        guard duped >= 0 else { return nil }
        guard let handle = fdopendir(duped) else {
            close(duped)
            return nil
        }
        rewinddir(handle)
        self.dir = handle
    }

    deinit {
        if let dir { closedir(dir) }  // closes the dup'd fd
    }

    func nextBatch(maxEntries: Int = 512) -> [RawEntry] {
        guard let dir else { return [] }
        var entries: [RawEntry] = []
        entries.reserveCapacity(min(maxEntries, 64))
        while entries.count < maxEntries, let dirent = readdir(dir) {
            let name = withUnsafeBytes(of: dirent.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                var end = 0
                while end < bytes.count && bytes[end] != 0 { end += 1 }
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
            if name.isEmpty || name == "." || name == ".." { continue }

            var status = stat()
            guard fstatat(dirFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

            var entry = RawEntry()
            entry.name = name
            entry.fileID = UInt64(status.st_ino)
            entry.bsdFlags = status.st_flags
            entry.linkCount = UInt32(status.st_nlink)
            switch status.st_mode & S_IFMT {
            case S_IFDIR: entry.objType = ObjType.dir
            case S_IFREG: entry.objType = ObjType.reg
            case S_IFLNK: entry.objType = ObjType.lnk
            case S_IFBLK: entry.objType = ObjType.blk
            case S_IFCHR: entry.objType = ObjType.chr
            case S_IFSOCK: entry.objType = ObjType.sock
            case S_IFIFO: entry.objType = ObjType.fifo
            default: entry.objType = 0
            }
            if entry.objType != ObjType.dir {
                entry.logical = Int64(status.st_size)
                entry.physical = Int64(status.st_blocks) * 512
                entry.returned.file = AttrBits.fileLinkCount | AttrBits.fileAllocSize | AttrBits.fileDataLength
            }
            entry.returned.common = AttrBits.cmnName | AttrBits.cmnObjType | AttrBits.cmnFlags | AttrBits.cmnFileID
            entries.append(entry)
        }
        return entries
    }
}
