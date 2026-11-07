/// What kind of filesystem object a node is.
public enum NodeKind: UInt16, Sendable {
    case file = 0
    case directory = 1
    case symlink = 2
    case other = 3
}

/// Packed per-node kind + attribute flags (2 bytes per node; storage matters
/// at millions of nodes).
public struct NodeFlags: Sendable, Equatable {
    public var rawValue: UInt16

    public init(kind: NodeKind) { rawValue = kind.rawValue }
    init(rawValue: UInt16) { self.rawValue = rawValue }

    public var kind: NodeKind { NodeKind(rawValue: rawValue & 0b11) ?? .other }

    private static let clonedBit: UInt16 = 1 << 2
    private static let sparseBit: UInt16 = 1 << 3
    private static let hardlinkedBit: UInt16 = 1 << 4
    private static let datalessBit: UInt16 = 1 << 5
    private static let purgeableBit: UInt16 = 1 << 6
    private static let accessDeniedBit: UInt16 = 1 << 7
    private static let compressedBit: UInt16 = 1 << 8
    private static let otherVolumeBit: UInt16 = 1 << 9
    private static let externalLinksBit: UInt16 = 1 << 10
    private static let sharedEstimateBit: UInt16 = 1 << 11
    private static let duplicateBit: UInt16 = 1 << 12
    private static let firmlinkSkippedBit: UInt16 = 1 << 13

    private func has(_ bit: UInt16) -> Bool { rawValue & bit != 0 }
    private mutating func set(_ bit: UInt16, _ on: Bool) {
        if on { rawValue |= bit } else { rawValue &= ~bit }
    }

    /// File shares extents with at least one clone.
    public var cloned: Bool {
        get { has(Self.clonedBit) }
        set { set(Self.clonedBit, newValue) }
    }
    public var sparse: Bool {
        get { has(Self.sparseBit) }
        set { set(Self.sparseBit, newValue) }
    }
    public var hardlinked: Bool {
        get { has(Self.hardlinkedBit) }
        set { set(Self.hardlinkedBit, newValue) }
    }
    /// Placeholder whose content lives in iCloud/File Provider; never opened.
    public var dataless: Bool {
        get { has(Self.datalessBit) }
        set { set(Self.datalessBit, newValue) }
    }
    /// Marked purgeable by the system (evictable under pressure).
    public var purgeable: Bool {
        get { has(Self.purgeableBit) }
        set { set(Self.purgeableBit, newValue) }
    }
    /// Directory could not be read; subtree sizes undercount.
    public var accessDenied: Bool {
        get { has(Self.accessDeniedBit) }
        set { set(Self.accessDeniedBit, newValue) }
    }
    /// Transparently compressed (decmpfs); physical < logical is real savings.
    public var compressed: Bool {
        get { has(Self.compressedBit) }
        set { set(Self.compressedBit, newValue) }
    }
    /// Mount point onto another volume; not traversed.
    public var otherVolume: Bool {
        get { has(Self.otherVolumeBit) }
        set { set(Self.otherVolumeBit, newValue) }
    }
    /// Hardlinks/clones of this content exist outside the scanned tree —
    /// deleting everything scanned still can't free the shared bytes.
    public var externalLinks: Bool {
        get { has(Self.externalLinksBit) }
        set { set(Self.externalLinksBit, newValue) }
    }
    /// A divergent clone family's shared bytes were estimated, not exact.
    public var sharedEstimate: Bool {
        get { has(Self.sharedEstimateBit) }
        set { set(Self.sharedEstimateBit, newValue) }
    }
    /// Directory already visited via another path (firmlink/cycle); not re-traversed.
    public var duplicate: Bool {
        get { has(Self.duplicateBit) }
        set { set(Self.duplicateBit, newValue) }
    }
    /// Firmlink target under /System/Volumes/Data whose content is attributed
    /// to its firmlink position (e.g. /Users) instead.
    public var firmlinkSkipped: Bool {
        get { has(Self.firmlinkSkippedBit) }
        set { set(Self.firmlinkSkippedBit, newValue) }
    }
}
