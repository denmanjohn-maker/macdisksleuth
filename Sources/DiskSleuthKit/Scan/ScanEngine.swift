import Darwin
import Foundation

/// A running scan: consume `progress` for live updates, await `result` for the
/// finished graph. Cancelling still yields a finalized (partial) graph.
public struct ScanSession: Sendable {
    public let progress: AsyncStream<ScanProgress>
    public let result: Task<ScanResult, Error>

    public func cancel() { result.cancel() }
}

/// Shared, immutable state for scanner workers.
private final class ScanContext: Sendable {
    let queue: WorkQueue
    let builder: GraphBuilder
    let visited: VisitedSet
    let allowedDevices: Set<UInt64>
    let firmlinkTargets: Set<String>
    let isRootScan: Bool
    let options: ScanOptions

    init(
        queue: WorkQueue, builder: GraphBuilder, visited: VisitedSet,
        allowedDevices: Set<UInt64>, firmlinkTargets: Set<String>,
        isRootScan: Bool, options: ScanOptions
    ) {
        self.queue = queue
        self.builder = builder
        self.visited = visited
        self.allowedDevices = allowedDevices
        self.firmlinkTargets = firmlinkTargets
        self.isRootScan = isRootScan
        self.options = options
    }
}

public enum ScanEngine {
    /// Validate the root synchronously and start the traversal. The returned
    /// session's result task finishes with a fully resolved FileGraph.
    public static func scan(path: String, options: ScanOptions = ScanOptions()) throws -> ScanSession {
        let canonical = canonicalize(path)

        let probeFD = open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard probeFD >= 0 else {
            let code = errno
            throw code == ENOTDIR
                ? ScanError.notADirectory(path: canonical)
                : ScanError.openFailed(path: canonical, code: code)
        }
        var rootStat = stat()
        fstat(probeFD, &rootStat)
        close(probeFD)

        raiseFileDescriptorLimit()

        let volume = (try? VolumeService.identity(ofPath: canonical))
            ?? VolumeIdentity(
                mountPoint: "/", fsTypeName: "unknown", deviceName: "", isReadOnly: false,
                usedBytes: 0, totalBytes: 0)

        var allowedDevices: Set<UInt64> = [deviceID(rootStat.st_dev)]
        let isRootScan = canonical == "/"
        var firmlinkTargets: Set<String> = []
        if isRootScan {
            var dataStat = stat()
            if stat("/System/Volumes/Data", &dataStat) == 0 {
                allowedDevices.insert(deviceID(dataStat.st_dev))
            }
            firmlinkTargets = Firmlinks.targetsRelativeToDataVolume()
        }

        let builder = GraphBuilder()
        let queue = WorkQueue()
        let context = ScanContext(
            queue: queue, builder: builder, visited: VisitedSet(),
            allowedDevices: allowedDevices, firmlinkTargets: firmlinkTargets,
            isRootScan: isRootScan, options: options)

        let (progressStream, progressContinuation) = AsyncStream.makeStream(of: ScanProgress.self)

        let resultTask = Task<ScanResult, Error> {
            let start = ContinuousClock.now

            let rootID = await builder.addRoot(name: canonical)
            await queue.push([
                DirWork(nodeID: rootID, parent: nil, name: canonical, path: canonical, dataRelativePath: nil)
            ])

            let progressTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { break }
                    progressContinuation.yield(await builder.progress())
                }
            }

            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<max(options.maxConcurrency, 1) {
                        group.addTask {
                            while !Task.isCancelled, let work = await context.queue.next() {
                                await processDirectory(work, context: context)
                                await context.queue.complete()
                            }
                        }
                    }
                }
            } onCancel: {
                Task { await queue.cancelAll() }
            }

            await queue.cancelAll()
            progressTask.cancel()

            let wall = Double(start.duration(to: .now).components.seconds)
                + Double(start.duration(to: .now).components.attoseconds) / 1e18
            let graph = await builder.finalize(
                rootPath: canonical, partial: Task.isCancelled, wallSeconds: wall)

            var finalProgress = await builder.progress()
            finalProgress.finished = true
            progressContinuation.yield(finalProgress)
            progressContinuation.finish()

            return ScanResult(graph: graph, volume: volume)
        }

        return ScanSession(progress: progressStream, result: resultTask)
    }

    // MARK: - Worker

    private static func processDirectory(_ work: DirWork, context: ScanContext) async {
        let fd: CInt
        if let parent = work.parent {
            fd = openat(parent.fd, work.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            parent.release()
        } else {
            fd = open(work.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let code = errno
            if code == EPERM || code == EACCES {
                await context.builder.markDenied(node: work.nodeID, path: work.path, code: code)
            }
            await context.builder.dirFinished(path: work.path)
            return
        }

        var status = stat()
        guard fstat(fd, &status) == 0 else {
            close(fd)
            await context.builder.dirFinished(path: work.path)
            return
        }
        let device = deviceID(status.st_dev)

        guard context.allowedDevices.contains(device) || context.options.crossVolumes else {
            close(fd)
            await context.builder.markOtherVolume(node: work.nodeID)
            await context.builder.dirFinished(path: work.path)
            return
        }
        guard context.visited.markVisited(device: device, inode: UInt64(status.st_ino)) else {
            close(fd)
            await context.builder.markDuplicate(node: work.nodeID)
            await context.builder.dirFinished(path: work.path)
            return
        }

        let handle = DirHandle(fd: fd, initialRefs: 1)
        let lister = DirectoryLister(fd: fd, preferFallback: context.options.forceFallback)

        while !Task.isCancelled {
            let batch: [RawEntry]
            do {
                batch = try lister.nextBatch()
            } catch {
                if let code = error.errnoCode, code == EPERM || code == EACCES {
                    await context.builder.markDenied(node: work.nodeID, path: work.path, code: code)
                }
                break
            }
            if batch.isEmpty { break }

            let ids = await context.builder.addChildren(
                parent: work.nodeID, device: device, entries: batch)

            var subdirectories: [DirWork] = []
            for (index, entry) in batch.enumerated() where entry.isDirectory {
                if entry.isDataless {
                    // Opening a dataless directory can trigger a File Provider
                    // download; record it as-is and never descend.
                    continue
                }
                let childPath = work.path == "/" ? "/" + entry.name : work.path + "/" + entry.name

                var childDataRel: String? = nil
                if let rel = work.dataRelativePath {
                    let childRel = rel.isEmpty ? entry.name : rel + "/" + entry.name
                    if context.firmlinkTargets.contains(childRel) {
                        await context.builder.markFirmlinkSkipped(node: ids[index])
                        continue
                    }
                    childDataRel = childRel
                } else if context.isRootScan && childPath == "/System/Volumes/Data" {
                    childDataRel = ""
                }

                handle.retain()
                subdirectories.append(
                    DirWork(
                        nodeID: ids[index], parent: handle, name: entry.name,
                        path: childPath, dataRelativePath: childDataRel))
            }
            if !subdirectories.isEmpty {
                await context.queue.push(subdirectories)
            }
        }

        if lister.usedFallback {
            await context.builder.markUsedFallback()
        }
        handle.release()
        await context.builder.dirFinished(path: work.path)
    }

    // MARK: - Helpers

    private static func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBytes { raw in
            realpath(expanded, raw.baseAddress?.assumingMemoryBound(to: CChar.self)) != nil
        }
        if resolved {
            return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return expanded
    }

    private static func raiseFileDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return }
        let target: rlim_t = 32768
        if limits.rlim_cur < target {
            limits.rlim_cur = min(target, limits.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limits)
        }
    }
}
