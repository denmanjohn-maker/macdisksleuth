import ArgumentParser
import DiskSleuthKit

@main
struct Disksleuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disksleuth",
        abstract: "The disk analyzer that tells you the truth on APFS.",
        version: DiskSleuthVersion.string,
        subcommands: [Scan.self, Top.self, Info.self]
    )
}
