import Foundation

/// Small async wrapper around Process for shelling out to diskutil/tmutil.
enum Subprocess {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: Duration = .seconds(20)
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Arm the exit signal before launching so termination can never race it.
        let exitStatus = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        try process.run()

        async let stdoutData = readAll(outPipe.fileHandleForReading)
        async let stderrData = readAll(errPipe.fileHandleForReading)

        let killer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled && process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await value in exitStatus {
            status = value
            break
        }
        killer.cancel()

        return await Output(status: status, stdout: stdoutData, stderr: stderrData)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}
