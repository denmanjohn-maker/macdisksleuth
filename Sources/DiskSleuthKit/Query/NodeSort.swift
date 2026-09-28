import Foundation

/// Multi-key ordering for query results. Size keys rank largest first and
/// text keys A→Z; later keys break ties. `reverse` flips the whole order.
public struct NodeSort: Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case logical
        case physical
        case freeable
        case name
        case path

        public init(lens: SizeLens) {
            switch lens {
            case .logical: self = .logical
            case .physical: self = .physical
            case .unique: self = .freeable
            }
        }

        var lens: SizeLens? {
            switch self {
            case .logical: .logical
            case .physical: .physical
            case .freeable: .unique
            case .name, .path: nil
            }
        }
    }

    public var keys: [Key]
    public var reverse: Bool

    public init(keys: [Key] = [.physical], reverse: Bool = false) {
        self.keys = keys.isEmpty ? [.physical] : keys
        self.reverse = reverse
    }

    /// Parses "freeable,logical" (also accepts the lens aliases "unique"/"u"
    /// and single-letter forms). Returns nil on an unknown or empty key.
    public static func parseKeys(_ text: String) -> [Key]? {
        let parts = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !parts.isEmpty else { return nil }
        var keys: [Key] = []
        for part in parts {
            switch part {
            case "logical", "l": keys.append(.logical)
            case "physical", "p": keys.append(.physical)
            case "freeable", "unique", "f", "u": keys.append(.freeable)
            case "name", "n": keys.append(.name)
            case "path": keys.append(.path)
            default: return nil
            }
        }
        return keys
    }
}

extension FileGraph {
    public struct QueryResult: Sendable {
        /// Matches in sort order, truncated to the requested limit.
        public var nodes: [NodeID]
        /// Matches before truncation.
        public var matchedCount: Int
        /// Nodes of the requested kind considered (before filtering).
        public var candidateCount: Int
        /// Sums over every match (before truncation). Only meaningful for
        /// files — nested folder totals overlap.
        public var matchedTotals: Sizes
    }

    /// Nodes of `kind` (excluding the root) that pass `filter`, ordered by
    /// `sort`. Walks the tree from the root, so items under a deleted
    /// (tombstoned) folder are never returned.
    public func query(
        kind: NodeKind, filter: NodeFilter = NodeFilter(), sort: NodeSort = NodeSort(),
        limit: Int? = nil
    ) -> QueryResult {
        var matched: [NodeID] = []
        var candidates = 0
        var totals = Sizes(logical: 0, physical: 0, unique: 0)

        var stack = [root]
        while let node = stack.popLast() {
            let nodeKind = self.kind(of: node)
            if nodeKind == .directory { stack.append(contentsOf: children(of: node)) }
            guard nodeKind == kind, node != root else { continue }
            candidates += 1
            guard filter.matches(node, in: self) else { continue }
            matched.append(node)
            let sizes = self.sizes(of: node)
            totals.logical += sizes.logical
            totals.physical += sizes.physical
            totals.unique += sizes.unique
        }

        let ordered = sorted(matched, by: sort)
        let limited = limit.map { Array(ordered.prefix(max($0, 0))) } ?? ordered
        return QueryResult(
            nodes: limited, matchedCount: matched.count, candidateCount: candidates,
            matchedTotals: totals)
    }

    /// Orders nodes by `sort`. Text keys are computed once per node, not per
    /// comparison (a path is a parent walk).
    public func sorted(_ nodes: [NodeID], by sort: NodeSort) -> [NodeID] {
        let needsName = sort.keys.contains(.name)
        let needsPath = sort.keys.contains(.path)
        let names = needsName ? nodes.map { name(of: $0) } : []
        let paths = needsPath ? nodes.map { path(of: $0) } : []

        func precedes(_ a: Int, _ b: Int) -> Bool {
            for key in sort.keys {
                if let lens = key.lens {
                    let sizeA = size(of: nodes[a], lens: lens)
                    let sizeB = size(of: nodes[b], lens: lens)
                    if sizeA != sizeB { return sizeA > sizeB }
                } else {
                    let textA = key == .name ? names[a] : paths[a]
                    let textB = key == .name ? names[b] : paths[b]
                    if textA != textB { return textA < textB }
                }
            }
            // Deterministic final tiebreak.
            return nodes[a].raw < nodes[b].raw
        }

        let order = nodes.indices.sorted { sort.reverse ? precedes($1, $0) : precedes($0, $1) }
        return order.map { nodes[$0] }
    }
}
