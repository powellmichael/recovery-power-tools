import Foundation

/// Minimal NTFS reader: free space from the $Bitmap file, deleted files from
/// MFT records whose in-use flag is cleared. Deleted MFT records keep the
/// filename, exact size, and the data runs — including fragmented files.
enum NTFS {
    struct DataInfo {
        let runs: [(start: UInt64, clusters: UInt64)]
        let size: UInt64
    }

    static func map(_ source: ScanSource, boot: [UInt8]) throws -> FreeSpaceMap? {
        let bytesPerSector = UInt64(FreeSpaceMap.le16(boot, 11))
        guard bytesPerSector >= 256, bytesPerSector <= 4096 else { return nil }
        let rawSPC = boot[13]
        let sectorsPerCluster: UInt64
        if rawSPC == 0 {
            return nil
        } else if rawSPC <= 0x80 {
            sectorsPerCluster = UInt64(rawSPC)
        } else {
            let shift = 256 - Int(rawSPC) // e.g. 0xF6 -> 2^10 sectors
            guard shift <= 25 else { return nil }
            sectorsPerCluster = UInt64(1) << shift
        }
        let clusterBytes = sectorsPerCluster * bytesPerSector
        let totalSectors = FreeSpaceMap.le64(boot, 40)
        let mftCluster = FreeSpaceMap.le64(boot, 48)
        let volumeSize = min(totalSectors * bytesPerSector, source.size)
        let rawRecordSize = Int8(bitPattern: boot[64])
        let recordSize: UInt64 = rawRecordSize > 0
            ? UInt64(rawRecordSize) * clusterBytes
            : UInt64(1) << UInt64(-Int(rawRecordSize))
        guard recordSize >= 256, recordSize <= 65536, volumeSize > clusterBytes else { return nil }

        // Record 0 is the MFT itself; its data runs locate every other record.
        guard let mftRecord = try record(source, at: mftCluster * clusterBytes, recordSize: recordSize, bytesPerSector: Int(bytesPerSector)),
              let mftData = try dataAttribute(in: mftRecord), !mftData.runs.isEmpty else { return nil }

        // Record 6 is $Bitmap: one bit per cluster, set = allocated.
        // ponytail: records assumed not to straddle a run boundary (they are
        // cluster-aligned in practice).
        guard let bitmapRecordOffset = streamOffset(6 * recordSize, runs: mftData.runs, clusterBytes: clusterBytes),
              let bitmapRecord = try record(source, at: bitmapRecordOffset, recordSize: recordSize, bytesPerSector: Int(bytesPerSector)),
              let bitmapData = try dataAttribute(in: bitmapRecord), !bitmapData.runs.isEmpty else { return nil }

        let clusterCount = volumeSize / clusterBytes
        let regions = try freeRegions(source, bitmap: bitmapData, clusterBytes: clusterBytes, clusterCount: clusterCount, volumeSize: volumeSize)
        guard !regions.isEmpty else { return nil }

        let deleted = (try? deletedFiles(
            source,
            mftData: mftData,
            recordSize: recordSize,
            clusterBytes: clusterBytes,
            bytesPerSector: Int(bytesPerSector),
            volumeSize: volumeSize
        )) ?? [:]

        return FreeSpaceMap(filesystem: "NTFS", regions: regions, deletedFiles: deleted, volumeSerial: FreeSpaceMap.le64(boot, 72))
    }

    // MARK: - Records

    static func record(_ source: ScanSource, at offset: UInt64, recordSize: UInt64, bytesPerSector: Int) throws -> [UInt8]? {
        var bytes = [UInt8](try source.read(at: offset, count: Int(recordSize)))
        guard bytes.count == Int(recordSize), hasFileMagic(bytes, 0) else { return nil }
        guard applyFixups(&bytes, bytesPerSector: bytesPerSector) else { return nil }
        return bytes
    }

    static func hasFileMagic(_ bytes: [UInt8], _ i: Int) -> Bool {
        i + 4 <= bytes.count && bytes[i] == 0x46 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x4C && bytes[i + 3] == 0x45 // "FILE"
    }

    /// Restores the real bytes that the update sequence array replaced at the
    /// end of each sector.
    static func applyFixups(_ record: inout [UInt8], bytesPerSector: Int) -> Bool {
        let usaOffset = Int(FreeSpaceMap.le16(record, 4))
        let usaCount = Int(FreeSpaceMap.le16(record, 6))
        guard usaCount >= 1, usaOffset >= 8, usaOffset + usaCount * 2 <= record.count else { return false }
        for i in 1..<usaCount {
            let sectorEnd = i * bytesPerSector
            guard sectorEnd <= record.count else { break }
            guard record[sectorEnd - 2] == record[usaOffset],
                  record[sectorEnd - 1] == record[usaOffset + 1] else { return false }
            record[sectorEnd - 2] = record[usaOffset + i * 2]
            record[sectorEnd - 1] = record[usaOffset + i * 2 + 1]
        }
        return true
    }

    // MARK: - Attributes

    /// The unnamed $DATA (0x80) attribute: data runs and real size.
    /// Resident data (tiny files stored inside the record) returns nil.
    static func dataAttribute(in record: [UInt8]) throws -> DataInfo? {
        var offset = Int(FreeSpaceMap.le16(record, 20))
        while offset + 16 <= record.count {
            let type = FreeSpaceMap.le32(record, offset)
            if type == 0xFFFF_FFFF { break }
            let length = Int(FreeSpaceMap.le32(record, offset + 4))
            guard length >= 24, offset + length <= record.count else { break }
            defer { offset += length }
            guard type == 0x80, record[offset + 9] == 0 else { continue }
            guard record[offset + 8] == 1, offset + 56 <= record.count else { return nil }
            let runlistOffset = Int(FreeSpaceMap.le16(record, offset + 32))
            let size = FreeSpaceMap.le64(record, offset + 48)
            let runs = decodeRuns(record, from: offset + runlistOffset, to: offset + length)
            return DataInfo(runs: runs, size: size)
        }
        return nil
    }

    /// Best $FILE_NAME (0x30): prefers Win32/POSIX names over DOS 8.3 names.
    static func fileName(in record: [UInt8]) -> String? {
        var offset = Int(FreeSpaceMap.le16(record, 20))
        var best: (namespace: UInt8, name: String)?
        while offset + 16 <= record.count {
            let type = FreeSpaceMap.le32(record, offset)
            if type == 0xFFFF_FFFF { break }
            let length = Int(FreeSpaceMap.le32(record, offset + 4))
            guard length >= 24, offset + length <= record.count else { break }
            defer { offset += length }
            guard type == 0x30, record[offset + 8] == 0 else { continue }
            let contentOffset = offset + Int(FreeSpaceMap.le16(record, offset + 20))
            guard contentOffset + 66 <= record.count else { continue }
            let nameLength = Int(record[contentOffset + 64])
            let namespace = record[contentOffset + 65]
            guard nameLength > 0, contentOffset + 66 + nameLength * 2 <= record.count else { continue }
            var units: [UInt16] = []
            for k in 0..<nameLength {
                units.append(UInt16(record[contentOffset + 66 + 2 * k]) | UInt16(record[contentOffset + 67 + 2 * k]) << 8)
            }
            let name = String(utf16CodeUnits: units, count: units.count)
            if best == nil || (best!.namespace == 2 && namespace != 2) {
                best = (namespace, name)
            }
        }
        return best?.name
    }

    /// Decodes an NTFS run list: [header][length bytes][signed LCN delta bytes]…
    /// ponytail: stops at sparse runs (holes); fine for media recovery.
    static func decodeRuns(_ bytes: [UInt8], from start: Int, to end: Int) -> [(start: UInt64, clusters: UInt64)] {
        var runs: [(start: UInt64, clusters: UInt64)] = []
        var i = start
        var lcn: Int64 = 0
        while i < min(end, bytes.count) {
            let header = bytes[i]
            if header == 0 { break }
            let lengthSize = Int(header & 0x0F)
            let offsetSize = Int(header >> 4)
            guard lengthSize >= 1, lengthSize <= 8, offsetSize <= 8,
                  i + 1 + lengthSize + offsetSize <= min(end, bytes.count) else { break }

            var runLength: UInt64 = 0
            for k in 0..<lengthSize {
                runLength |= UInt64(bytes[i + 1 + k]) << (8 * k)
            }
            guard offsetSize > 0 else { break } // sparse run

            var raw: UInt64 = 0
            for k in 0..<offsetSize {
                raw |= UInt64(bytes[i + 1 + lengthSize + k]) << (8 * k)
            }
            let shift = (8 - offsetSize) * 8
            lcn += Int64(bitPattern: raw << shift) >> shift
            guard lcn >= 0, runLength > 0 else { break }
            runs.append((UInt64(lcn), runLength))
            i += 1 + lengthSize + offsetSize
        }
        return runs
    }

    /// Byte offset on disk for a position within a runlist-mapped stream.
    static func streamOffset(_ position: UInt64, runs: [(start: UInt64, clusters: UInt64)], clusterBytes: UInt64) -> UInt64? {
        var remaining = position
        for run in runs {
            let runBytes = run.clusters * clusterBytes
            if remaining < runBytes {
                return run.start * clusterBytes + remaining
            }
            remaining -= runBytes
        }
        return nil
    }

    // MARK: - Free space

    static func freeRegions(_ source: ScanSource, bitmap: DataInfo, clusterBytes: UInt64, clusterCount: UInt64, volumeSize: UInt64) throws -> [Range<UInt64>] {
        var regions: [Range<UInt64>] = []
        var runStart: UInt64?
        var cluster: UInt64 = 0

        func close(_ endCluster: UInt64) {
            guard let start = runStart else { return }
            runStart = nil
            let lower = start * clusterBytes
            let upper = min(volumeSize, endCluster * clusterBytes)
            if lower < upper { regions.append(lower..<upper) }
        }

        var bitmapRemaining = bitmap.size
        outer: for run in bitmap.runs {
            var offset = run.start * clusterBytes
            var runBytes = min(run.clusters * clusterBytes, bitmapRemaining)
            while runBytes > 0 {
                try Task.checkCancellation()
                let want = Int(min(runBytes, 4 * 1024 * 1024))
                let chunk = [UInt8](try source.read(at: offset, count: want))
                guard !chunk.isEmpty else { break outer }
                for byte in chunk {
                    if cluster >= clusterCount { break outer }
                    switch byte {
                    case 0x00:
                        if runStart == nil { runStart = cluster }
                        cluster += 8
                    case 0xFF:
                        close(cluster)
                        cluster += 8
                    default:
                        for bit in 0..<8 where cluster < clusterCount {
                            if byte & (1 << bit) == 0 {
                                if runStart == nil { runStart = cluster }
                            } else {
                                close(cluster)
                            }
                            cluster += 1
                        }
                    }
                }
                offset += UInt64(chunk.count)
                runBytes -= UInt64(chunk.count)
                bitmapRemaining -= UInt64(chunk.count)
            }
        }
        close(min(cluster, clusterCount))
        return regions
    }

    // MARK: - Deleted files

    static func deletedFiles(
        _ source: ScanSource,
        mftData: DataInfo,
        recordSize: UInt64,
        clusterBytes: UInt64,
        bytesPerSector: Int,
        volumeSize: UInt64
    ) throws -> [UInt64: DeletedFileEntry] {
        var results: [UInt64: DeletedFileEntry] = [:]
        var recordsSeen: UInt64 = 0
        let recordCap: UInt64 = 4_000_000 // ponytail: 4 GB of MFT at 1 KB records

        outer: for run in mftData.runs {
            var offset = run.start * clusterBytes
            var remaining = run.clusters * clusterBytes
            while remaining >= recordSize {
                try Task.checkCancellation()
                let rawWant = Int(min(remaining, 4 * 1024 * 1024))
                let want = rawWant - rawWant % Int(recordSize)
                let chunk = [UInt8](try source.read(at: offset, count: want))
                guard chunk.count >= Int(recordSize) else { break outer }

                var i = 0
                while i + Int(recordSize) <= chunk.count {
                    defer { i += Int(recordSize) }
                    recordsSeen += 1
                    if recordsSeen > recordCap { break outer }
                    guard hasFileMagic(chunk, i) else { continue }
                    let flags = FreeSpaceMap.le16(chunk, i + 22)
                    guard flags & 0x01 == 0, flags & 0x02 == 0 else { continue } // deleted, not a directory

                    var rec = Array(chunk[i..<i + Int(recordSize)])
                    guard applyFixups(&rec, bytesPerSector: bytesPerSector),
                          let name = fileName(in: rec), !name.isEmpty,
                          let data = try? dataAttribute(in: rec), data.size > 0 else { continue }

                    let segments = data.runs
                        .map { ($0.start * clusterBytes)..<min(volumeSize, ($0.start + $0.clusters) * clusterBytes) }
                        .filter { !$0.isEmpty }
                    guard let firstSegment = segments.first else { continue }
                    results[firstSegment.lowerBound] = DeletedFileEntry(
                        name: name,
                        length: data.size,
                        segments: segments.count > 1 ? segments : nil
                    )
                }
                offset += UInt64(chunk.count)
                remaining -= UInt64(chunk.count)
            }
        }
        return results
    }
}
