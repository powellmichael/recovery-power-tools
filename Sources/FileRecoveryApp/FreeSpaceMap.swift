import Foundation

/// A deleted file's directory entry: original name and exact size, keyed by
/// the byte offset where its data starts.
struct DeletedFileEntry: Sendable, Equatable {
    let name: String
    let length: UInt64
    /// Disk byte ranges holding the data when the file was fragmented
    /// (NTFS data runs); nil means a single contiguous range at the key offset.
    var segments: [Range<UInt64>]? = nil
}

/// Free (unallocated) byte regions of a volume. Anything carved from these
/// regions is by definition deleted data, not a live file.
struct FreeSpaceMap: Sendable {
    let filesystem: String
    let regions: [Range<UInt64>]
    var deletedFiles: [UInt64: DeletedFileEntry] = [:]

    var freeBytes: UInt64 {
        regions.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Returns nil when the filesystem is not recognized (caller falls back to
    /// carving the whole device).
    static func read(from source: ScanSource) throws -> FreeSpaceMap? {
        let boot = [UInt8](try source.read(at: 0, count: 512))
        guard boot.count == 512 else { return nil }

        if matchASCII(boot, at: 3, "EXFAT   ") {
            return try exfat(source, boot: boot)
        }
        if matchASCII(boot, at: 3, "NTFS    ") {
            return try NTFS.map(source, boot: boot)
        }
        if matchASCII(boot, at: 82, "FAT32   ") {
            return try fat32(source, boot: boot)
        }
        return nil
    }

    // MARK: - FAT32

    static func fat32(_ source: ScanSource, boot: [UInt8]) throws -> FreeSpaceMap? {
        let bytesPerSector = UInt64(le16(boot, 11))
        let sectorsPerCluster = UInt64(boot[13])
        let reservedSectors = UInt64(le16(boot, 14))
        let fatCount = UInt64(boot[16])
        let totalSectors = le32(boot, 32) != 0 ? UInt64(le32(boot, 32)) : UInt64(le16(boot, 19))
        let sectorsPerFAT = UInt64(le32(boot, 36))
        guard bytesPerSector > 0, sectorsPerCluster > 0, fatCount > 0, sectorsPerFAT > 0,
              totalSectors > reservedSectors + fatCount * sectorsPerFAT else { return nil }

        let fatStart = reservedSectors * bytesPerSector
        let dataStartSector = reservedSectors + fatCount * sectorsPerFAT
        let dataStart = dataStartSector * bytesPerSector
        let clusterBytes = sectorsPerCluster * bytesPerSector
        let clusterCount = (totalSectors - dataStartSector) / sectorsPerCluster

        var freeClusters: [Bool] = []
        freeClusters.reserveCapacity(Int(clusterCount))
        // FAT entries are 4 bytes; entry N describes cluster N. Clusters start at 2.
        let firstEntryOffset = fatStart + 2 * 4
        let totalFATBytes = clusterCount * 4
        var offset: UInt64 = 0
        while offset < totalFATBytes {
            let want = Int(min(UInt64(4 * 1024 * 1024), totalFATBytes - offset))
            let chunk = [UInt8](try source.read(at: firstEntryOffset + offset, count: want))
            guard !chunk.isEmpty else { break }
            var i = 0
            while i + 4 <= chunk.count {
                let entry = le32(chunk, i) & 0x0FFF_FFFF
                freeClusters.append(entry == 0)
                i += 4
            }
            offset += UInt64(chunk.count)
        }

        let regions = mergedRegions(freeClusters: freeClusters, dataStart: dataStart, clusterBytes: clusterBytes, deviceSize: source.size)
        return FreeSpaceMap(filesystem: "FAT32", regions: regions)
    }

    // MARK: - exFAT

    static func exfat(_ source: ScanSource, boot: [UInt8]) throws -> FreeSpaceMap? {
        let bytesPerSectorShift = boot[108]
        let sectorsPerClusterShift = boot[109]
        guard bytesPerSectorShift >= 9, bytesPerSectorShift <= 12, sectorsPerClusterShift <= 25 else { return nil }
        let bytesPerSector = UInt64(1) << bytesPerSectorShift
        let clusterBytes = bytesPerSector << sectorsPerClusterShift
        let clusterHeapOffset = UInt64(le32(boot, 88))
        let clusterCount = UInt64(le32(boot, 92))
        let rootDirCluster = UInt64(le32(boot, 96))
        guard clusterCount > 0, rootDirCluster >= 2 else { return nil }

        let heapStart = clusterHeapOffset * bytesPerSector
        func clusterAddress(_ n: UInt64) -> UInt64 { heapStart + (n - 2) * clusterBytes }

        // ponytail: read only the first cluster of the root directory; the
        // allocation bitmap entry is virtually always there. Follow the FAT
        // chain if this ever misses.
        let rootDir = [UInt8](try source.read(at: clusterAddress(rootDirCluster), count: Int(min(clusterBytes, 1 << 20))))
        var bitmapCluster: UInt64 = 0
        var bitmapLength: UInt64 = 0
        var entry = 0
        while entry + 32 <= rootDir.count {
            if rootDir[entry] == 0x81 {
                bitmapCluster = UInt64(le32(rootDir, entry + 20))
                bitmapLength = le64(rootDir, entry + 24)
                break
            }
            if rootDir[entry] == 0x00 { break }
            entry += 32
        }
        guard bitmapCluster >= 2, bitmapLength > 0 else { return nil }

        // ponytail: assume the bitmap file is contiguous (it nearly always is).
        let neededBytes = min(bitmapLength, (clusterCount + 7) / 8)
        let bitmap = [UInt8](try source.read(at: clusterAddress(bitmapCluster), count: Int(neededBytes)))
        guard !bitmap.isEmpty else { return nil }

        var freeClusters: [Bool] = []
        freeClusters.reserveCapacity(Int(clusterCount))
        for index in 0..<Int(clusterCount) {
            let byte = index / 8
            guard byte < bitmap.count else { break }
            freeClusters.append(bitmap[byte] & (1 << (index % 8)) == 0)
        }

        let regions = mergedRegions(freeClusters: freeClusters, dataStart: heapStart, clusterBytes: clusterBytes, deviceSize: source.size)
        let deletedFiles = (try? exfatDeletedFiles(
            source,
            boot: boot,
            bytesPerSector: bytesPerSector,
            clusterBytes: clusterBytes,
            heapStart: heapStart,
            clusterCount: clusterCount,
            rootDirCluster: rootDirCluster
        )) ?? [:]
        return FreeSpaceMap(filesystem: "exFAT", regions: regions, deletedFiles: deletedFiles)
    }

    /// Walks the exFAT directory tree collecting deleted-file entry sets
    /// (types 0x05/0x40/0x41 — in-use entries with the InUse bit cleared).
    /// These carry the original filename, exact size, and first cluster.
    static func exfatDeletedFiles(
        _ source: ScanSource,
        boot: [UInt8],
        bytesPerSector: UInt64,
        clusterBytes: UInt64,
        heapStart: UInt64,
        clusterCount: UInt64,
        rootDirCluster: UInt64
    ) throws -> [UInt64: DeletedFileEntry] {
        let fatStart = UInt64(le32(boot, 80)) * bytesPerSector
        func clusterAddress(_ n: UInt64) -> UInt64 { heapStart + (n - 2) * clusterBytes }
        func isValidCluster(_ n: UInt64) -> Bool { n >= 2 && n < clusterCount + 2 }

        func fatNext(_ cluster: UInt64) throws -> UInt64? {
            let entry = [UInt8](try source.read(at: fatStart + cluster * 4, count: 4))
            guard entry.count == 4 else { return nil }
            let next = UInt64(le32(entry, 0))
            return isValidCluster(next) ? next : nil
        }

        /// Directory contents: follows the FAT chain, or contiguous clusters
        /// when NoFatChain is set (also used for deleted directories, whose
        /// FAT chains are no longer valid).
        func directoryData(firstCluster: UInt64, noFatChain: Bool, size: UInt64) throws -> [UInt8] {
            let maxClusters: UInt64 = 512 // ponytail: caps directories at 512 clusters
            var clusters: [UInt64] = []
            if noFatChain {
                let count = size > 0 ? min(maxClusters, (size + clusterBytes - 1) / clusterBytes) : 1
                clusters = (0..<count).compactMap { isValidCluster(firstCluster + $0) ? firstCluster + $0 : nil }
            } else {
                var cluster: UInt64? = firstCluster
                var seen = Set<UInt64>()
                while let current = cluster, isValidCluster(current), seen.insert(current).inserted,
                      clusters.count < Int(maxClusters) {
                    clusters.append(current)
                    cluster = try fatNext(current)
                }
            }
            var data: [UInt8] = []
            for cluster in clusters {
                data.append(contentsOf: [UInt8](try source.read(at: clusterAddress(cluster), count: Int(clusterBytes))))
            }
            return data
        }

        var results: [UInt64: DeletedFileEntry] = [:]
        var queue: [(cluster: UInt64, noFatChain: Bool, size: UInt64)] = [(rootDirCluster, false, 0)]
        var visitedDirs = Set<UInt64>()

        while let directory = queue.popLast() {
            guard visitedDirs.count < 4096, visitedDirs.insert(directory.cluster).inserted else { continue }
            let dir = try directoryData(firstCluster: directory.cluster, noFatChain: directory.noFatChain, size: directory.size)

            var i = 0
            while i + 32 <= dir.count {
                let entryType = dir[i]
                if entryType == 0x00 { break } // end of directory
                guard entryType == 0x85 || entryType == 0x05 else {
                    i += 32
                    continue
                }
                let isDeleted = entryType == 0x05
                let secondaryCount = Int(dir[i + 1])
                let attributes = le16(dir, i + 4)
                let isDirectory = attributes & 0x10 != 0
                let setEnd = i + 32 * (1 + secondaryCount)
                guard secondaryCount >= 2, setEnd <= dir.count else {
                    i += 32
                    continue
                }

                // Stream extension entry follows the file entry.
                let s = i + 32
                let expectedStream: UInt8 = isDeleted ? 0x40 : 0xC0
                guard dir[s] == expectedStream else {
                    i = setEnd
                    continue
                }
                let noFatChain = dir[s + 1] & 0x02 != 0
                let nameLength = Int(dir[s + 3])
                let firstCluster = UInt64(le32(dir, s + 20))
                let dataLength = le64(dir, s + 24)

                // File name entries follow, 15 UTF-16LE units each.
                var nameUnits: [UInt16] = []
                let expectedName: UInt8 = isDeleted ? 0x41 : 0xC1
                var n = s + 32
                while nameUnits.count < nameLength, n + 32 <= setEnd, dir[n] == expectedName {
                    for k in 0..<min(15, nameLength - nameUnits.count) {
                        nameUnits.append(UInt16(dir[n + 2 + 2 * k]) | UInt16(dir[n + 3 + 2 * k]) << 8)
                    }
                    n += 32
                }
                let name = String(utf16CodeUnits: nameUnits, count: nameUnits.count)

                if isValidCluster(firstCluster) {
                    if isDeleted, !isDirectory, dataLength > 0, !name.isEmpty {
                        results[clusterAddress(firstCluster)] = DeletedFileEntry(name: name, length: dataLength)
                    } else if isDirectory {
                        // Live subdirectories, and deleted ones — their entry
                        // data often survives in free space.
                        queue.append((firstCluster, isDeleted ? true : noFatChain, dataLength))
                    }
                }
                i = setEnd
            }
        }
        return results
    }

    // MARK: - Helpers

    /// freeClusters[i] describes cluster i+2. Coalesces runs into byte ranges.
    static func mergedRegions(freeClusters: [Bool], dataStart: UInt64, clusterBytes: UInt64, deviceSize: UInt64) -> [Range<UInt64>] {
        var regions: [Range<UInt64>] = []
        var runStart: Int?
        func closeRun(endingBefore index: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let lower = dataStart + UInt64(start) * clusterBytes
            let upper = min(deviceSize, dataStart + UInt64(index) * clusterBytes)
            if lower < upper { regions.append(lower..<upper) }
        }
        for (index, isFree) in freeClusters.enumerated() {
            if isFree {
                if runStart == nil { runStart = index }
            } else {
                closeRun(endingBefore: index)
            }
        }
        closeRun(endingBefore: freeClusters.count)
        return regions
    }

    private static func matchASCII(_ bytes: [UInt8], at index: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        return Array(bytes[index..<index + pattern.count]) == pattern
    }

    static func le16(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8
    }

    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
    }
}
