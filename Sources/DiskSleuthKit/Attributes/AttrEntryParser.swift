import Darwin

/// Parses the packed attribute buffers produced by getattrlistbulk(2) and
/// getattrlist(2). Both share the same entry shape when ATTR_CMN_RETURNED_ATTRS
/// is requested:
///
///     uint32_t length                 // total entry length; advance by this
///     attribute_set_t returned        // 5 × attrgroup_t = 20 bytes, ALWAYS first
///     ...attributes, canonical order, only those present in `returned`
///
/// Attributes pack in ascending bit order within each group, groups in order
/// common → dir → file → fork(CMNEXT). Every field is 4-byte aligned, so 8-byte
/// values must be read with loadUnaligned. Variable-length data (names) is
/// stored out-of-line and referenced by an attrreference_t whose offset is
/// relative to the attrreference's own location.
enum AttrEntryParser {
    /// Parse a getattrlistbulk buffer containing `count` entries.
    static func parseBatch(buffer: UnsafeRawPointer, count: Int, capacity: Int) -> [RawEntry] {
        var entries: [RawEntry] = []
        entries.reserveCapacity(count)
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 4 <= capacity else { break }
            let entryLength = Int(buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
            guard entryLength >= 24, cursor + entryLength <= capacity else { break }
            if let entry = parseEntry(at: buffer + cursor, length: entryLength) {
                entries.append(entry)
            }
            cursor += entryLength
        }
        return entries
    }

    /// Parse a single getattrlist(2) result. The buffer leads with a uint32
    /// total length (including itself), then the same layout as a bulk entry.
    static func parseSingle(buffer: UnsafeRawPointer, capacity: Int) -> RawEntry? {
        guard capacity >= 24 else { return nil }
        let length = Int(buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        return parseEntry(at: buffer, length: min(length, capacity))
    }

    /// `base` points at the entry's leading uint32 length field.
    private static func parseEntry(at base: UnsafeRawPointer, length: Int) -> RawEntry? {
        guard length >= 24 else { return nil }
        var entry = RawEntry()
        var offset = 4

        var returned = ReturnedGroups()
        returned.common = base.loadUnaligned(fromByteOffset: offset, as: attrgroup_t.self)
        returned.vol = base.loadUnaligned(fromByteOffset: offset + 4, as: attrgroup_t.self)
        returned.dir = base.loadUnaligned(fromByteOffset: offset + 8, as: attrgroup_t.self)
        returned.file = base.loadUnaligned(fromByteOffset: offset + 12, as: attrgroup_t.self)
        returned.fork = base.loadUnaligned(fromByteOffset: offset + 16, as: attrgroup_t.self)
        entry.returned = returned
        offset += 20

        @inline(__always) func canRead(_ size: Int) -> Bool { offset + size <= length }

        // Common group, ascending bit order after RETURNED_ATTRS.
        if returned.hasCommon(AttrBits.cmnName) {
            guard canRead(8) else { return entry }
            let dataOffset = Int(base.loadUnaligned(fromByteOffset: offset, as: Int32.self))
            let dataLength = Int(base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            let nameStart = offset + dataOffset
            if dataLength > 0, nameStart >= 0, nameStart + dataLength <= length {
                let bytes = UnsafeRawBufferPointer(start: base + nameStart, count: dataLength)
                // dataLength includes the NUL terminator; strip trailing NULs defensively.
                var end = dataLength
                while end > 0 && bytes[end - 1] == 0 { end -= 1 }
                entry.name = String(decoding: bytes[0..<end], as: UTF8.self)
            }
            offset += 8
        }
        if returned.hasCommon(AttrBits.cmnObjType) {
            guard canRead(4) else { return entry }
            entry.objType = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if returned.hasCommon(AttrBits.cmnFlags) {
            guard canRead(4) else { return entry }
            entry.bsdFlags = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if returned.hasCommon(AttrBits.cmnFileID) {
            guard canRead(8) else { return entry }
            entry.fileID = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
        }

        // Dir group: nothing requested. File group: present for files/symlinks only.
        if returned.hasFile(AttrBits.fileLinkCount) {
            guard canRead(4) else { return entry }
            entry.linkCount = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }
        if returned.hasFile(AttrBits.fileAllocSize) {
            guard canRead(8) else { return entry }
            entry.physical = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
        }
        if returned.hasFile(AttrBits.fileDataLength) {
            guard canRead(8) else { return entry }
            entry.logical = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
        }

        // Fork group carries CMNEXT attributes (FSOPT_ATTR_CMN_EXTENDED).
        if returned.hasFork(AttrBits.cmnextPrivateSize) {
            guard canRead(8) else { return entry }
            entry.privateSize = base.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
        }
        if returned.hasFork(AttrBits.cmnextCloneID) {
            guard canRead(8) else { return entry }
            entry.cloneID = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
        }
        if returned.hasFork(AttrBits.cmnextExtFlags) {
            guard canRead(8) else { return entry }
            entry.extFlags = base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            offset += 8
        }
        if returned.hasFork(AttrBits.cmnextCloneRefcnt) {
            guard canRead(4) else { return entry }
            entry.cloneRefcnt = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
        }

        return entry
    }
}
