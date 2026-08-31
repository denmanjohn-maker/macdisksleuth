import ArgumentParser
import DiskSleuthKit
import Foundation

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Truth card for one file or folder: real sizes, clones, and what deleting frees."
    )

    @Argument(help: "Path to inspect.")
    var path: String

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors.")
    var noColor = false

    @Flag(name: .customLong("si"), help: "Use binary units (GiB) instead of decimal (GB).")
    var binaryUnits = false

    func run() async throws {
        let resolved = (path as NSString).expandingTildeInPath
        let readResult = Result { try SingleItemReader.read(path: resolved) }
        let item: ItemInfo
        switch readResult {
        case .success(let value):
            item = value
        case .failure(let error):
            if let scanError = error as? ScanError, case .openFailed(let p, let code) = scanError {
                throw ValidationError("Cannot read \(p): \(errnoMessage(code))")
            }
            throw error
        }

        // Snapshot presence changes what "freeable" means; fetch quietly, best-effort.
        let snapshots = (try? await VolumeService.snapshots(ofVolume: item.volumeMountPoint)) ?? []

        if json {
            try printJSON(item: item, snapshotCount: snapshots.count)
        } else {
            printCard(item: item, snapshotCount: snapshots.count)
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCount.format(bytes, binary: binaryUnits)
    }

    private func printCard(item: ItemInfo, snapshotCount: Int) {
        let style = Style(noColor: noColor)
        let e = item.entry

        let kind: String =
            e.isDirectory ? "directory" : e.isSymlink ? "symlink" : e.isRegularFile ? "file" : "special"

        var badges: [String] = []
        if e.maySharesBlocks { badges.append("⧉ clone") }
        if e.isSparse { badges.append("▤ sparse") }
        if e.linkCount > 1 && !e.isDirectory { badges.append("⛓ hardlink ×\(e.linkCount)") }
        if e.isDataless { badges.append("☁ dataless") }
        if e.isCompressed { badges.append("▣ compressed") }
        if e.isPurgeable { badges.append("♻ purgeable") }

        print(style.boldBlue(item.path))
        var meta = "\(kind) on \(item.volumeFSType) (\(item.volumeMountPoint))"
        if !badges.isEmpty { meta += "   " + badges.joined(separator: "  ") }
        print(style.dim(meta))
        print()

        if e.isDirectory {
            print("Directories carry no size of their own — run:")
            print(style.cyan("  disksleuth scan \(shellQuote(item.path))"))
            return
        }

        let rows: [(String, String, String)] = [
            ("logical", fmt(max(e.logical, 0)), "what the file claims to be"),
            ("physical", fmt(max(e.physical, 0)), "what the disk actually holds"),
            ("freeable now", fmt(item.freeableNow), "what deleting this really gives back"),
        ]
        for (label, value, note) in rows {
            let paddedLabel = label.padding(toLength: 14, withPad: " ", startingAt: 0)
            let paddedValue = value.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(paddedLabel)\(style.bold(paddedValue))\(style.dim(note))")
        }
        print()

        if e.linkCount > 1 {
            print(
                "  \(style.yellow("⛓")) \(e.linkCount) hard links share this content — "
                    + "deleting one path frees nothing until all links are gone.")
        }
        if e.maySharesBlocks {
            let saved = max(e.physical, 0) - max(e.privateSize, 0)
            var line =
                "  \(style.yellow("⧉")) Shares \(fmt(max(saved, 0))) with clones (APFS copy-on-write"
            if e.cloneRefcnt > 1 { line += ", \(e.cloneRefcnt) files in family" }
            line += ")."
            print(line)
        }
        if e.isDataless {
            print("  \(style.cyan("☁")) Content lives in the cloud; deleting frees almost nothing locally.")
        }
        if snapshotCount > 0 {
            print(
                style.dim(
                    "  ◷ \(snapshotCount) local Time Machine snapshot\(snapshotCount == 1 ? "" : "s") exist — "
                        + "freed space may appear gradually as snapshots thin."))
        }

        let headline = "Deleting frees ~\(fmt(item.freeableNow)) now"
        print()
        print("  " + style.bold(style.green(headline)))
    }

    private func printJSON(item: ItemInfo, snapshotCount: Int) throws {
        struct Payload: Codable {
            var schemaVersion = 1
            var path: String
            var kind: String
            var volume: String
            var filesystem: String
            var logical: Int64
            var physical: Int64
            var freeableNow: Int64
            var linkCount: UInt32
            var isClone: Bool
            var cloneFamilySize: UInt32?
            var isSparse: Bool
            var isDataless: Bool
            var isCompressed: Bool
            var isPurgeable: Bool
            var localSnapshots: Int
        }
        let e = item.entry
        let payload = Payload(
            path: item.path,
            kind: e.isDirectory ? "directory" : e.isSymlink ? "symlink" : "file",
            volume: item.volumeMountPoint,
            filesystem: item.volumeFSType,
            logical: max(e.logical, 0),
            physical: max(e.physical, 0),
            freeableNow: item.freeableNow,
            linkCount: e.linkCount,
            isClone: e.maySharesBlocks,
            cloneFamilySize: e.cloneRefcnt > 0 ? e.cloneRefcnt : nil,
            isSparse: e.isSparse,
            isDataless: e.isDataless,
            isCompressed: e.isCompressed,
            isPurgeable: e.isPurgeable,
            localSnapshots: snapshotCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }
}

func errnoMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}

func shellQuote(_ path: String) -> String {
    path.contains(where: { " \"'\\$`!*?[](){}<>|&;".contains($0) })
        ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        : path
}
