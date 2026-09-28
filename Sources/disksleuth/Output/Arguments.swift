import ArgumentParser
import DiskSleuthKit
import Foundation

extension SizeLens: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "logical", "l": self = .logical
        case "physical", "p": self = .physical
        case "unique", "freeable", "u", "f": self = .unique
        default: return nil
        }
    }
}

/// A human size such as "100MB", "1.5GiB", or "4k".
struct SizeArgument: ExpressibleByArgument {
    var bytes: Int64

    init?(argument: String) {
        guard let bytes = ByteCount.parse(argument) else { return nil }
        self.bytes = bytes
    }
}

/// Flattens repeatable, comma-separated list options: ["mov,mp4", "avi"] → ["mov", "mp4", "avi"].
func splitList(_ values: [String]) -> [String] {
    values.flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func parseAttributes(_ values: [String]) throws -> Set<NodeFilter.Attribute> {
    var attributes: Set<NodeFilter.Attribute> = []
    for value in splitList(values) {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        // Accept plurals too: "clones", "hardlinks".
        guard
            let attribute = NodeFilter.Attribute(rawValue: normalized)
                ?? NodeFilter.Attribute(rawValue: String(normalized.dropLast()))
        else {
            let valid = NodeFilter.Attribute.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown attribute '\(value)' for --only. Valid: \(valid).")
        }
        attributes.insert(attribute)
    }
    return attributes
}

func parseSort(_ text: String?, default lens: SizeLens, reverse: Bool) throws -> NodeSort {
    guard let text else { return NodeSort(keys: [NodeSort.Key(lens: lens)], reverse: reverse) }
    guard let keys = NodeSort.parseKeys(text) else {
        let valid = NodeSort.Key.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("Invalid --sort '\(text)'. Use comma-separated keys from: \(valid).")
    }
    return NodeSort(keys: keys, reverse: reverse)
}
