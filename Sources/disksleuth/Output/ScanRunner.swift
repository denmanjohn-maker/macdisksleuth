import ArgumentParser
import Darwin
import DiskSleuthKit
import Foundation

/// Runs a scan with a live stderr progress line (TTY only) and returns the result.
enum ScanRunner {
    static func run(path: String, options: ScanOptions = ScanOptions()) async throws -> ScanResult {
        let session: ScanSession
        do {
            session = try ScanEngine.scan(path: path, options: options)
        } catch let error as ScanError {
            switch error {
            case .notADirectory(let p):
                throw ValidationError("\(p) is not a directory — try: disksleuth info \(shellQuote(p))")
            case .openFailed(let p, let code):
                throw ValidationError("Cannot open \(p): \(errnoMessage(code))")
            default:
                throw error
            }
        }

        let showProgress = isatty(STDERR_FILENO) == 1
        let progressTask = Task {
            guard showProgress else { return }
            let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var tick = 0
            for await progress in session.progress {
                if progress.finished { break }
                tick += 1
                let path = progress.currentPath.count > 60
                    ? "…" + progress.currentPath.suffix(59)
                    : progress.currentPath
                let line = "\(spinner[tick % spinner.count]) \(progress.filesSeen.formatted()) files · "
                    + "\(ByteCount.format(progress.physicalBytes)) physical · \(path)"
                FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
            }
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        }

        let result = try await session.result.value
        _ = await progressTask.value
        return result
    }
}
