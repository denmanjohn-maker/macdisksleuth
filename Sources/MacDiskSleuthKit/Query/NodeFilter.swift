import Darwin
import Foundation

/// Criteria for selecting nodes from a FileGraph. An empty filter matches
/// everything. Size and percent checks use `lens`; extension and attribute
/// criteria only ever match files (a folder has no extension or clone flag).
public struct NodeFilter: Sendable {
    /// Per-file APFS attributes a filter can require.
    public enum Attribute: String, Sendable, CaseIterable {
        case clone
        case hardlink
        case sparse
        case dataless
        case compressed
        case sharedOutside = "shared-outside"

        func isSet(in flags: NodeFlags) -> Bool {
            switch self {
            case .clone: flags.cloned
            case .hardlink: flags.hardlinked
            case .sparse: flags.sparse
            case .dataless: flags.dataless
            case .compressed: flags.compressed
            case .sharedOutside: flags.externalLinks
            }
        }
    }

    public var lens: SizeLens = .physical
    public var minSize: Int64?
    public var maxSize: Int64?
    /// Minimum share of the scan root's size (0–100), in `lens`.
    public var minPercent: Double?
    /// Lowercased, without the leading dot. Non-empty → files must match one.
    public var includeExtensions: Set<String> = []
    public var excludeExtensions: Set<String> = []
    /// fnmatch(3) globs, case-insensitive. A pattern containing "/" is matched
    /// against the absolute path, otherwise against the item's name.
    /// Non-empty include → the item must match at least one.
    public var includeGlobs: [String] = []
    public var excludeGlobs: [String] = []
    /// Every listed attribute must be set.
    public var requiredAttributes: Set<Attribute> = []

    public init() {}

    public var isEmpty: Bool {
        minSize == nil && maxSize == nil && minPercent == nil
            && includeExtensions.isEmpty && excludeExtensions.isEmpty
            && includeGlobs.isEmpty && excludeGlobs.isEmpty
            && requiredAttributes.isEmpty
    }

    /// Whether any criterion only makes sense for files.
    public var hasFileOnlyCriteria: Bool {
        !includeExtensions.isEmpty || !excludeExtensions.isEmpty || !requiredAttributes.isEmpty
    }

    /// ".MOV" / "mov" → "mov".
    public static func normalizedExtension(_ text: String) -> String {
        var ext = text.trimmingCharacters(in: .whitespaces).lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        return ext
    }

    /// Lowercased extension of a file name; nil for none. A leading dot alone
    /// (".DS_Store", ".zshrc") marks a hidden file, not an extension.
    public static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    public func matches(_ node: NodeID, in graph: FileGraph) -> Bool {
        if isEmpty { return true }

        // Cheapest checks first: array reads, then name, then the full path
        // (a parent walk) only when a path glob needs it.
        let size = graph.size(of: node, lens: lens)
        if let minSize, size < minSize { return false }
        if let maxSize, size > maxSize { return false }
        if let minPercent {
            let rootSize = graph.size(of: graph.root, lens: lens)
            let percent = rootSize > 0 ? Double(size) / Double(rootSize) * 100 : 0
            if percent < minPercent { return false }
        }

        let flags = graph.flags(of: node)
        if hasFileOnlyCriteria {
            guard flags.kind == .file else { return false }
            for attribute in requiredAttributes where !attribute.isSet(in: flags) { return false }
        }

        if includeExtensions.isEmpty && excludeExtensions.isEmpty
            && includeGlobs.isEmpty && excludeGlobs.isEmpty
        {
            return true
        }

        let name = graph.name(of: node)
        if !includeExtensions.isEmpty || !excludeExtensions.isEmpty {
            let ext = Self.fileExtension(of: name)
            if !includeExtensions.isEmpty {
                guard let ext, includeExtensions.contains(ext) else { return false }
            }
            if let ext, excludeExtensions.contains(ext) { return false }
        }

        if includeGlobs.isEmpty && excludeGlobs.isEmpty { return true }
        var cachedPath: String?
        func subject(for pattern: String) -> String {
            guard pattern.contains("/") else { return name }
            if let cachedPath { return cachedPath }
            let path = graph.path(of: node)
            cachedPath = path
            return path
        }
        if !includeGlobs.isEmpty
            && !includeGlobs.contains(where: { Self.glob($0, matches: subject(for: $0)) })
        {
            return false
        }
        if excludeGlobs.contains(where: { Self.glob($0, matches: subject(for: $0)) }) {
            return false
        }
        return true
    }

    static func glob(_ pattern: String, matches text: String) -> Bool {
        fnmatch(pattern, text, FNM_CASEFOLD) == 0
    }
}
