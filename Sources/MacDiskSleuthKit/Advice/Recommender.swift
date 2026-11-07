import Foundation

/// Turns a finished scan into "the five things to delete first".
///
/// Intelligence, in order of weight:
/// 1. **Honest bytes.** Everything ranks by *freeable* (what deletion really
///    gives back), never logical size. Clones and hard links that would free
///    nothing are skipped and reported as skipped.
/// 2. **Knowledge of macOS.** A rule base (`CleanupKnowledge`) knows which
///    folders are regenerable caches, build output, installers, VM images,
///    backups — and which must never be touched (mail, photos, cloud-synced
///    folders, the OS). Project markers keep `node_modules` from matching
///    outside a project; related finds merge into one action.
/// 3. **Staleness.** Modification times roll up the tree, so a cache nothing
///    has touched in a year outranks one written this morning, and Downloads
///    older than a month surface while last week's don't.
/// 4. **Duplicates.** Files with the same name and exact size in different
///    folders that are *not* clones — real double storage.
/// 5. **Volume facts.** Local snapshots and purgeable space, when known.
public enum Recommender {
    public static func recommend(
        graph: FileGraph, context: RecommendationContext = RecommendationContext()
    ) -> RecommendationReport {
        var engine = Engine(graph: graph, context: context)
        return engine.run()
    }
}

private struct Engine {
    private struct Candidate {
        /// Index into `CleanupKnowledge.rules`; nil for a generic large file.
        var rule: Int?
        var node: NodeID
        var path: String
        /// Matcher state at this node, so protected children can be told apart.
        var states: [PathPatternTrie.Node] = []
        /// The scan root itself matched a rule: recommend its children.
        var forceChildren = false
    }

    private struct Frame {
        var node: NodeID
        var path: String
        var states: [PathPatternTrie.Node]
        var genericAllowed: Bool
    }

    private struct DuplicateKey: Hashable {
        var name: String
        var logical: Int64
    }

    /// Protected content: never recommended, never a member.
    private static let excludeRule = -1
    /// Opaque bundle: not descended into, but may be a member of a recommendation.
    private static let opaqueRule = -2

    private let graph: FileGraph
    private let context: RecommendationContext
    private let trie = PathPatternTrie()
    private let rules = CleanupKnowledge.rules

    private let fileFloor: Int64
    private let itemFloor: Int64
    private let duplicateFloor: Int64

    private var candidates: [Candidate] = []
    private var duplicateGroups: [DuplicateKey: [NodeID]] = [:]
    private var skippedClones = 0
    private var skippedCloneLogical: Int64 = 0
    private var rootExcluded = false

    init(graph: FileGraph, context: RecommendationContext) {
        self.graph = graph
        self.context = context
        fileFloor = max(context.minimumBytes, 1)
        itemFloor = max(context.minimumBytes / 20, 1)
        duplicateFloor = max(context.minimumBytes / 2, 1)

        for (index, rule) in rules.enumerated() {
            for pattern in rule.patterns {
                for expanded in expand(pattern) { trie.insert(expanded, rule: index) }
            }
        }
        for pattern in CleanupKnowledge.excludedPatterns {
            for expanded in expand(pattern) { trie.insert(expanded, rule: Self.excludeRule) }
        }
        for pattern in CleanupKnowledge.opaquePatterns {
            for expanded in expand(pattern) { trie.insert(expanded, rule: Self.opaqueRule) }
        }
    }

    /// "~/x" → the user's home and every account under /Users.
    private func expand(_ pattern: String) -> [String] {
        guard pattern.hasPrefix("~") else { return [pattern] }
        let rest = String(pattern.dropFirst())
        var expanded = [context.homeDirectory + rest]
        let everyUser = "/Users/*" + rest
        if everyUser != expanded[0] { expanded.append(everyUser) }
        return expanded
    }

    // MARK: - Run

    mutating func run() -> RecommendationReport {
        traverse()

        var all = build().filter { $0.freeable >= context.minimumBytes }
        let volumeAdvice = rootExcluded ? nil : snapshotAdvice()
        all.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.freeable != b.freeable { return a.freeable > b.freeable }
            return a.id < b.id
        }
        let top = Array(all.prefix(max(context.limit, 0)))

        var notes: [String] = []
        if rootExcluded {
            notes.append(
                "The scanned folder is one MacDiskSleuth never suggests deleting from (system files, mail, photos, or cloud-synced content).")
        } else if top.isEmpty {
            notes.append(
                "Nothing above \(ByteCount.format(context.minimumBytes)) stood out as disposable here. Scan a broader folder or lower the size floor.")
        }
        if skippedClones > 0 {
            notes.append(
                "Skipped \(skippedClones.formatted()) large file\(skippedClones == 1 ? "" : "s") that \(skippedClones == 1 ? "is a clone or hard link" : "are clones or hard links") "
                    + "(\(ByteCount.format(skippedCloneLogical)) logical) — deleting \(skippedClones == 1 ? "it" : "them") would free almost nothing.")
        }
        let denied = graph.summary.deniedDirectoryCount
        if denied > 0 {
            var note = "\(denied.formatted()) folder\(denied == 1 ? "" : "s") could not be read, so candidates may be missing."
            if graph.ledger.likelyNeedsFullDiskAccess { note += " Grant Full Disk Access for a complete picture." }
            notes.append(note)
        }
        let timeMachine = context.timeMachineSnapshots.count
        if timeMachine > 0 {
            notes.append(
                "\(timeMachine) local Time Machine snapshot\(timeMachine == 1 ? " exists" : "s exist") — space freed by deletions may appear gradually as they thin.")
        }

        return RecommendationReport(
            recommendations: top,
            totalFreeable: top.reduce(Int64(0)) { $0 + $1.freeable },
            consideredCount: all.count,  // everything that cleared the size floor
            notes: notes,
            generatedAt: context.now,
            volumeAdvice: volumeAdvice)
    }

    // MARK: - Traversal

    private mutating func traverse() {
        // Position the pattern matcher at the scan root, deciding on the way
        // whether generic large-file finds are allowed there.
        var states = trie.start()
        var genericAllowed = true
        var ancestorExcluded = false
        var path = ""
        for component in graph.rootPath.split(separator: "/") where !component.isEmpty {
            let name = String(component)
            let parent = path.isEmpty ? "/" : path
            path += "/" + name
            states = trie.advance(states, component: name)
            if genericAllowed {
                genericAllowed = allowsGeneric(name: name, path: path, parentPath: parent, explicit: true)
            }
            // Scanning inside protected content (a .git, a mail store, an app
            // bundle) is still inside it; the exclusion travels down.
            let (ancestorRule, excludedHere) = decide(states)
            if excludedHere && ancestorRule == nil { ancestorExcluded = true }
        }
        let rootPath = graph.rootPath

        let (rule, excluded) = decide(states)
        if let rule, applies(rules[rule], node: graph.root, parent: nil) {
            candidates.append(
                Candidate(rule: rule, node: graph.root, path: rootPath, states: states, forceChildren: true))
            return
        }
        if excluded || ancestorExcluded {
            rootExcluded = true
            return
        }

        var stack = [Frame(node: graph.root, path: rootPath, states: states, genericAllowed: genericAllowed)]
        while let frame = stack.popLast() {
            for child in graph.children(of: frame.node) {
                let flags = graph.flags(of: child)
                let name = graph.name(of: child)
                switch flags.kind {
                case .directory:
                    // Nothing is charged to mount points, re-visited paths, or
                    // firmlink targets counted elsewhere.
                    if flags.otherVolume || flags.duplicate || flags.firmlinkSkipped { continue }
                    let childPath = frame.path == "/" ? "/" + name : frame.path + "/" + name
                    let childStates = trie.advance(frame.states, component: name)
                    let (rule, excluded) = decide(childStates)
                    if let rule, applies(rules[rule], node: child, parent: frame.node) {
                        candidates.append(Candidate(rule: rule, node: child, path: childPath, states: childStates))
                        continue  // the rule covers the whole subtree
                    }
                    if excluded { continue }
                    if flags.accessDenied { continue }
                    let generic = frame.genericAllowed
                        && allowsGeneric(name: name, path: childPath, parentPath: frame.path, explicit: false)
                    stack.append(Frame(node: child, path: childPath, states: childStates, genericAllowed: generic))

                case .file:
                    guard frame.genericAllowed, !name.hasPrefix(".") else { continue }
                    if flags.dataless { continue }
                    let sizes = graph.sizes(of: child)
                    if sizes.physical >= fileFloor && sizes.unique * 4 < sizes.physical {
                        // A clone or hard link: big on paper, nearly free to keep.
                        skippedClones += 1
                        skippedCloneLogical += sizes.logical
                        continue
                    }
                    if sizes.unique >= duplicateFloor && sizes.logical > 0 {
                        let key = DuplicateKey(name: name.lowercased(), logical: sizes.logical)
                        duplicateGroups[key, default: []].append(child)
                    }
                    if sizes.unique >= fileFloor {
                        let childPath = frame.path == "/" ? "/" + name : frame.path + "/" + name
                        candidates.append(Candidate(rule: nil, node: child, path: childPath))
                    }

                case .symlink, .other:
                    continue
                }
            }
        }
    }

    /// The most specific rule ending here, and whether an exclusion (protected
    /// content or an opaque bundle) does too.
    private func decide(_ states: [PathPatternTrie.Node]) -> (rule: Int?, excluded: Bool) {
        let payloads = trie.payloads(states)
        guard !payloads.isEmpty else { return (nil, false) }
        var best: PathPatternTrie.Payload?
        var excluded = false
        for payload in payloads {
            if payload.rule < 0 {
                excluded = true
            } else if best == nil || payload.specificity > best!.specificity {
                best = payload
            }
        }
        return (best?.rule, excluded)
    }

    /// Protected content ends here (mail, photos, cloud-synced, .git …).
    private func isProtected(_ states: [PathPatternTrie.Node]) -> Bool {
        trie.payloads(states).contains { $0.rule == Self.excludeRule }
    }

    /// Project markers: `node_modules` next to a package.json, a venv with pyvenv.cfg inside.
    private func applies(_ rule: CleanupRule, node: NodeID, parent: NodeID?) -> Bool {
        func anyName(in container: NodeID, matches globs: [String]) -> Bool {
            let names = graph.children(of: container).map { graph.name(of: $0) }
            return globs.contains { glob in names.contains { NodeFilter.glob(glob, matches: $0) } }
        }
        if !rule.requiredSiblings.isEmpty {
            guard let parent, anyName(in: parent, matches: rule.requiredSiblings) else { return false }
        }
        if !rule.requiredChildren.isEmpty {
            guard anyName(in: node, matches: rule.requiredChildren) else { return false }
        }
        return true
    }

    /// Where a big file is just a big file the user put there. Inside Library
    /// folders, hidden folders, bundles and the OS, only the rule base speaks.
    /// `explicit` marks ancestors of the scan root: someone who scans
    /// /private/tmp or ~/.docker on purpose wants to hear about big files in
    /// it, but Library folders and bundles stay rule-only wherever they are.
    private func allowsGeneric(name: String, path: String, parentPath: String, explicit: Bool) -> Bool {
        if !explicit {
            if name.hasPrefix(".") { return false }
            if Self.systemRoots.contains(path) { return false }
        }
        if name == "Library"
            && (parentPath == "/" || parentPath == context.homeDirectory || Self.isUserHome(parentPath))
        {
            return false
        }
        if let ext = NodeFilter.fileExtension(of: name), Self.packageExtensions.contains(ext) {
            return false
        }
        return true
    }

    private static let systemRoots: Set<String> = [
        "/Library", "/System", "/private", "/usr", "/opt", "/Applications", "/bin", "/sbin",
        "/cores", "/dev", "/Network", "/Library/Developer",
    ]

    private static func isUserHome(_ path: String) -> Bool {
        path.hasPrefix("/Users/") && path.split(separator: "/").count == 2
    }

    /// Directory names that are really single documents or bundles.
    private static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "xcodeproj", "xcworkspace", "appex", "kext", "plugin",
        "component", "prefpane", "qlgenerator", "mdimporter", "xpc", "dsym", "xcarchive",
        "playground", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "lrdata", "pvm", "vmwarevm", "utm", "vbox", "sparsebundle", "band", "logicx", "key",
        "pages", "numbers", "rtfd", "scptd", "download", "nib", "storyboardc", "docset",
        "textbundle", "sketch", "aplibrary",
    ]

    // MARK: - Building recommendations

    private func build() -> [Recommendation] {
        var grouped: [String: [Candidate]] = [:]
        var groupOrder: [String] = []
        var out: [Recommendation] = []

        // Duplicates first: an extra copy is recommended once, as a duplicate,
        // never again as a generic large file.
        let (duplicates, duplicateNodes) = duplicateRecommendation()

        for candidate in candidates {
            guard let ruleIndex = candidate.rule else {
                if duplicateNodes.contains(candidate.node) { continue }
                if let generic = genericRecommendation(candidate) { out.append(generic) }
                continue
            }
            let rule = rules[ruleIndex]
            if let group = rule.group {
                if grouped[group] == nil { groupOrder.append(group) }
                grouped[group, default: []].append(candidate)
            } else if let single = standalone(candidate, rule: rule) {
                out.append(single)
            }
        }
        for key in groupOrder {
            if let members = grouped[key], let recommendation = groupRecommendation(key, members) {
                out.append(recommendation)
            }
        }
        if let duplicates { out.append(duplicates) }
        return out
    }

    private struct Members {
        var items: [Recommendation.Item] = []
        var totals = Sizes(logical: 0, physical: 0, unique: 0)
        var newest: Date?

        mutating func merge(_ other: Members) {
            items.append(contentsOf: other.items)
            totals.add(other.totals)
            if let date = other.newest { newest = max(newest ?? date, date) }
        }
    }

    /// What one candidate contributes: itself, or its children when the rule
    /// says those are the interesting units (per-app caches, per-project
    /// DerivedData, stale downloads).
    private func members(of candidate: Candidate, rule: CleanupRule, groupAction: String?) -> Members {
        var result = Members()

        func add(_ node: NodeID, path: String, note: String?) {
            let sizes = graph.sizes(of: node)
            result.totals.add(sizes)
            let date = graph.newestModified(of: node)
            if let date { result.newest = max(result.newest ?? date, date) }
            if sizes.unique >= itemFloor {
                result.items.append(
                    Recommendation.Item(node: node, path: path, sizes: sizes, newestModified: date, note: note))
            }
        }

        if rule.itemsAreChildren || candidate.forceChildren {
            var everyChildIncluded = true
            for child in graph.children(of: candidate.node) {
                let flags = graph.flags(of: child)
                if flags.otherVolume || flags.duplicate || flags.firmlinkSkipped { continue }
                let name = graph.name(of: child)
                // A Photos library or a .git parked in Downloads stays protected.
                if isProtected(trie.advance(candidate.states, component: name)) {
                    everyChildIncluded = false
                    continue
                }
                let newest = graph.newestModified(of: child)
                if let days = rule.staleAfterDays {
                    guard let newest,
                        context.now.timeIntervalSince(newest) >= Double(days) * 86_400
                    else {
                        everyChildIncluded = false
                        continue
                    }
                }
                let childPath = candidate.path == "/" ? "/" + name : candidate.path + "/" + name
                let note: String? =
                    rule.staleAfterDays != nil
                    ? itemDescription(name: name, flags: flags, newest: newest)
                    : CleanupKnowledge.hint(forChildNamed: name)
                add(child, path: childPath, note: note)
            }
            if everyChildIncluded {
                // The folder's own totals carry the shared-bytes corrections
                // charged at this level (hard links spanning two caches free
                // their content only when both go), which a sum of children loses.
                result.totals = graph.sizes(of: candidate.node)
            }
        } else {
            let note: String?
            if let groupAction {
                note = rule.action != groupAction ? rule.action : rule.title
            } else {
                note = nil
            }
            add(candidate.node, path: candidate.path, note: note)
        }
        return result
    }

    /// "installer · untouched for 7 months"
    private func itemDescription(name: String, flags: NodeFlags, newest: Date?) -> String? {
        var parts: [String] = []
        if flags.kind == .directory {
            parts.append("folder")
        } else {
            switch CleanupKnowledge.classify(extension: NodeFilter.fileExtension(of: name)) {
            case .installer: parts.append("installer or archive")
            case .diskImage: parts.append("disk image")
            case .video: parts.append("video")
            case .audio: parts.append("audio")
            case .image: parts.append("image")
            case .dump: parts.append("data export")
            case .log: parts.append("log")
            case .other: break
            }
        }
        if let newest { parts.append(AgeText.staleness(since: newest, now: context.now)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func standalone(_ candidate: Candidate, rule: CleanupRule) -> Recommendation? {
        let found = members(of: candidate, rule: rule, groupAction: nil)
        guard found.totals.unique > 0 else { return nil }
        let asChildren = rule.itemsAreChildren || candidate.forceChildren
        return make(
            id: "\(rule.category.rawValue):\(candidate.path)",
            category: rule.category, title: rule.title, safety: rule.safety,
            reason: rule.reason, action: rule.action,
            node: candidate.node, members: found,
            canMoveToTrash: !asChildren && candidate.node != graph.root && Self.trashable(rule.category))
    }

    private func groupRecommendation(_ key: String, _ candidates: [Candidate]) -> Recommendation? {
        guard let group = CleanupKnowledge.groups[key] else { return nil }
        var found = Members()
        var safety = CleanupSafety.safe
        var category = rules[candidates[0].rule!].category
        for candidate in candidates {
            let rule = rules[candidate.rule!]
            safety = min(safety, rule.safety)
            category = rule.category
            found.merge(members(of: candidate, rule: rule, groupAction: group.action))
        }
        guard found.totals.unique > 0 else { return nil }

        let soleRule = candidates.count == 1 ? rules[candidates[0].rule!] : nil
        let singleNode = soleRule.map { !$0.itemsAreChildren && !candidates[0].forceChildren } ?? false
        return make(
            id: "group:\(key)",
            category: category, title: group.title, safety: safety,
            reason: group.reason, action: group.action,
            node: singleNode ? candidates[0].node : nil, members: found,
            canMoveToTrash: singleNode && Self.trashable(category))
    }

    /// Categories whose advice is "prune from inside the tool" or "let macOS
    /// handle it" never get a Move to Trash button, however single the node.
    private static func trashable(_ category: CleanupCategory) -> Bool {
        category.membersAreTrashable
    }

    private func genericRecommendation(_ candidate: Candidate) -> Recommendation? {
        let node = candidate.node
        let name = graph.name(of: node)
        let sizes = graph.sizes(of: node)
        let flags = graph.flags(of: node)
        guard sizes.unique >= fileFloor else { return nil }
        let newest = graph.newestModified(of: node)
        let ageDays = newest.map { context.now.timeIntervalSince($0) / 86_400 } ?? 0

        let category: CleanupCategory
        let title: String
        let safety: CleanupSafety
        let reason: String
        let action: String
        switch CleanupKnowledge.classify(extension: NodeFilter.fileExtension(of: name)) {
        case .installer:
            category = .installers
            title = "Installer or archive: \(name)"
            safety = ageDays > 30 ? .likelySafe : .review
            reason = "Installers and archives are disposable once installed or extracted, and can be downloaded again."
            action = "Delete it if the app is installed or the archive has been extracted."
        case .diskImage:
            category = .virtualMachines
            title = "Disk image: \(name)"
            safety = .review
            reason = "A virtual machine or disk image — among the largest single items on any Mac. Only you know whether what's inside is still needed."
            action = "Delete it from the VM app so metadata goes too, or move it to external storage."
        case .video:
            category = .media
            title = "Large video: \(name)"
            safety = .review
            reason = "Video makes up the bulk of most full disks. Exports and screen recordings can usually be regenerated; originals belong on external storage."
            action = "Move it to external storage or the cloud, or delete it if it is an export you can redo."
        case .audio:
            category = .media
            title = "Large audio: \(name)"
            safety = .review
            reason = "Uncompressed audio bounces and recordings are large and rarely needed after the project ships."
            action = "Archive to external storage, or delete if it is a bounce you can redo."
        case .image:
            category = .media
            title = "Large image: \(name)"
            safety = .review
            reason = "Layered or raw image files are large; finished work is usually exported elsewhere."
            action = "Archive to external storage, or delete if it is a working copy."
        case .dump:
            category = .largeFile
            title = "Database dump or backup: \(name)"
            safety = ageDays > 90 ? .likelySafe : .review
            reason = "Dumps and backup exports are one-off safety copies; old ones are almost never restored."
            action = "Delete it if the data has moved on, or compress it."
        case .log:
            category = .logs
            title = "Large log file: \(name)"
            safety = .likelySafe
            reason = "A log this large is usually a runaway; it is only useful while chasing the problem that produced it."
            action = "Delete it (or truncate it with `: > file` if the writer is still running)."
        case .other:
            category = .largeFile
            title = "Large file: \(name)"
            safety = .review
            reason = "One of the biggest single files outside caches and app data. It is not a clone or hard link, so deleting it really frees this much."
            action = "Check what it is; move it to external storage or delete it."
        }

        var caveats: [String] = []
        if flags.sparse {
            caveats.append(
                "Sparse file: claims \(ByteCount.format(sizes.logical)) but occupies \(ByteCount.format(sizes.physical)).")
        }
        var found = Members()
        found.totals = sizes
        found.newest = newest
        found.items = [Recommendation.Item(node: node, path: candidate.path, sizes: sizes, newestModified: newest)]
        return make(
            id: "file:\(candidate.path)",
            category: category, title: title, safety: safety, reason: reason, action: action,
            node: node, members: found, canMoveToTrash: true, caveats: caveats)
    }

    /// The duplicate recommendation and the set of extra copies it names.
    private func duplicateRecommendation() -> (Recommendation?, Set<NodeID>) {
        var found = Members()
        var groupCount = 0
        var extras: Set<NodeID> = []
        for (_, nodes) in duplicateGroups where nodes.count > 1 {
            // Keep the oldest copy — the original, usually — and suggest the rest.
            let ordered = nodes.sorted { a, b in
                let dateA = graph.modified(of: a) ?? .distantFuture
                let dateB = graph.modified(of: b) ?? .distantFuture
                if dateA != dateB { return dateA < dateB }
                return a.raw < b.raw
            }
            let kept = context.displayPath(graph.path(of: ordered[0]))
            groupCount += 1
            for extra in ordered.dropFirst() {
                extras.insert(extra)
                let sizes = graph.sizes(of: extra)
                found.totals.add(sizes)
                let date = graph.newestModified(of: extra)
                if let date { found.newest = max(found.newest ?? date, date) }
                found.items.append(
                    Recommendation.Item(
                        node: extra, path: graph.path(of: extra), sizes: sizes, newestModified: date,
                        note: "same name & size as \(kept)"))
            }
        }
        guard groupCount > 0, found.totals.unique > 0 else { return (nil, []) }
        let copies = found.items.count
        let recommendation = make(
            id: "duplicates",
            category: .duplicates,
            title: "Duplicate copies (\(copies) extra \(copies == 1 ? "file" : "files"))",
            safety: .review,
            reason: "Same name and exact size in different folders, and not APFS clones — so each copy really occupies disk. MacDiskSleuth never opens files; confirm they match before deleting.",
            action: "Keep one of each; delete the rest, or turn them into clones with `cp -c` so they share storage.",
            node: nil, members: found, canMoveToTrash: false)
        return (recommendation, extras)
    }

    /// Local Time Machine snapshots on the scanned volume. macOS reports no
    /// per-snapshot size, so this carries no byte figure and never enters the
    /// ranked list or its total — honesty over a number.
    private func snapshotAdvice() -> Recommendation? {
        let count = context.timeMachineSnapshots.count
        guard count > 0 else { return nil }
        let volume = context.volumeMountPoint ?? "/"
        var caveats = ["macOS does not report how much space snapshots hold, so none is counted above."]
        if let purgeable = context.purgeableBytes, purgeable > 0 {
            caveats.append(
                "The volume reports \(ByteCount.format(purgeable)) purgeable in all (snapshots, evictable caches and iCloud content together).")
        }
        return Recommendation(
            id: "snapshots",
            category: .snapshots,
            title: "Local Time Machine snapshots (\(count)) on \(volume)",
            safety: .likelySafe,
            reason: "Local snapshots hold on to every block deleted recently, so other deletions don't show up as free space until they thin. Your Time Machine disk keeps the real history, and macOS makes a fresh local snapshot every hour while Time Machine is on.",
            action: "sudo macdisksleuth cleanup \(Self.shellQuoted(volume)) --remove-snapshots --dry-run   (then without --dry-run)",
            node: nil,
            items: [],
            itemCount: 0,
            sizes: Sizes(logical: 0, physical: 0, unique: 0),
            newestModified: nil,
            caveats: caveats,
            confidence: 0.6,
            canMoveToTrash: false,
            score: 0)
    }

    private static func shellQuoted(_ path: String) -> String {
        path.contains(where: { " \"'\\$`!*?[](){}<>|&;".contains($0) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : path
    }

    private func make(
        id: String, category: CleanupCategory, title: String, safety: CleanupSafety,
        reason: String, action: String, node: NodeID?, members: Members,
        canMoveToTrash: Bool, caveats extraCaveats: [String] = []
    ) -> Recommendation {
        let items = members.items.sorted { a, b in
            if a.sizes.unique != b.sizes.unique { return a.sizes.unique > b.sizes.unique }
            return a.path < b.path
        }
        let totals = members.totals

        var caveats = extraCaveats
        let shared = totals.physical - totals.unique
        if shared > max(1_000_000, totals.physical / 20) {
            caveats.append(
                "\(ByteCount.format(shared)) is shared with clones or hard links elsewhere and stays on disk.")
        }
        if totals.physical > 0 && totals.logical > totals.physical * 2 && !extraCaveats.contains(where: { $0.hasPrefix("Sparse") }) {
            caveats.append(
                "Claims \(ByteCount.format(totals.logical)) but occupies \(ByteCount.format(totals.physical)) — sparse or compressed content.")
        }
        let denied = deniedCount(under: items.map(\.path))
        if denied > 0 {
            caveats.append("\(denied) unreadable folder\(denied == 1 ? "" : "s") inside — the real size is larger.")
        }
        if items.contains(where: { item in item.node.map { graph.flags(of: $0).purgeable } ?? false }) {
            caveats.append("macOS already counts some of this as purgeable.")
        }

        // Rank over every member, then keep only the largest for display, so
        // the storage cap never changes the order.
        var recommendation = Recommendation(
            id: id, category: category, title: title, safety: safety, reason: reason, action: action,
            node: node, items: items, itemCount: items.count,
            sizes: totals, newestModified: members.newest, caveats: caveats,
            confidence: 0, canMoveToTrash: canMoveToTrash, score: 0)
        let ranked = rank(recommendation)
        recommendation.score = ranked.score
        recommendation.confidence = ranked.confidence
        recommendation.items = Array(items.prefix(context.maxItems))
        return recommendation
    }

    /// Freeable bytes, weighted by how safe the deletion is and — where age
    /// means anything — by how long since each member changed. Staleness is
    /// applied per member, not to the group: ~/Library/Caches always has
    /// *something* written today, but the 9 GB Homebrew cache nobody touched
    /// since spring still deserves full credit.
    private func rank(_ recommendation: Recommendation) -> (score: Double, confidence: Double) {
        var weighted = Double(recommendation.freeable)
        if recommendation.category.ageMatters {
            if recommendation.items.isEmpty {
                weighted *= ageFactor(recommendation.newestModified)
            } else {
                var sum = 0.0
                var covered: Int64 = 0
                for item in recommendation.items {
                    sum += Double(item.sizes.unique) * ageFactor(item.newestModified)
                    covered += item.sizes.unique
                }
                // Members below the listing floor count at face value.
                sum += Double(max(recommendation.freeable - covered, 0))
                weighted = sum
            }
        }

        var confidence: Double
        switch recommendation.safety {
        case .safe: confidence = 0.9
        case .likelySafe: confidence = 0.7
        case .review: confidence = 0.45
        }
        if recommendation.category.ageMatters, recommendation.freeable > 0 {
            // Average age factor 1.3 → +0.15; 0.75 → −0.125.
            confidence += (weighted / Double(recommendation.freeable) - 1.0) * 0.5
        }

        switch recommendation.category {
        case .systemManaged: weighted *= 0.3
        case .applications: weighted *= 0.8
        default: break
        }
        let score = weighted * recommendation.safety.weight
        return (score, min(max(confidence, 0.05), 0.99))
    }

    /// Untouched for a year: 1.3×. Written this week: 0.75×. Unknown: neutral.
    private func ageFactor(_ date: Date?) -> Double {
        guard let date else { return 1.0 }
        let days = context.now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<7: return 0.75
        case ..<30: return 0.9
        case ..<90: return 1.0
        case ..<365: return 1.15
        default: return 1.3
        }
    }

    private func deniedCount(under paths: [String]) -> Int {
        guard graph.ledger.deniedCount > 0, !paths.isEmpty else { return 0 }
        var count = 0
        for entry in graph.ledger.denied {
            if paths.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) {
                count += 1
            }
        }
        return count
    }
}

extension Sizes {
    fileprivate mutating func add(_ other: Sizes) {
        logical += other.logical
        physical += other.physical
        unique += other.unique
    }
}
