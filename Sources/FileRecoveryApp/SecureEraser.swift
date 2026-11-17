import Darwin
import Foundation

enum EraseError: LocalizedError, Equatable {
    case notExternal(String)
    case changed(String)
    case notMounted(String)
    case readOnly(String)
    case diskutil(String)
    case io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .notExternal(let name):
            "\(name) is not an external drive. Only external drives and cards can be erased."
        case .changed(let name):
            "\(name) is no longer the drive that was chosen. It may have been unplugged or replaced. Nothing was erased."
        case .notMounted(let name):
            "\(name) is not mounted, so its space cannot be overwritten. Reconnect it and try again."
        case .readOnly(let name):
            "macOS cannot write to \(name), so its free space cannot be overwritten. Erase the entire volume instead."
        case .diskutil(let message):
            message
        case .io(let what, let code):
            "\(what): \(String(cString: strerror(code)))"
        }
    }
}

/// The filesystem laid down by a whole-volume erase. Raw values are diskutil
/// format names.
enum EraseFormat: String, CaseIterable, Identifiable, Sendable {
    case exfat = "ExFAT"
    case fat32 = "MS-DOS FAT32"
    case hfs = "JHFS+"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exfat: "ExFAT (Mac, Windows and cameras)"
        case .fat32: "FAT32 (older cameras and devices)"
        case .hfs: "Mac OS Extended (Mac only)"
        }
    }

    /// The format closest to what the volume has now.
    static func matching(_ device: ExternalDevice) -> EraseFormat {
        let current = (device.filesystemName ?? "").lowercased()
        if current.contains("fat32") || current.contains("ms-dos") { return .fat32 }
        if current.contains("mac os extended") || current.contains("hfs") { return .hfs }
        return .exfat
    }

    /// A volume name this format accepts, as close to `name` as it allows.
    func volumeName(from name: String?) -> String {
        var result = (name ?? "").trimmingCharacters(in: .whitespaces)
        switch self {
        case .fat32:
            result = String(result.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || " _-".contains($0)) }.prefix(11))
        case .exfat:
            result = String(result.filter { !"\"*/:<>?\\|".contains($0) }.prefix(11))
        case .hfs:
            result = result.replacingOccurrences(of: ":", with: "-")
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "UNTITLED" : result
    }
}

struct EraseProgress: Sendable, Equatable {
    var done: UInt64 = 0
    var total: UInt64 = 0

    var fraction: Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }
}

struct ShredReport: Sendable, Equatable {
    var files = 0
    var bytes: UInt64 = 0
    var failures: [String] = []
}

/// Destroys data on external drives. Everything here writes zeros through the
/// mounted filesystem; the app never opens a raw device for writing.
///
/// ponytail: one pass of zeros. Extra passes add hours and nothing a
/// recovery scan can measure on any drive made this century.
enum SecureEraser {
    private static let chunkBytes = 4 * 1024 * 1024
    /// FAT32 cannot hold a file of 4 GB, so the filler is cut into pieces.
    private static let fillFileBytes: UInt64 = 1024 * 1024 * 1024
    private static let reportEvery: UInt64 = 32 * 1024 * 1024

    // MARK: - Guards

    /// Re-reads the device straight from diskutil and refuses unless it is
    /// external, is not the startup disk, and still has the size and name the
    /// user confirmed. BSD identifiers are reused: "disk4" can be a different
    /// drive from the one that was listed a minute ago.
    static func verify(_ device: ExternalDevice) throws {
        guard let info = DeviceDiscovery.diskutilPlist(["info", "-plist", "/dev/\(device.identifier)"]) else {
            throw EraseError.changed(device.userFacingName)
        }
        let parent = info["ParentWholeDisk"] as? String ?? device.wholeDiskIdentifier
        let boot = DeviceDiscovery.bsdName(forPath: "/").map { "disk" + $0.dropFirst(4).prefix(while: \.isNumber) }
        guard info["Internal"] as? Bool == false, parent != boot else {
            throw EraseError.notExternal(device.userFacingName)
        }
        let size = ((info["TotalSize"] ?? info["Size"]) as? NSNumber)?.uint64Value
        let name = info["VolumeName"] as? String ?? ""
        guard size == device.size, name == (device.volumeName ?? "") else {
            throw EraseError.changed(device.userFacingName)
        }
    }

    /// True when `url` is on a disk that diskutil reports as not internal.
    /// Network volumes and anything unidentifiable count as not external.
    static func isOnExternalDisk(_ url: URL) -> Bool {
        guard let name = DeviceDiscovery.bsdName(forPath: url.path),
              let info = DeviceDiscovery.diskutilPlist(["info", "-plist", "/dev/\(name)"]) else { return false }
        return info["Internal"] as? Bool == false
    }

    // MARK: - Free space

    /// Overwrites the free space of a mounted volume. Existing files are not
    /// touched. Throws CancellationError if the task is cancelled; the filler
    /// is removed either way.
    static func wipeFreeSpace(
        _ device: ExternalDevice,
        progress: @escaping @Sendable (EraseProgress) -> Void
    ) async throws {
        try verify(device)
        guard let mount = mountPoint(of: device) else {
            throw EraseError.notMounted(device.userFacingName)
        }
        guard access(mount.path, W_OK) == 0 else {
            throw EraseError.readOnly(device.userFacingName)
        }
        try fill(mount, progress: progress)
    }

    // MARK: - Whole volume

    /// Formats the volume, which discards everything on it, then overwrites
    /// all of the new, empty volume's space. Returns false when the overwrite
    /// was cancelled part-way: the volume is formatted and usable, but old
    /// data beyond the point reached can still be recovered.
    ///
    /// ponytail: overwrites the space files can occupy, through the
    /// filesystem, so progress is real and nothing needs raw write access.
    /// Sectors outside the data area (reserved and alignment gaps) are not
    /// touched. `diskutil zeroDisk` covers those if that is ever required,
    /// at the cost of reporting no progress.
    static func eraseVolume(
        _ device: ExternalDevice,
        format: EraseFormat,
        progress: @escaping @Sendable (EraseProgress) -> Void
    ) async throws -> Bool {
        try verify(device)
        // Never forced: if a file on the volume is open, diskutil refuses.
        try diskutil(["eraseVolume", format.rawValue, format.volumeName(from: device.volumeName), "/dev/\(device.identifier)"])
        guard let mount = mountPoint(of: device) else {
            throw EraseError.notMounted(device.userFacingName)
        }
        do {
            try fill(mount, progress: progress)
            return true
        } catch is CancellationError {
            return false
        }
    }

    // MARK: - Files

    /// Overwrites each file in place, then deletes it. Folders are emptied
    /// the same way and removed. Files that are not on an external disk are
    /// refused and reported, never touched.
    ///
    /// ponytail: in-place overwrite is only as good as the filesystem. On
    /// flash media and copy-on-write volumes (APFS snapshots, clones) the old
    /// blocks can survive; the UI says so and points to the volume erase.
    static func shred(
        _ urls: [URL],
        progress: @escaping @Sendable (EraseProgress) -> Void
    ) async throws -> ShredReport {
        var files: [(url: URL, size: UInt64)] = []
        var others: [URL] = []      // symlinks and special files: just unlinked
        var folders: [URL] = []
        var report = ShredReport()
        var externalByVolume: [dev_t: Bool] = [:]

        func add(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                report.failures.append("\(url.lastPathComponent): no longer exists.")
                return
            }
            let external = externalByVolume[info.st_dev] ?? isOnExternalDisk(url)
            externalByVolume[info.st_dev] = external
            guard external else {
                report.failures.append("\(url.lastPathComponent): not on an external drive, so it was left alone.")
                return
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG: files.append((url, UInt64(info.st_size)))
            case S_IFDIR:
                folders.append(url)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                    add(url.appendingPathComponent(name))
                }
            default: others.append(url)
            }
        }
        urls.forEach(add)

        var status = EraseProgress(total: files.reduce(0) { $0 + $1.size })
        let zeros = [UInt8](repeating: 0, count: chunkBytes)
        for file in files {
            try Task.checkCancellation()
            do {
                let fd = open(file.url.path, O_WRONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw EraseError.io("Could not open", errno) }
                defer { close(fd) }
                var remaining = file.size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let wrote = zeros.withUnsafeBytes { write(fd, $0.baseAddress, Int(min(UInt64(chunkBytes), remaining))) }
                    if wrote < 0, errno == EINTR { continue }
                    guard wrote > 0 else { throw EraseError.io("Could not overwrite", errno) }
                    remaining -= UInt64(wrote)
                    status.done += UInt64(wrote)
                    progress(status)
                }
                // Past the drive's own write cache, before the name goes.
                guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                    throw EraseError.io("Could not flush", errno)
                }
                // Renamed first so the original name is not what gets unlinked.
                let anonymous = file.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                let doomed = rename(file.url.path, anonymous.path) == 0 ? anonymous : file.url
                guard unlink(doomed.path) == 0 else { throw EraseError.io("Overwritten, but could not delete", errno) }
                report.files += 1
                report.bytes += file.size
            } catch let error as EraseError {
                report.failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for url in others where unlink(url.path) != 0 {
            report.failures.append("\(url.lastPathComponent): could not delete.")
        }
        // Deepest first. A folder that still holds a file that failed stays.
        for folder in folders.reversed() {
            rmdir(folder.path)
        }
        return report
    }

    // MARK: - Internals

    private static func mountPoint(of device: ExternalDevice) -> URL? {
        guard let info = DeviceDiscovery.diskutilPlist(["info", "-plist", "/dev/\(device.identifier)"]),
              let path = info["MountPoint"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Writes zeros into a hidden folder until the volume is full, then
    /// removes the folder.
    private static func fill(_ mount: URL, progress: @Sendable (EraseProgress) -> Void) throws {
        let folder = mount.appendingPathComponent(".rpt-erase-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw EraseError.diskutil("Could not write to \(mount.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        var fs = statfs()
        guard statfs(mount.path, &fs) == 0 else { throw EraseError.io("Could not read free space", errno) }
        var status = EraseProgress(total: UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
        progress(status)

        let zeros = [UInt8](repeating: 0, count: chunkBytes)
        var index = 0
        var full = false
        while !full {
            let fd = open(folder.appendingPathComponent("\(index)").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd < 0 {
                if errno == ENOSPC { break }
                throw EraseError.io("Could not create the filler file", errno)
            }
            defer { close(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
            var inFile: UInt64 = 0
            var chunk = chunkBytes
            while inFile < fillFileBytes {
                try Task.checkCancellation()
                let want = Int(min(UInt64(chunk), fillFileBytes - inFile))
                let wrote = zeros.withUnsafeBytes { write(fd, $0.baseAddress, want) }
                if wrote > 0 {
                    let before = status.done
                    inFile += UInt64(wrote)
                    status.done += UInt64(wrote)
                    if before / reportEvery != status.done / reportEvery { progress(status) }
                    continue
                }
                if wrote < 0, errno == EINTR { continue }
                guard wrote == 0 || errno == ENOSPC || errno == EDQUOT else {
                    throw EraseError.io("Could not overwrite free space", errno)
                }
                // A big write can fail with room still left for a small one.
                if chunk > 4096 {
                    chunk = 4096
                    continue
                }
                full = true
                break
            }
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
                throw EraseError.io("Could not flush to the drive", errno)
            }
            index += 1
        }
        status.done = max(status.done, status.total)
        progress(status)
    }

    private static func diskutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw EraseError.diskutil("Could not run diskutil: \(error.localizedDescription)")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let last = output.split(separator: "\n").last.map(String.init) ?? "diskutil failed."
            throw EraseError.diskutil(last)
        }
    }
}
