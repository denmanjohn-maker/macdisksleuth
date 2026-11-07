import Darwin

/// Matches absolute paths against a set of component-wise glob patterns —
/// `/Users/*/Library/Caches`, `/**/node_modules`, `/**/*.lrdata` — as a small
/// NFA that advances one path component at a time. Walked alongside a
/// depth-first traversal, every directory in a multi-million-node graph is
/// classified with a handful of dictionary lookups instead of a path string
/// and a hundred fnmatch calls.
///
/// Components match case-insensitively (APFS defaults to case-insensitive).
/// `*`/`?`/`[…]` match within one component; `**` matches any number of
/// components, including none.
final class PathPatternTrie {
    struct Payload {
        var rule: Int
        /// Literal components outweigh globs, and a glob with more fixed text
        /// outweighs a bare `*.app` — the most specific pattern wins when
        /// several end at one directory.
        var specificity: Int
    }

    final class Node {
        var literal: [String: Node] = [:]
        var globs: [(pattern: String, node: Node)] = []
        var anyDepth: Node?
        let isAnyDepth: Bool
        var payloads: [Payload] = []

        init(isAnyDepth: Bool = false) { self.isAnyDepth = isAnyDepth }
    }

    private let root = Node()

    func insert(_ pattern: String, rule: Int) {
        var node = root
        var specificity = 0
        for component in pattern.split(separator: "/") where !component.isEmpty {
            let text = String(component)
            if text == "**" {
                if node.anyDepth == nil { node.anyDepth = Node(isAnyDepth: true) }
                node = node.anyDepth!
            } else if Self.isGlob(text) {
                let lowered = text.lowercased()
                if let existing = node.globs.first(where: { $0.pattern == lowered }) {
                    node = existing.node
                } else {
                    let next = Node()
                    node.globs.append((lowered, next))
                    node = next
                }
                specificity += text.filter { $0 != "*" && $0 != "?" && $0 != "[" && $0 != "]" }.count
            } else {
                let lowered = text.lowercased()
                if let existing = node.literal[lowered] {
                    node = existing
                } else {
                    let next = Node()
                    node.literal[lowered] = next
                    node = next
                }
                specificity += 100
            }
        }
        node.payloads.append(Payload(rule: rule, specificity: specificity))
    }

    /// The state set positioned at "/" (before any component).
    func start() -> [Node] { closure([root]) }

    /// Consume one path component.
    func advance(_ states: [Node], component: String) -> [Node] {
        let lowered = component.lowercased()
        var next: [Node] = []
        for state in states {
            if state.isAnyDepth { next.append(state) }
            if let literal = state.literal[lowered] { next.append(literal) }
            for (pattern, node) in state.globs where fnmatch(pattern, lowered, 0) == 0 {
                next.append(node)
            }
        }
        return closure(next)
    }

    /// Walk a whole path from the start state.
    func states(forPath path: String) -> [Node] {
        var current = start()
        for component in path.split(separator: "/") where !component.isEmpty {
            current = advance(current, component: String(component))
        }
        return current
    }

    /// Payloads of every pattern ending at this state set.
    func payloads(_ states: [Node]) -> [Payload] {
        states.flatMap(\.payloads)
    }

    /// Pattern components that must be matched before any further payload
    /// can be reached. False means nothing deeper can match: descent is pointless.
    func canMatchDeeper(_ states: [Node]) -> Bool {
        states.contains { !$0.literal.isEmpty || !$0.globs.isEmpty || $0.anyDepth != nil }
    }

    // MARK: - Internals

    /// Add `**` nodes reachable without consuming a component, deduplicated.
    private func closure(_ states: [Node]) -> [Node] {
        var seen = Set<ObjectIdentifier>()
        var result: [Node] = []
        var stack = states
        while let node = stack.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            if let anyDepth = node.anyDepth { stack.append(anyDepth) }
        }
        return result
    }

    private static func isGlob(_ component: String) -> Bool {
        component.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" })
    }
}
