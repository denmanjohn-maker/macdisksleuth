import ArgumentParser
import Foundation
import MacDiskSleuthKit

@main
struct MacDiskSleuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macdisksleuth",
        abstract: "The disk analyzer that tells you the truth on APFS.",
        version: MacDiskSleuthVersion.string,
        subcommands: [
            Scan.self, Top.self, Info.self, Overview.self, Snapshots.self,
            Schedule.self, Export.self, Diff.self, WhatIf.self, Cleanup.self,
        ]
    )
}
