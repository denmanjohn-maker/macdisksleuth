import Darwin

/// Which attribute groups the filesystem actually returned for an entry.
/// Reads of absent attributes must be guarded on this — that is what lets the
/// same parser degrade gracefully on filesystems without APFS extended attrs.
public struct ReturnedGroups: Sendable {
    public var common: attrgroup_t = 0
    public var vol: attrgroup_t = 0
    public var dir: attrgroup_t = 0
    public var file: attrgroup_t = 0
    public var fork: attrgroup_t = 0

    @inline(__always) func hasCommon(_ bit: attrgroup_t) -> Bool { common & bit != 0 }
    @inline(__always) func hasFile(_ bit: attrgroup_t) -> Bool { file & bit != 0 }
    @inline(__always) func hasFork(_ bit: attrgroup_t) -> Bool { fork & bit != 0 }
}

/// One parsed directory entry (or single-item getattrlist result).
/// Sendable value; sizes are -1 when the attribute was not returned.
public struct RawEntry: Sendable {
    public var name: String = ""
    public var objType: UInt32 = 0
    public var fileID: UInt64 = 0
    public var bsdFlags: UInt32 = 0
    public var linkCount: UInt32 = 1
    /// ATTR_FILE_DATALENGTH; -1 if not returned (e.g. directories).
    public var logical: Int64 = -1
    /// ATTR_FILE_ALLOCSIZE; -1 if not returned.
    public var physical: Int64 = -1
    /// ATTR_CMNEXT_PRIVATESIZE — bytes actually freed by deleting this item; -1 if not returned.
    public var privateSize: Int64 = -1
    /// ATTR_CMNEXT_CLONEID; 0 if not returned.
    public var cloneID: UInt64 = 0
    /// ATTR_CMNEXT_EXT_FLAGS; 0 if not returned.
    public var extFlags: UInt64 = 0
    /// ATTR_CMNEXT_CLONE_REFCNT (macOS 14+); 0 if not returned.
    public var cloneRefcnt: UInt32 = 0
    public var returned = ReturnedGroups()

    public var isDirectory: Bool { objType == ObjType.dir }
    public var isSymlink: Bool { objType == ObjType.lnk }
    public var isRegularFile: Bool { objType == ObjType.reg }
    public var isDataless: Bool { bsdFlags & BSDFlags.dataless != 0 }
    public var isCompressed: Bool { bsdFlags & BSDFlags.compressed != 0 }
    public var maySharesBlocks: Bool { extFlags & ExtFlags.mayShareBlocks != 0 }
    public var isSparse: Bool { extFlags & ExtFlags.isSparse != 0 }
    public var isPurgeable: Bool { extFlags & ExtFlags.isPurgeable != 0 }
    public var hasPrivateSize: Bool { returned.hasFork(AttrBits.cmnextPrivateSize) }
}
