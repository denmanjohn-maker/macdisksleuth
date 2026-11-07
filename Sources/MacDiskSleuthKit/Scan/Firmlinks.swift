import Foundation

/// The system↔Data volume firmlink table. When scanning "/", firmlinked
/// content (e.g. /Users → Data/Users) is attributed to its firmlink position;
/// the literal /System/Volumes/Data subtree is traversed only for the residue
/// no firmlink covers (.Spotlight-V100, .fseventsd, …), skipping firmlink
/// targets so nothing is counted twice and attribution stays deterministic.
enum Firmlinks {
    /// Firmlink target paths relative to the Data volume root,
    /// e.g. "Applications", "Users", "usr/local".
    static func targetsRelativeToDataVolume() -> Set<String> {
        guard let contents = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        else { return [] }
        var targets: Set<String> = []
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2 else { continue }
            targets.insert(String(fields[1]))
        }
        return targets
    }
}
