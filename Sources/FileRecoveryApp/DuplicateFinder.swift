import CryptoKit
import Foundation

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: UInt64
    let modified: Date?
    var id: URL { url }
}

/// Files with byte-for-byte identical contents.
struct DuplicateGroup: Identifiable, Hashable, Sendable {
    /// SHA-256 of the contents.
    let id: String
    let size: UInt64
    var files: [DuplicateFile]

    /// Space freed by keeping one copy.
    var reclaimableBytes: UInt64 { size * UInt64(max(0, files.count - 1)) }
}

struct DuplicateProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case listing, comparing }
    var phase: Phase = .listing
    var filesListed = 0
    var bytesCompared: UInt64 = 0
    var bytesToCompare: UInt64 = 0

    var fraction: Double? {
        guard phase == .comparing, bytesToCompare > 0 else { return nil }
        return min(1, Double(bytesCompared) / Double(bytesToCompare))
    }
}

struct DuplicateScanResult: Sendable {
    var groups: [DuplicateGroup] = []
    var filesExamined = 0
    /// Files that could not be read, so could not be compared.
    var unreadable = 0
}

/// Finds exact duplicates in three passes, each cheaper than the next would
/// be on its own: group by size (no reads), then by a hash of the first 4 KB,
/// then by a SHA-256 of the whole file. Only the last pass decides: two files
/// are reported as duplicates only when every byte matches.
struct DuplicateFinder: Sendable {
    private let prefixLength = 4096
    private let chunkSize = 1024 * 1024

    func find(
        in roots: [URL],
        minimumSize: UInt64 = 1,
        progress: @escaping @Sendable (DuplicateProgress) async -> Void
    ) async throws -> DuplicateScanResult {
        var result = DuplicateScanResult()
        var state = DuplicateProgress()
        var lastReport = Date.distantPast

        // Pass 1: list files and group by size.
        var bySize: [UInt64: [DuplicateFile]] = [:]
        // One entry per file on disk. A hard link is the same data under
        // another name, and deleting it frees nothing; overlapping folders
        // would otherwise list the same file twice and call it a duplicate.
        var seenInodes = Set<FileID>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            // Hidden files are system bookkeeping (.DS_Store). Packages (apps,
            // the Photos library) are single items to the user, and removing a
            // file from inside one breaks it.
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            // nextObject, not for-in: the enumerator's Sequence conformance is
            // unavailable in async code.
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                // Symlinks report isRegularFile false and are not followed.
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize.map(UInt64.init), size >= max(1, minimumSize),
                      let fileID = FileID(url), seenInodes.insert(fileID).inserted else { continue }
                bySize[size, default: []].append(
                    DuplicateFile(url: url, size: size, modified: values.contentModificationDate)
                )
                result.filesExamined += 1
                state.filesListed = result.filesExamined
                if Date().timeIntervalSince(lastReport) >= 0.2 {
                    lastReport = Date()
                    await progress(state)
                }
            }
        }

        let candidates = bySize.values.filter { $0.count > 1 }
        state.phase = .comparing
        state.bytesToCompare = candidates.reduce(0) { $0 + $1.reduce(0) { $0 + $1.size } }
        await progress(state)

        for sameSize in candidates {
            // Pass 2: the first 4 KB separates most same-size files for the
            // cost of one small read each.
            var byPrefix: [String: [DuplicateFile]] = [:]
            for file in sameSize {
                try Task.checkCancellation()
                guard let digest = try hash(file.url, limit: prefixLength) else {
                    result.unreadable += 1
                    state.bytesCompared += file.size
                    continue
                }
                byPrefix[digest, default: []].append(file)
            }

            for (prefixDigest, samePrefix) in byPrefix {
                guard samePrefix.count > 1 else {
                    state.bytesCompared += samePrefix.reduce(0) { $0 + $1.size }
                    continue
                }
                // Pass 3: the whole file. A file no longer than the prefix
                // has already been hashed in full.
                var byContent: [String: [DuplicateFile]] = [:]
                for file in samePrefix {
                    try Task.checkCancellation()
                    let digest = file.size <= UInt64(prefixLength) ? prefixDigest : try hash(file.url, limit: nil)
                    state.bytesCompared += file.size
                    if Date().timeIntervalSince(lastReport) >= 0.2 {
                        lastReport = Date()
                        await progress(state)
                    }
                    guard let digest else {
                        result.unreadable += 1
                        continue
                    }
                    byContent[digest, default: []].append(file)
                }
                for (digest, files) in byContent where files.count > 1 {
                    result.groups.append(DuplicateGroup(
                        id: digest,
                        size: files[0].size,
                        files: files.sorted { $0.url.path < $1.url.path }
                    ))
                }
            }
        }

        // Biggest savings first.
        result.groups.sort { ($0.reclaimableBytes, $0.id) > ($1.reclaimableBytes, $1.id) }
        state.bytesCompared = state.bytesToCompare
        await progress(state)
        return result
    }

    /// SHA-256 of the first `limit` bytes, or of the whole file when nil.
    /// Returns nil when the file cannot be read.
    private func hash(_ url: URL, limit: Int?) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            try Task.checkCancellation()
            // read(upToCount:) returns nil at end of file and throws on a
            // real failure; the two must not be confused.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(chunkSize, remaining))
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Identity of a file on disk, independent of its name.
private struct FileID: Hashable {
    let device: Int32
    let inode: UInt64

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = UInt64(info.st_ino)
    }
}
