import CryptoKit
import Darwin
import Foundation

enum CopyError: LocalizedError, Equatable {
    case sameVolume(String)
    case notWritable(String)
    case notEnoughSpace(String, needed: UInt64, available: UInt64)
    case nothingToCopy
    case cannotCreate(String)

    var errorDescription: String? {
        switch self {
        case .sameVolume(let name):
            "\(name) is on the same drive as the files being copied. A copy on the same drive does not protect them; choose a different drive."
        case .notWritable(let name):
            "Files cannot be saved in \(name). Choose a different folder."
        case .notEnoughSpace(let name, let needed, let available):
            "\(name) has \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)) free but the copy needs \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file))."
        case .nothingToCopy:
            "There are no files to copy in that folder."
        case .cannotCreate(let reason):
            "The destination folder could not be created: \(reason)"
        }
    }
}

struct CopyProgress: Sendable, Equatable {
    var done: UInt64 = 0
    var total: UInt64 = 0
    var filesDone = 0
    var fileCount = 0
    var currentFile = ""

    var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
}

struct CopyReport: Sendable, Equatable {
    var fileCount = 0
    /// Files that reached every destination and read back identical.
    var verified = 0
    var bytes: UInt64 = 0
    /// The new folder made in each destination.
    var folders: [URL] = []
    var failures: [String] = []
    var stopped = false

    /// The only state in which the original can be erased.
    var everythingVerified: Bool {
        !stopped && failures.isEmpty && fileCount > 0 && verified == fileCount
    }
}

/// Copies a folder (typically a camera card) to one or more destinations and
/// proves each copy: every file is hashed as it is read from the source,
/// then each written copy is read back from its drive and compared.
enum VerifiedCopier {
    static let manifestName = "SHA256SUMS.txt"
    private static let chunkBytes = 4 * 1024 * 1024

    /// Refuses destinations that cannot be written or that sit on the same
    /// volume as the source.
    static func checkDestinations(_ destinations: [URL], source: URL) throws {
        let sourceVolume = mountPoint(of: source)
        for destination in destinations {
            guard access(destination.path, W_OK) == 0 else {
                throw CopyError.notWritable(destination.lastPathComponent)
            }
            guard sourceVolume == nil || mountPoint(of: destination) != sourceVolume else {
                throw CopyError.sameVolume(destination.lastPathComponent)
            }
        }
    }

    private static func mountPoint(of url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }

    /// Copies everything under `source` into a new folder, `folderName`,
    /// inside each destination. One bad file is reported and the rest carry
    /// on. `afterWrite` is a test hook, called once a copy is on disk and
    /// before it is read back.
    ///
    /// ponytail: hidden files and symlinks are not copied; on a camera card
    /// those are Finder and Spotlight leftovers. The read-back turns the
    /// file cache off, which is as close to "from the drive" as an app gets
    /// without unmounting it.
    static func copy(
        from source: URL,
        to destinations: [URL],
        folderName: String,
        afterWrite: (@Sendable (URL) -> Void)? = nil,
        progress: @escaping @Sendable (CopyProgress) -> Void
    ) async throws -> CopyReport {
        // List first, so the total is known and space can be checked.
        var files: [(path: String, size: UInt64)] = []
        let root = source.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            files.append((String(path.dropFirst(root.count + 1)), UInt64(values.fileSize ?? 0)))
        }
        guard !files.isEmpty else { throw CopyError.nothingToCopy }
        files.sort { $0.path < $1.path }
        let bytes = files.reduce(0) { $0 + $1.size }

        var report = CopyReport(fileCount: files.count)
        for destination in destinations {
            var fs = statfs()
            if statfs(destination.path, &fs) == 0 {
                let available = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
                guard available >= bytes else {
                    throw CopyError.notEnoughSpace(destination.lastPathComponent, needed: bytes, available: available)
                }
            }
            var folder = destination.appendingPathComponent(folderName, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = destination.appendingPathComponent("\(folderName) \(suffix)", isDirectory: true)
                suffix += 1
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch {
                throw CopyError.cannotCreate(error.localizedDescription)
            }
            report.folders.append(folder)
        }

        // One read of the source, then one read-back per destination.
        var status = CopyProgress(total: bytes * UInt64(1 + destinations.count), fileCount: files.count)
        var manifest = ""
        var buffer = [UInt8](repeating: 0, count: chunkBytes)

        for file in files {
            if Task.isCancelled {
                report.stopped = true
                break
            }
            status.currentFile = file.path
            progress(status)
            let before = status.done
            let sourceURL = source.appendingPathComponent(file.path)
            let targets = report.folders.map { $0.appendingPathComponent(file.path) }
            var problem: String?

            // Copy, hashing what was read.
            var hasher = SHA256()
            let input = open(sourceURL.path, O_RDONLY)
            var outputs: [Int32] = []
            if input < 0 {
                problem = "could not be read (\(String(cString: strerror(errno))))"
            } else {
                for target in targets where problem == nil {
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                    if fd < 0 {
                        problem = "could not be created on \(target.deletingLastPathComponent().path) (\(String(cString: strerror(errno))))"
                    } else {
                        _ = fcntl(fd, F_NOCACHE, 1)
                        outputs.append(fd)
                    }
                }
            }
            while problem == nil, !Task.isCancelled {
                let got = read(input, &buffer, chunkBytes)
                if got < 0, errno == EINTR { continue }
                if got < 0 { problem = "could not be read (\(String(cString: strerror(errno))))" }
                guard got > 0 else { break }
                buffer.withUnsafeBytes { raw in
                    let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<got])
                    hasher.update(bufferPointer: chunk)
                    for fd in outputs where problem == nil {
                        var written = 0
                        while written < got {
                            let n = write(fd, chunk.baseAddress! + written, got - written)
                            if n < 0, errno == EINTR { continue }
                            guard n > 0 else {
                                problem = "could not be written (\(String(cString: strerror(errno))))"
                                break
                            }
                            written += n
                        }
                    }
                }
                status.done += UInt64(got)
                progress(status)
            }
            if input >= 0 { close(input) }
            for fd in outputs {
                if problem == nil, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
                    problem = "could not be flushed to the drive (\(String(cString: strerror(errno))))"
                }
                close(fd)
            }
            if Task.isCancelled {
                // Half a file is worse than no file.
                targets.forEach { try? FileManager.default.removeItem(at: $0) }
                report.stopped = true
                break
            }

            // Read each copy back and compare.
            let expected = hasher.finalize()
            if problem == nil {
                let dates = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
                for target in targets where problem == nil {
                    afterWrite?(target)
                    var check = SHA256()
                    let fd = open(target.path, O_RDONLY)
                    guard fd >= 0 else {
                        problem = "could not be read back"
                        break
                    }
                    _ = fcntl(fd, F_NOCACHE, 1)
                    while true {
                        let got = read(fd, &buffer, chunkBytes)
                        if got < 0, errno == EINTR { continue }
                        if got < 0 { problem = "could not be read back (\(String(cString: strerror(errno))))" }
                        guard got > 0 else { break }
                        buffer.withUnsafeBytes { check.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<got])) }
                        status.done += UInt64(got)
                        progress(status)
                    }
                    close(fd)
                    if problem == nil, check.finalize() != expected {
                        problem = "the copy does not match the original"
                    }
                    var attributes: [FileAttributeKey: Any] = [:]
                    attributes[.creationDate] = dates?[.creationDate]
                    attributes[.modificationDate] = dates?[.modificationDate]
                    try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
                }
            }

            if let problem {
                report.failures.append("\(file.path): \(problem).")
            } else {
                report.verified += 1
                report.bytes += file.size
                manifest += expected.map { String(format: "%02x", $0) }.joined() + "  " + file.path + "\n"
            }
            status.filesDone += 1
            // Keep the bar honest when a file was cut short or grew.
            status.done = max(status.done, min(status.total, before + file.size * UInt64(1 + destinations.count)))
        }

        // `shasum -a 256 -c SHA256SUMS.txt`, run inside the folder, re-checks
        // the copy at any later date.
        for folder in report.folders where !manifest.isEmpty {
            try? manifest.write(to: folder.appendingPathComponent(manifestName), atomically: true, encoding: .utf8)
        }
        progress(status)
        return report
    }
}
