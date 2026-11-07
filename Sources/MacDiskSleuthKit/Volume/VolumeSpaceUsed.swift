import Darwin

extension VolumeService {
    /// Per-volume bytes used, via ATTR_VOL_SPACEUSED. On APFS, statfs reports
    /// container-level totals (every volume in the container shows the same
    /// "used"), so this is the only honest per-volume number.
    public static func volumeSpaceUsed(at mountPoint: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrBit(ATTR_VOL_INFO) | attrBit(ATTR_VOL_SPACEUSED)
        list.commonattr = attrBit(ATTR_CMN_RETURNED_ATTRS)

        let bufferSize = 64
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        guard getattrlist(mountPoint, &list, buffer, bufferSize, 0) == 0 else { return nil }
        // Layout: u32 length · attribute_set_t (20 B) · off_t spaceUsed.
        let returnedVol = buffer.loadUnaligned(fromByteOffset: 8, as: attrgroup_t.self)
        guard returnedVol & attrBit(ATTR_VOL_SPACEUSED) != 0 else { return nil }
        return buffer.loadUnaligned(fromByteOffset: 24, as: Int64.self)
    }
}
