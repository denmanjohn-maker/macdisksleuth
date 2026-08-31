import DiskSleuthKit
import Testing

@Test func versionIsNonEmpty() {
    #expect(!DiskSleuthVersion.string.isEmpty)
}
