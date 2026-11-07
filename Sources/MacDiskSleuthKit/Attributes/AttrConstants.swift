import Darwin

// MARK: - Signedness-safe attribute masks
//
// Constants from <sys/attr.h> import into Swift with mixed signedness:
// `ATTR_CMN_RETURNED_ATTRS` (0x80000000) imports as UInt32 while most others
// import as Int32, so they cannot be OR'd together directly. Widen everything
// through `attrBit` when building masks.

@inline(__always)
func attrBit<T: BinaryInteger>(_ value: T) -> attrgroup_t {
    attrgroup_t(truncatingIfNeeded: value)
}

/// The attribute set requested for every directory enumeration and single-item read.
enum RequestedAttrs {
    static let common: attrgroup_t =
        attrBit(ATTR_CMN_RETURNED_ATTRS)
        | attrBit(ATTR_CMN_NAME)
        | attrBit(ATTR_CMN_OBJTYPE)
        | attrBit(ATTR_CMN_FLAGS)
        | attrBit(ATTR_CMN_FILEID)

    static let file: attrgroup_t =
        attrBit(ATTR_FILE_LINKCOUNT)
        | attrBit(ATTR_FILE_ALLOCSIZE)
        | attrBit(ATTR_FILE_DATALENGTH)

    /// With FSOPT_ATTR_CMN_EXTENDED set, the forkattr slot selects ATTR_CMNEXT_* attributes.
    static let fork: attrgroup_t =
        attrBit(ATTR_CMNEXT_PRIVATESIZE)
        | attrBit(ATTR_CMNEXT_CLONEID)
        | attrBit(ATTR_CMNEXT_EXT_FLAGS)
        | attrBit(ATTR_CMNEXT_CLONE_REFCNT)

    static func makeList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = common
        list.fileattr = file
        list.forkattr = fork
        return list
    }
}

/// Individual attribute bits, pre-widened, for testing membership in returned masks.
enum AttrBits {
    static let cmnName = attrBit(ATTR_CMN_NAME)
    static let cmnObjType = attrBit(ATTR_CMN_OBJTYPE)
    static let cmnFlags = attrBit(ATTR_CMN_FLAGS)
    static let cmnFileID = attrBit(ATTR_CMN_FILEID)
    static let fileLinkCount = attrBit(ATTR_FILE_LINKCOUNT)
    static let fileAllocSize = attrBit(ATTR_FILE_ALLOCSIZE)
    static let fileDataLength = attrBit(ATTR_FILE_DATALENGTH)
    static let cmnextPrivateSize = attrBit(ATTR_CMNEXT_PRIVATESIZE)
    static let cmnextCloneID = attrBit(ATTR_CMNEXT_CLONEID)
    static let cmnextExtFlags = attrBit(ATTR_CMNEXT_EXT_FLAGS)
    static let cmnextCloneRefcnt = attrBit(ATTR_CMNEXT_CLONE_REFCNT)
}

/// getattrlist/getattrlistbulk option flags. Defined numerically (ABI-stable)
/// to sidestep import-signedness surprises.
enum FSOptions {
    /// Reinterpret the forkattr slot as ATTR_CMNEXT_* attributes.
    static let attrCmnExtended: UInt32 = 0x0000_0020
    /// Do not follow a symlink at the end of the path (getattrlist only).
    static let noFollow: UInt32 = 0x0000_0001
}

/// fsobj_type_t values (enum vtype in <sys/vnode.h>; ABI-stable).
enum ObjType {
    static let reg: UInt32 = 1
    static let dir: UInt32 = 2
    static let blk: UInt32 = 3
    static let chr: UInt32 = 4
    static let lnk: UInt32 = 5
    static let sock: UInt32 = 6
    static let fifo: UInt32 = 7
}

/// ATTR_CMNEXT_EXT_FLAGS bits (EF_* in <sys/stat.h>; ABI-stable values).
public enum ExtFlags {
    public static let mayShareBlocks: UInt64 = 0x0000_0001
    public static let noXattrs: UInt64 = 0x0000_0002
    public static let isSyncRoot: UInt64 = 0x0000_0004
    public static let isPurgeable: UInt64 = 0x0000_0008
    public static let isSparse: UInt64 = 0x0000_0010
    public static let sharesAllBlocks: UInt64 = 0x0000_0020
}

/// st_flags / ATTR_CMN_FLAGS bits of interest (<sys/stat.h>; ABI-stable values).
public enum BSDFlags {
    /// File content is not materialized locally (iCloud/File Provider placeholder).
    public static let dataless: UInt32 = 0x4000_0000  // SF_DATALESS
    /// Transparently compressed (decmpfs).
    public static let compressed: UInt32 = 0x0000_0020  // UF_COMPRESSED
}
