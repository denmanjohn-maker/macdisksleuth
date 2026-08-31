import Darwin
import Foundation

/// Builds REAL filesystem fixtures — clones via clonefile(2), hard links,
/// sparse files — in a temporary directory, so engine numbers can be asserted
/// against ground truth the kernel itself reports.
public final class FixtureTree {
    public let root: URL

    public init(name: String = "disksleuth-fixture") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    public var rootPath: String { root.path }

    public func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    @discardableResult
    public func directory(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Random-content file (random defeats transparent compression concerns
    /// and guarantees clones share no blocks with anything else).
    @discardableResult
    public func file(_ relative: String, size: Int) throws -> String {
        let target = path(relative)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, size)
        }
        try data.write(to: URL(fileURLWithPath: target))
        return target
    }

    /// APFS copy-on-write clone.
    @discardableResult
    public func clone(of source: String, at relative: String) throws -> String {
        let target = path(relative)
        guard clonefile(source, target, 0) == 0 else {
            throw FixtureError.syscall("clonefile", errno)
        }
        return target
    }

    @discardableResult
    public func hardlink(of source: String, at relative: String) throws -> String {
        let target = path(relative)
        guard link(source, target) == 0 else {
            throw FixtureError.syscall("link", errno)
        }
        return target
    }

    /// File with `dataBytes` of real content followed by a hole up to `logicalSize`.
    @discardableResult
    public func sparse(_ relative: String, dataBytes: Int, logicalSize: Int) throws -> String {
        let target = path(relative)
        let fd = open(target, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FixtureError.syscall("open", errno) }
        defer { close(fd) }
        var data = [UInt8](repeating: 0, count: dataBytes)
        arc4random_buf(&data, dataBytes)
        guard write(fd, data, dataBytes) == dataBytes else {
            throw FixtureError.syscall("write", errno)
        }
        guard ftruncate(fd, off_t(logicalSize)) == 0 else {
            throw FixtureError.syscall("ftruncate", errno)
        }
        return target
    }

    /// Overwrite a range of an existing file (diverges a clone).
    public func overwrite(_ relative: String, offset: Int, length: Int) throws {
        let fd = open(path(relative), O_WRONLY)
        guard fd >= 0 else { throw FixtureError.syscall("open", errno) }
        defer { close(fd) }
        var data = [UInt8](repeating: 0, count: length)
        arc4random_buf(&data, length)
        guard pwrite(fd, data, length, off_t(offset)) == length else {
            throw FixtureError.syscall("pwrite", errno)
        }
        // APFS reports unsettled PRIVATESIZE for freshly CoW-diverged extents
        // until they hit disk; flush so the test observes steady-state truth.
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw FixtureError.syscall("fsync", errno)
        }
    }

    public func removeReadPermission(_ relative: String) throws {
        guard chmod(path(relative), 0) == 0 else { throw FixtureError.syscall("chmod", errno) }
    }

    public func restoreReadPermission(_ relative: String) throws {
        guard chmod(path(relative), 0o755) == 0 else { throw FixtureError.syscall("chmod", errno) }
    }

    /// st_blocks-based physical size of one item, straight from the kernel.
    public func physicalSize(_ relative: String) throws -> Int64 {
        var status = stat()
        guard lstat(path(relative), &status) == 0 else { throw FixtureError.syscall("lstat", errno) }
        return Int64(status.st_blocks) * 512
    }

    /// Whether the volume hosting the fixtures supports cloning (skip clone
    /// tests gracefully on exotic CI mounts).
    public static func volumeSupportsCloning(at path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let fsType = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return fsType == "apfs"
    }
}

public enum FixtureError: Error {
    case syscall(String, Int32)
}
