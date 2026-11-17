import Darwin
import Foundation

enum ImagingError: LocalizedError, Equatable {
    case sameDisk
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case fileTooLarge
    case cannotCreate(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sameDisk:
            "The image cannot be saved on the drive being copied. Choose a different drive."
        case .notEnoughSpace(let needed, let available):
            "The image needs \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)) but only \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)) is free there. Choose a drive with more room."
        case .fileTooLarge:
            "That drive is formatted as FAT32, which cannot hold a file this large. Choose a drive formatted as ExFAT, APFS or Mac OS Extended."
        case .cannotCreate(let reason):
            "The image file could not be created: \(reason)"
        case .writeFailed(let reason):
            "Writing the image failed: \(reason). The part copied so far was kept."
        }
    }
}

struct ImagingProgress: Sendable, Equatable {
    var done: UInt64 = 0
    var total: UInt64 = 0
    var unreadableBytes: UInt64 = 0

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

struct ImagingResult: Sendable, Equatable {
    var copied: UInt64
    var total: UInt64
    var unreadableBytes: UInt64
    /// Nil when the whole drive was copied. Otherwise why it stopped early;
    /// the part copied so far is kept either way and can still be scanned.
    var stoppedBecause: String?
}

/// Copies a drive, byte for byte, into one file. A failing drive is then read
/// only once: recovery works on the copy, however many scans that takes.
/// The drive itself is opened read-only.
enum DriveImager {
    private static let chunkBytes = 4 * 1024 * 1024

    /// Refuses a destination that is on the drive being copied, has too
    /// little room, or cannot hold a file this size.
    static func checkDestination(_ url: URL, for device: ExternalDevice) throws {
        let folder = url.deletingLastPathComponent()
        guard !DeviceDiscovery.destination(folder, isOnSameDiskAs: device) else { throw ImagingError.sameDisk }
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else {
            throw ImagingError.cannotCreate(String(cString: strerror(errno)))
        }
        let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        if type == "msdos", device.size >= 4 * 1024 * 1024 * 1024 { throw ImagingError.fileTooLarge }
        // An image being replaced gives its space back.
        let replaced = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let available = UInt64(fs.f_bavail) * UInt64(fs.f_bsize) + replaced
        guard available >= device.size else {
            throw ImagingError.notEnoughSpace(needed: device.size, available: available)
        }
    }

    /// Copies `source` to `url`, replacing any file there. Unreadable blocks
    /// are written as zeros and counted. Stopping, or losing the source
    /// part-way, returns what was copied; only a destination failure throws.
    ///
    /// ponytail: a stopped copy starts over next time. Resuming from the
    /// partial file's length is the upgrade if people image very large,
    /// very slow drives.
    static func copy(
        _ source: ScanSource,
        to url: URL,
        progress: @escaping @Sendable (ImagingProgress) -> Void
    ) async throws -> ImagingResult {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw ImagingError.cannotCreate(String(cString: strerror(errno))) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var status = ImagingProgress(total: source.size)
        var stopped: String?
        progress(status)
        while status.done < source.size {
            if Task.isCancelled {
                stopped = "The copy was stopped."
                break
            }
            let data: Data
            do {
                data = try source.read(at: status.done, count: chunkBytes)
            } catch {
                stopped = "The drive stopped responding. It may have been unplugged."
                break
            }
            guard !data.isEmpty else { break }
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let n = write(fd, raw.baseAddress! + written, raw.count - written)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw ImagingError.writeFailed(String(cString: strerror(errno))) }
                    written += n
                }
            }
            status.done += UInt64(data.count)
            status.unreadableBytes = source.unreadableBytes
            progress(status)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw ImagingError.writeFailed(String(cString: strerror(errno)))
        }
        return ImagingResult(
            copied: status.done,
            total: source.size,
            unreadableBytes: source.unreadableBytes,
            stoppedBecause: stopped
        )
    }
}
