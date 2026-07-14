import Foundation

struct RecoveryScanner: Sendable {
    private let chunkSize = 4 * 1024 * 1024
    private let overlapSize = 128 * 1024
    private let maxCarveSize: UInt64 = 2 * 1024 * 1024 * 1024
    private let jpegSearchCap: UInt64 = 256 * 1024 * 1024
    private let pngSearchCap: UInt64 = 1024 * 1024 * 1024

    // MARK: - Planning

    func makePlan(for target: ScanTarget) async throws -> ScanPlan {
        switch target {
        case .path(let url):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw RecoveryError.sourceMissing(url.path)
            }
            if isDirectory.boolValue {
                let regions = try discoverReadableInputs(at: url).compactMap { fileURL -> ScanRegion? in
                    let source = try ScanSource(fileURL: fileURL)
                    guard source.size > 0 else { return nil }
                    return ScanRegion(source: source, range: 0..<source.size)
                }
                return ScanPlan(regions: regions, note: nil)
            }
            // A single file might be a raw disk image with a parseable filesystem.
            let source = try ScanSource(fileURL: url)
            if let plan = try freeSpacePlan(for: source) {
                return plan
            }
            return ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)

        case .device(let device):
            let source = try ScanSource(devicePath: device.rawDevicePath, displayName: device.displayName)
            if let plan = try freeSpacePlan(for: source) {
                return plan
            }
            return ScanPlan(
                regions: [ScanRegion(source: source, range: 0..<source.size)],
                note: "Filesystem not recognized — scanning the entire device. Results may include live files."
            )
        }
    }

    private func freeSpacePlan(for source: ScanSource) throws -> ScanPlan? {
        guard let map = try FreeSpaceMap.read(from: source) else { return nil }
        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(map.freeBytes), countStyle: .file)
        let namesNote = map.deletedFiles.isEmpty
            ? " No deleted directory entries found, so original filenames are unavailable."
            : " Found \(map.deletedFiles.count) deleted directory entries with original filenames."
        return ScanPlan(
            regions: map.regions.map { ScanRegion(source: source, range: $0) },
            note: "\(map.filesystem) volume — scanning \(sizeLabel) of free space. Everything found is deleted data.\(namesNote)",
            deletedFiles: map.deletedFiles
        )
    }

    // MARK: - Scanning

    func scan(
        plan: ScanPlan,
        selectedKinds: Set<MediaKind>,
        pauseGate: PauseGate? = nil,
        progress: @escaping @Sendable (ScanProgress) async -> Void,
        itemFound: @escaping @Sendable (RecoveredItem) async -> Void
    ) async throws -> [RecoveredItem] {
        let totalBytes = plan.regions.reduce(UInt64(0)) { $0 + UInt64($1.range.count) }
        var allItems: [RecoveredItem] = []
        var bytesScanned: UInt64 = 0

        // Deleted directory entries are first-class results: verify the
        // signature at each entry's data offset and emit it with its original
        // name and exact size. Carving then only adds anonymous extras.
        var claimed: [RecoveredItem] = []
        if let source = plan.regions.first?.source, !plan.deletedFiles.isEmpty {
            let freeRanges = plan.regions.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
            for (offset, entry) in plan.deletedFiles.sorted(by: { $0.key < $1.key }) {
                try await waitIfPaused(pauseGate)
                guard entry.length > 0, offset < source.size else { continue }
                // Data reused by a live file is no longer in free space — skip.
                guard rangesContain(freeRanges, offset) else { continue }
                let head = [UInt8](try source.read(at: offset, count: 64))
                guard let (kind, sniffExt) = sniffKind(head), selectedKinds.contains(kind) else { continue }
                let nameExt = (entry.name as NSString).pathExtension.lowercased()
                let item = RecoveredItem(
                    kind: kind,
                    source: source,
                    byteOffset: offset,
                    byteLength: min(entry.length, source.size - offset),
                    fileExtension: nameExt.isEmpty ? (sniffExt ?? kind.fileExtension) : nameExt,
                    originalFilename: entry.name,
                    segments: entry.segments
                )
                claimed.append(item)
                allItems.append(item)
                await itemFound(item)
            }
        }

        for region in plan.regions {
            try Task.checkCancellation()
            let regionClaims = claimed.filter {
                $0.byteOffset < region.range.upperBound && $0.byteOffset + $0.byteLength > region.range.lowerBound
            }
            let items = try await scanRegion(
                region,
                totalBytes: totalBytes,
                scannedBefore: bytesScanned,
                selectedKinds: selectedKinds,
                deletedFiles: plan.deletedFiles,
                claimed: regionClaims,
                pauseGate: pauseGate,
                progress: progress,
                itemFound: itemFound
            )
            allItems.append(contentsOf: items)
            bytesScanned += UInt64(region.range.count)
        }

        await progress(ScanProgress(bytesScanned: totalBytes, totalBytes: totalBytes, currentPath: ""))
        return allItems
    }

    private func scanRegion(
        _ region: ScanRegion,
        totalBytes: UInt64,
        scannedBefore: UInt64,
        selectedKinds: Set<MediaKind>,
        deletedFiles: [UInt64: DeletedFileEntry],
        claimed: [RecoveredItem],
        pauseGate: PauseGate?,
        progress: @escaping @Sendable (ScanProgress) async -> Void,
        itemFound: @escaping @Sendable (RecoveredItem) async -> Void
    ) async throws -> [RecoveredItem] {
        let source = region.source
        let regionEnd = region.range.upperBound
        var items: [RecoveredItem] = []
        var cursor = region.range.lowerBound
        var carry = Data()
        var lastReport = Date.distantPast

        while cursor < regionEnd {
            try await waitIfPaused(pauseGate)
            let want = Int(min(UInt64(chunkSize), regionEnd - cursor))
            let chunk = try source.read(at: cursor, count: want)
            let isLast = chunk.isEmpty || cursor + UInt64(chunk.count) >= regionEnd

            var buffer = carry
            buffer.append(chunk)
            let baseOffset = cursor - UInt64(carry.count)
            let searchLimit = isLast ? buffer.count : max(0, buffer.count - overlapSize)

            for candidate in try findCandidates(
                in: buffer,
                source: source,
                regionEnd: regionEnd,
                baseOffset: baseOffset,
                searchLimit: searchLimit,
                selectedKinds: selectedKinds,
                deletedFiles: deletedFiles
            ) {
                guard !overlapsExisting(candidate, in: items),
                      !overlapsExisting(candidate, in: claimed) else { continue }
                items.append(candidate)
                await itemFound(candidate)
            }

            cursor += UInt64(chunk.count)
            if isLast { break }
            carry = buffer.suffix(min(overlapSize, buffer.count))

            // Throttle: on fast drives per-chunk reporting floods the UI.
            if Date().timeIntervalSince(lastReport) >= 0.25 {
                lastReport = Date()
                await progress(ScanProgress(
                    bytesScanned: scannedBefore + (cursor - region.range.lowerBound),
                    totalBytes: totalBytes,
                    currentPath: source.displayName
                ))
            }
        }

        return items.sorted { $0.byteOffset < $1.byteOffset }
    }

    /// Blocks while the gate is paused; pause latency is at most one chunk
    /// plus one candidate length parse.
    private func waitIfPaused(_ gate: PauseGate?) async throws {
        try Task.checkCancellation()
        while let gate, gate.isPaused {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
        }
    }

    // MARK: - Candidate detection

    private struct Candidate {
        let kind: MediaKind
        let start: Int
        let length: UInt64
        let ext: String?
    }

    private func findCandidates(
        in data: Data,
        source: ScanSource,
        regionEnd: UInt64,
        baseOffset: UInt64,
        searchLimit: Int,
        selectedKinds: Set<MediaKind>,
        deletedFiles: [UInt64: DeletedFileEntry]
    ) throws -> [RecoveredItem] {
        var results: [RecoveredItem] = []
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var index = 0
        while index < searchLimit {
            try Task.checkCancellation()
            if let candidate = try detect(bytes, index, source: source, regionEnd: regionEnd, baseOffset: baseOffset, kinds: selectedKinds) {
                let byteOffset = baseOffset + UInt64(candidate.start)
                // A deleted directory entry starting exactly here supplies the
                // original filename and the file's true size.
                let entry = deletedFiles[byteOffset]
                var length = candidate.length
                if let entry, entry.length > 0, byteOffset + entry.length <= regionEnd {
                    length = entry.length
                }
                results.append(item(
                    candidate.kind,
                    source: source,
                    byteOffset: byteOffset,
                    byteLength: length,
                    ext: candidate.ext,
                    directoryEntry: entry
                ))
                index = candidate.start + Int(min(length, UInt64(Int.max - candidate.start)))
            } else {
                index += 1
            }
        }

        return results
    }

    private func detect(
        _ bytes: [UInt8],
        _ index: Int,
        source: ScanSource,
        regionEnd: UInt64,
        baseOffset: UInt64,
        kinds: Set<MediaKind>
    ) throws -> Candidate? {
        let absolute = baseOffset + UInt64(index)

        switch bytes[index] {
        case 0xFF: // JPEG
            guard kinds.contains(.jpeg), match(bytes, index, [0xFF, 0xD8, 0xFF]) else { return nil }
            let limit = min(regionEnd, absolute &+ jpegSearchCap)
            guard let end = try findMarkerEnd(in: source, from: absolute + 3, limit: limit, marker: [0xFF, 0xD9]) else { return nil }
            return Candidate(kind: .jpeg, start: index, length: end - absolute, ext: nil)

        case 0x89: // PNG
            guard kinds.contains(.png), match(bytes, index, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
            let limit = min(regionEnd, absolute &+ pngSearchCap)
            guard let end = try findMarkerEnd(in: source, from: absolute + 8, limit: limit, marker: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]) else { return nil }
            return Candidate(kind: .png, start: index, length: end - absolute, ext: nil)

        case 0x66: // "ftyp" — ISO base media box starts 4 bytes earlier
            guard index >= 4, match(bytes, index, Array("ftyp".utf8)) else { return nil }
            guard let (kind, ext) = ftypKind(bytes, at: index), kinds.contains(kind) else { return nil }
            let start = index - 4
            guard let length = try isoBaseMediaLength(in: source, from: baseOffset + UInt64(start), regionEnd: regionEnd) else { return nil }
            return Candidate(kind: kind, start: start, length: length, ext: ext)

        case 0x50: // ZIP "PK\3\4"
            guard kinds.contains(.zip), match(bytes, index, [0x50, 0x4B, 0x03, 0x04]) else { return nil }
            guard let length = try zipLength(in: source, from: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .zip, start: index, length: length, ext: nil)

        case 0x42: // BMP "BM"
            guard kinds.contains(.bmp), match(bytes, index, [0x42, 0x4D]) else { return nil }
            guard let length = try bmpLength(in: source, at: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .bmp, start: index, length: length, ext: nil)

        case 0x52: // AVI "RIFF"
            guard kinds.contains(.avi), match(bytes, index, Array("RIFF".utf8)) else { return nil }
            guard let length = try aviLength(in: source, at: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .avi, start: index, length: length, ext: nil)

        case 0x30: // ASF header GUID
            guard kinds.contains(.wmv),
                  match(bytes, index, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]) else { return nil }
            guard let length = try asfLength(in: source, at: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .wmv, start: index, length: length, ext: nil)

        case 0x46: // "F" — FLV or FUJIFILM RAF
            if kinds.contains(.flv), match(bytes, index, [0x46, 0x4C, 0x56, 0x01]),
               let length = try flvLength(in: source, at: absolute, regionEnd: regionEnd) {
                return Candidate(kind: .flv, start: index, length: length, ext: nil)
            }
            if kinds.contains(.raw), match(bytes, index, Array("FUJIFILMCCD-RAW".utf8)),
               let length = try rafLength(in: source, at: absolute, regionEnd: regionEnd) {
                return Candidate(kind: .raw, start: index, length: length, ext: "raf")
            }
            return nil

        case 0x1A: // EBML (WebM / MKV)
            guard kinds.contains(.webm), match(bytes, index, [0x1A, 0x45, 0xDF, 0xA3]) else { return nil }
            guard let (length, ext) = try ebmlLength(in: source, at: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .webm, start: index, length: length, ext: ext)

        case 0x00: // MPEG program stream pack header
            guard kinds.contains(.mpeg), match(bytes, index, [0x00, 0x00, 0x01, 0xBA]) else { return nil }
            guard let length = try mpegProgramStreamLength(in: source, at: absolute, regionEnd: regionEnd) else { return nil }
            return Candidate(kind: .mpeg, start: index, length: length, ext: nil)

        case 0x49, 0x4D: // TIFF ("II*\0" / "MM\0*") — NEF, CR2, ARW, DNG, 3FR…
            guard kinds.contains(.raw) else { return nil }
            let littleEndian = match(bytes, index, [0x49, 0x49, 0x2A, 0x00])
            guard littleEndian || match(bytes, index, [0x4D, 0x4D, 0x00, 0x2A]) else { return nil }
            guard let (length, ext) = try tiffLength(in: source, at: absolute, regionEnd: regionEnd, bigEndian: !littleEndian) else { return nil }
            return Candidate(kind: .raw, start: index, length: length, ext: ext)

        default:
            return nil
        }
    }

    private func item(_ kind: MediaKind, source: ScanSource, byteOffset: UInt64, byteLength: UInt64, ext: String?, directoryEntry: DeletedFileEntry? = nil) -> RecoveredItem {
        RecoveredItem(
            kind: kind,
            source: source,
            byteOffset: byteOffset,
            byteLength: byteLength,
            fileExtension: ext ?? kind.fileExtension,
            originalFilename: directoryEntry?.name
                ?? originalFilenameIfWholeFile(kind: kind, source: source, byteOffset: byteOffset, byteLength: byteLength)
        )
    }

    private func originalFilenameIfWholeFile(kind: MediaKind, source: ScanSource, byteOffset: UInt64, byteLength: UInt64) -> String? {
        guard byteOffset == 0, byteLength == source.size, let url = source.fileURL,
              kind.knownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url.lastPathComponent
    }

    private func overlapsExisting(_ item: RecoveredItem, in items: [RecoveredItem]) -> Bool {
        items.contains { existing in
            let existingEnd = existing.byteOffset + existing.byteLength
            let itemEnd = item.byteOffset + item.byteLength
            return item.byteOffset < existingEnd && existing.byteOffset < itemEnd
        }
    }

    private func match(_ bytes: [UInt8], _ index: Int, _ pattern: [UInt8]) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for (offset, expected) in pattern.enumerated() where bytes[index + offset] != expected {
            return false
        }
        return true
    }

    /// Signature-only check of a file head, used to validate deleted
    /// directory entries whose length we already know.
    private func sniffKind(_ b: [UInt8]) -> (MediaKind, String?)? {
        if match(b, 0, [0xFF, 0xD8, 0xFF]) { return (.jpeg, nil) }
        if match(b, 0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return (.png, nil) }
        if b.count >= 16, match(b, 4, Array("ftyp".utf8)), let (kind, ext) = ftypKind(b, at: 4) { return (kind, ext) }
        if match(b, 0, [0x50, 0x4B, 0x03, 0x04]) { return (.zip, nil) }
        if match(b, 0, [0x42, 0x4D]), b.count >= 18, [12, 40, 52, 56, 64, 108, 124].contains(FreeSpaceMap.le32(b, 14)) { return (.bmp, nil) }
        if match(b, 0, Array("RIFF".utf8)), match(b, 8, Array("AVI ".utf8)) { return (.avi, nil) }
        if match(b, 0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]) { return (.wmv, nil) }
        if match(b, 0, [0x46, 0x4C, 0x56, 0x01]) { return (.flv, nil) }
        if match(b, 0, Array("FUJIFILMCCD-RAW".utf8)) { return (.raw, "raf") }
        if match(b, 0, [0x1A, 0x45, 0xDF, 0xA3]) { return (.webm, nil) }
        if match(b, 0, [0x00, 0x00, 0x01, 0xBA]) { return (.mpeg, nil) }
        if match(b, 0, [0x49, 0x49, 0x2A, 0x00]) || match(b, 0, [0x4D, 0x4D, 0x00, 0x2A]) {
            return (.raw, b.count > 10 && b[8] == 0x43 && b[9] == 0x52 ? "cr2" : "tif")
        }
        return nil
    }

    private func rangesContain(_ sortedRanges: [Range<UInt64>], _ offset: UInt64) -> Bool {
        var low = 0
        var high = sortedRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sortedRanges[mid].contains(offset) { return true }
            if offset < sortedRanges[mid].lowerBound {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return false
    }

    private func ftypKind(_ bytes: [UInt8], at ftypIndex: Int) -> (MediaKind, String)? {
        guard ftypIndex + 12 <= bytes.count else { return nil }
        let brandData = Data(bytes[ftypIndex + 4..<min(bytes.count, ftypIndex + 28)])
        guard let brands = String(data: brandData, encoding: .ascii) else { return nil }

        if ["heic", "heix", "hevc", "hevx", "mif1", "mif2", "msf1"].contains(where: brands.contains) {
            return (.heic, "heic")
        }
        if brands.contains("qt  ") {
            return (.video, "mov")
        }
        if brands.contains("3gp") { return (.video, "3gp") }
        if brands.contains("3g2") { return (.video, "3g2") }
        if ["mp41", "mp42", "isom", "iso2", "avc1", "M4V ", "mmp4"].contains(where: brands.contains) {
            return (.video, "mp4")
        }
        return nil
    }

    // MARK: - Format length parsers

    private func findMarkerEnd(in source: ScanSource, from searchOffset: UInt64, limit: UInt64, marker: [UInt8]) throws -> UInt64? {
        var offset = searchOffset
        var carry: [UInt8] = []
        while offset < limit {
            try Task.checkCancellation()
            let want = Int(min(UInt64(chunkSize), limit - offset))
            let data = try source.read(at: offset, count: want)
            guard !data.isEmpty else { return nil }

            var buffer = carry
            buffer.append(contentsOf: data)
            let base = offset - UInt64(carry.count)

            if buffer.count >= marker.count {
                for i in 0...(buffer.count - marker.count) where buffer[i] == marker[0] {
                    var j = 1
                    while j < marker.count, buffer[i + j] == marker[j] { j += 1 }
                    if j == marker.count {
                        return base + UInt64(i + marker.count)
                    }
                }
            }

            offset += UInt64(data.count)
            carry = Array(buffer.suffix(marker.count - 1))
        }
        return nil
    }

    private func zipLength(in source: ScanSource, from start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let limit = min(regionEnd, start &+ maxCarveSize)
        // End of central directory: sig(4) + fields(16) + comment length(2) + comment
        guard let sigEnd = try findMarkerEnd(in: source, from: start + 4, limit: limit, marker: [0x50, 0x4B, 0x05, 0x06]) else { return nil }
        let record = [UInt8](try source.read(at: sigEnd, count: 18))
        guard record.count == 18 else { return nil }
        let commentLength = UInt64(record[16]) | UInt64(record[17]) << 8
        let zipEnd = sigEnd + 18 + commentLength
        guard zipEnd <= regionEnd else { return nil }
        return zipEnd - start
    }

    private func isoBaseMediaLength(in source: ScanSource, from start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let knownBoxTypes: Set<String> = [
            "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot", "udta",
            "meta", "uuid", "moof", "mfra", "sidx", "styp", "ssix", "prft", "emsg"
        ]
        var cursor = start
        var parsedLength: UInt64 = 0
        while cursor + 8 <= regionEnd {
            let header = [UInt8](try source.read(at: cursor, count: 16))
            guard header.count >= 8 else { break }
            let size32 = UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3])
            guard let boxType = String(bytes: header[4..<8], encoding: .ascii) else { break }

            var boxSize = UInt64(size32)
            if size32 == 1 {
                guard header.count >= 16 else { break }
                boxSize = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                parsedLength = min(regionEnd, start &+ maxCarveSize) - start
                break
            }

            guard parsedLength == 0 || knownBoxTypes.contains(boxType) else { break }
            guard boxSize >= 8, cursor + boxSize <= regionEnd, boxSize <= maxCarveSize else { break }
            parsedLength = (cursor + boxSize) - start
            cursor += boxSize

            if parsedLength >= maxCarveSize { break }
        }
        return parsedLength > 16 ? parsedLength : nil
    }

    private func bmpLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let header = [UInt8](try source.read(at: start, count: 18))
        guard header.count == 18 else { return nil }
        // Reserved fields must be zero and the DIB header size must be a known one,
        // otherwise random "BM" bytes flood the results.
        guard header[6] == 0, header[7] == 0, header[8] == 0, header[9] == 0 else { return nil }
        let dibSize = FreeSpaceMap.le32(header, 14)
        guard [12, 40, 52, 56, 64, 108, 124].contains(dibSize) else { return nil }
        let size = UInt64(FreeSpaceMap.le32(header, 2))
        guard size >= 30, size <= maxCarveSize, start + size <= regionEnd else { return nil }
        return size
    }

    private func aviLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let header = [UInt8](try source.read(at: start, count: 12))
        guard header.count == 12,
              match(header, 0, Array("RIFF".utf8)),
              match(header, 8, Array("AVI ".utf8)) else { return nil }
        var extent = UInt64(FreeSpaceMap.le32(header, 4)) + 8
        guard extent > 12, start + extent <= regionEnd else { return nil }

        // Files over 4 GB continue in "RIFF AVIX" chunks.
        for _ in 0..<64 {
            let next = [UInt8](try source.read(at: start + extent, count: 12))
            guard next.count == 12, match(next, 0, Array("RIFF".utf8)), match(next, 8, Array("AVIX".utf8)) else { break }
            let chunkSize = UInt64(FreeSpaceMap.le32(next, 4)) + 8
            guard start + extent + chunkSize <= regionEnd, extent + chunkSize <= maxCarveSize else { break }
            extent += chunkSize
        }
        return extent
    }

    private func asfLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let head = [UInt8](try source.read(at: start, count: 24))
        guard head.count == 24 else { return nil }
        let headerSize = FreeSpaceMap.le64(head, 16)
        guard headerSize >= 30, headerSize <= 16 * 1024 * 1024, start + headerSize <= regionEnd else { return nil }

        // The File Properties object inside the header holds the total file size.
        let filePropsGUID: [UInt8] = [0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
        let headerBody = [UInt8](try source.read(at: start, count: Int(headerSize)))
        guard headerBody.count >= 48 else { return nil }
        var position = 30
        while position + 48 <= headerBody.count {
            if match(headerBody, position, filePropsGUID) {
                let fileSize = FreeSpaceMap.le64(headerBody, position + 40)
                guard fileSize >= headerSize + 50, fileSize <= maxCarveSize, start + fileSize <= regionEnd else { return nil }
                return fileSize
            }
            position += 1
        }
        return nil
    }

    private func flvLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let header = [UInt8](try source.read(at: start, count: 9))
        guard header.count == 9, header[5] == 0, header[6] == 0, header[7] == 0, header[8] == 9 else { return nil }

        let limit = min(regionEnd, start &+ maxCarveSize)
        var position = start + 9
        var tagCount = 0
        while position + 15 <= limit {
            try Task.checkCancellation()
            // 4-byte previous-tag size, then tag header: type(1) dataSize(3) rest(7)
            let block = [UInt8](try source.read(at: position, count: 15))
            guard block.count == 15 else { break }
            let tagType = block[4]
            guard tagType == 8 || tagType == 9 || tagType == 18 else {
                // Not a tag: this 4-byte value is the trailing previous-tag size.
                return tagCount > 0 ? position + 4 - start : nil
            }
            let dataSize = UInt64(block[5]) << 16 | UInt64(block[6]) << 8 | UInt64(block[7])
            let next = position + 4 + 11 + dataSize
            guard next <= limit else { break }
            position = next
            tagCount += 1
        }
        guard tagCount > 0, position + 4 <= limit else { return nil }
        return position + 4 - start
    }

    private func ebmlLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> (UInt64, String)? {
        let head = [UInt8](try source.read(at: start, count: 128))
        guard head.count >= 8 else { return nil }
        guard let headerSize = vint(head, 4) else { return nil }
        let headerEnd = 4 + headerSize.length + Int(headerSize.value)
        guard headerSize.value <= 4096 else { return nil }

        let docTypeBytes = Array("webm".utf8)
        let searchEnd = min(head.count, headerEnd)
        var isWebM = false
        if searchEnd >= docTypeBytes.count {
            for i in 0...(searchEnd - docTypeBytes.count) where match(head, i, docTypeBytes) {
                isWebM = true
                break
            }
        }
        let ext = isWebM ? "webm" : "mkv"

        let segmentHead = [UInt8](try source.read(at: start + UInt64(headerEnd), count: 16))
        guard segmentHead.count >= 6, match(segmentHead, 0, [0x18, 0x53, 0x80, 0x67]),
              let segmentSize = vint(segmentHead, 4) else { return nil }

        let extent: UInt64
        if segmentSize.unknown {
            // ponytail: streamed files declare an unknown segment size; carve to
            // the end of the free region, capped. Trailing garbage is possible.
            extent = min(regionEnd - start, maxCarveSize)
        } else {
            extent = UInt64(headerEnd) + 4 + UInt64(segmentSize.length) + segmentSize.value
        }
        guard extent > 32, extent <= maxCarveSize, start + extent <= regionEnd else { return nil }
        return (extent, ext)
    }

    private func vint(_ bytes: [UInt8], _ index: Int) -> (value: UInt64, length: Int, unknown: Bool)? {
        guard index < bytes.count, bytes[index] != 0 else { return nil }
        let length = bytes[index].leadingZeroBitCount + 1
        guard length <= 8, index + length <= bytes.count else { return nil }
        var value = UInt64(bytes[index]) & (UInt64(0xFF) >> UInt64(length))
        for k in 1..<length {
            value = value << 8 | UInt64(bytes[index + k])
        }
        let unknown = value == (UInt64(1) << (7 * length)) - 1
        return (value, length, unknown)
    }

    private func mpegProgramStreamLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let limit = min(regionEnd, start &+ maxCarveSize)
        var position = start
        var packetCount = 0
        while position + 4 <= limit {
            try Task.checkCancellation()
            let header = [UInt8](try source.read(at: position, count: 14))
            guard header.count >= 4, header[0] == 0, header[1] == 0, header[2] == 1 else { break }
            let code = header[3]
            if code == 0xBA {
                guard header.count >= 14 else { break }
                if header[4] & 0xC0 == 0x40 { // MPEG-2 pack header
                    position += 14 + UInt64(header[13] & 0x07)
                } else if header[4] & 0xF0 == 0x20 { // MPEG-1 pack header
                    position += 12
                } else {
                    break
                }
            } else if code == 0xB9 { // program end
                position += 4
                packetCount += 1
                break
            } else if code >= 0xBB {
                guard header.count >= 6 else { break }
                position += 6 + UInt64(header[4]) << 8 + UInt64(header[5])
            } else {
                break
            }
            packetCount += 1
        }
        guard packetCount >= 2, position > start + 20 else { return nil }
        return position - start
    }

    private func rafLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64) throws -> UInt64? {
        let header = [UInt8](try source.read(at: start, count: 108))
        guard header.count == 108 else { return nil }
        func be32(_ i: Int) -> UInt64 {
            UInt64(header[i]) << 24 | UInt64(header[i + 1]) << 16 | UInt64(header[i + 2]) << 8 | UInt64(header[i + 3])
        }
        var extent: UInt64 = 108
        for fieldOffset in [84, 92, 100] {
            let sectionOffset = be32(fieldOffset)
            let sectionLength = be32(fieldOffset + 4)
            guard sectionLength > 0, sectionOffset + sectionLength <= maxCarveSize else { continue }
            extent = max(extent, sectionOffset + sectionLength)
        }
        guard extent >= 64 * 1024, start + extent <= regionEnd else { return nil }
        return extent
    }

    private func tiffLength(in source: ScanSource, at start: UInt64, regionEnd: UInt64, bigEndian: Bool) throws -> (UInt64, String)? {
        let limit = min(regionEnd - start, maxCarveSize)
        let header = [UInt8](try source.read(at: start, count: 12))
        guard header.count == 12 else { return nil }

        func u16(_ b: [UInt8], _ i: Int) -> UInt32 {
            bigEndian ? UInt32(b[i]) << 8 | UInt32(b[i + 1]) : UInt32(b[i + 1]) << 8 | UInt32(b[i])
        }
        func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
            bigEndian
                ? UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                : UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i])
        }

        let ext = header[8] == 0x43 && header[9] == 0x52 ? "cr2" : "tif" // "CR" at offset 8
        let typeSizes: [UInt64] = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]

        var extent: UInt64 = 8
        var queue: [UInt64] = [UInt64(u32(header, 4))]
        var visited = Set<UInt64>()
        var ifdsWalked = 0

        while let ifdOffset = queue.popLast() {
            guard ifdOffset >= 8, ifdOffset < limit, visited.insert(ifdOffset).inserted, ifdsWalked < 64 else { continue }
            ifdsWalked += 1

            let countBytes = [UInt8](try source.read(at: start + ifdOffset, count: 2))
            guard countBytes.count == 2 else { continue }
            let entryCount = Int(u16(countBytes, 0))
            guard entryCount > 0, entryCount <= 512 else { continue }

            let body = [UInt8](try source.read(at: start + ifdOffset + 2, count: entryCount * 12 + 4))
            guard body.count == entryCount * 12 + 4 else { continue }
            extent = max(extent, ifdOffset + 2 + UInt64(entryCount * 12) + 4)

            var stripOffsets: [UInt64] = []
            var stripCounts: [UInt64] = []

            for entryIndex in 0..<entryCount {
                let e = entryIndex * 12
                let tag = u16(body, e)
                let type = Int(u16(body, e + 2))
                let count = UInt64(u32(body, e + 4))
                let value = UInt64(u32(body, e + 8))
                guard type >= 1, type <= 12 else { continue }

                let byteCount = count * typeSizes[type]
                if byteCount > 4, value < limit, byteCount < limit, value + byteCount <= limit {
                    extent = max(extent, value + byteCount)
                }

                // Sub-IFD, EXIF, and GPS pointers
                if (tag == 330 || tag == 34665 || tag == 34853), type == 4 {
                    if count == 1 {
                        queue.append(value)
                    } else if count <= 16, value + count * 4 <= limit {
                        let pointers = [UInt8](try source.read(at: start + value, count: Int(count) * 4))
                        var p = 0
                        while p + 4 <= pointers.count {
                            queue.append(UInt64(u32(pointers, p)))
                            p += 4
                        }
                    }
                }

                if tag == 273 || tag == 324 {
                    stripOffsets = try tiffValueArray(source, tiffStart: start, type: type, count: count, valueField: Array(body[e + 8..<e + 12]), limit: limit, read16: u16, read32: u32)
                }
                if tag == 279 || tag == 325 {
                    stripCounts = try tiffValueArray(source, tiffStart: start, type: type, count: count, valueField: Array(body[e + 8..<e + 12]), limit: limit, read16: u16, read32: u32)
                }
            }

            for (offset, count) in zip(stripOffsets, stripCounts) where offset + count <= limit {
                extent = max(extent, offset + count)
            }

            let nextIFD = UInt64(u32(body, entryCount * 12))
            if nextIFD != 0 {
                queue.append(nextIFD)
            }
        }

        // ponytail: 16 KB floor filters out EXIF blocks and junk that parse as
        // tiny TIFFs; real RAW files are megabytes.
        guard extent >= 16 * 1024, start + extent <= regionEnd else { return nil }
        return (extent, ext)
    }

    private func tiffValueArray(
        _ source: ScanSource,
        tiffStart: UInt64,
        type: Int,
        count: UInt64,
        valueField: [UInt8],
        limit: UInt64,
        read16: ([UInt8], Int) -> UInt32,
        read32: ([UInt8], Int) -> UInt32
    ) throws -> [UInt64] {
        guard type == 3 || type == 4, count > 0, count <= 8192 else { return [] }
        let entrySize = type == 3 ? 2 : 4
        let totalBytes = Int(count) * entrySize

        let raw: [UInt8]
        if totalBytes <= 4 {
            raw = valueField
        } else {
            let offset = UInt64(read32(valueField, 0))
            guard offset + UInt64(totalBytes) <= limit else { return [] }
            raw = [UInt8](try source.read(at: tiffStart + offset, count: totalBytes))
            guard raw.count == totalBytes else { return [] }
        }

        var values: [UInt64] = []
        for i in 0..<Int(count) {
            let at = i * entrySize
            values.append(type == 3 ? UInt64(read16(raw, at)) : UInt64(read32(raw, at)))
        }
        return values
    }

    // MARK: - Recovery

    func recover(_ item: RecoveredItem, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputURL = uniqueOutputURL(for: item, in: destination)
        try write(item, to: outputURL)
        return outputURL
    }

    func write(_ item: RecoveredItem, to outputURL: URL) throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw RecoveryError.cannotCreateOutput(outputURL.path)
        }
        let writer = try FileHandle(forWritingTo: outputURL)
        defer { try? writer.close() }

        // Fragmented files (NTFS data runs) are stitched run by run; the
        // total is capped at byteLength since the last run includes slack.
        let segments = item.segments ?? [item.byteOffset..<(item.byteOffset + item.byteLength)]
        var remaining = item.byteLength
        for segment in segments {
            var position = segment.lowerBound
            while remaining > 0, position < segment.upperBound {
                let want = Int(min(UInt64(chunkSize), min(remaining, segment.upperBound - position)))
                let data = try item.source.read(at: position, count: want)
                guard !data.isEmpty else { return }
                try writer.write(contentsOf: data)
                position += UInt64(data.count)
                remaining -= UInt64(data.count)
            }
            if remaining == 0 { break }
        }
    }

    private func uniqueOutputURL(for item: RecoveredItem, in destination: URL) -> URL {
        var candidate = destination.appendingPathComponent(item.displayName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = (item.displayName as NSString).deletingPathExtension
            candidate = destination.appendingPathComponent("\(base)-\(counter).\(item.fileExtension)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Folder discovery

    private func discoverReadableInputs(at source: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw RecoveryError.cannotEnumerate(source.path)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            if values.isRegularFile == true && values.isReadable == true {
                guard !isContainerOrInstallerFile(url), !isExistingMediaFile(url) else { continue }
                files.append(url)
            }
        }
        return files
    }

    private func isContainerOrInstallerFile(_ url: URL) -> Bool {
        let containerExtensions: Set<String> = [
            "zip", "rar", "7z",
            "tar", "tgz", "gz", "bz2", "xz",
            "dmg", "iso", "img", "sparseimage", "sparsebundle",
            "pkg", "mpkg", "xar"
        ]
        return containerExtensions.contains(url.pathExtension.lowercased())
    }

    private func isExistingMediaFile(_ url: URL) -> Bool {
        let existingMediaExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "bmp", "gif",
            "tif", "tiff", "nef", "cr2", "arw", "dng", "3fr", "raf",
            "mov", "mp4", "m4v", "3gp", "3g2",
            "avi", "wmv", "asf", "flv", "webm", "mkv", "mpg", "mpeg"
        ]
        return existingMediaExtensions.contains(url.pathExtension.lowercased())
    }
}

enum RecoveryError: LocalizedError {
    case sourceMissing(String)
    case cannotEnumerate(String)
    case cannotCreateOutput(String)
    case cannotOpen(String)
    case deviceAccessDenied(String)
    case readFailed(String, UInt64)
    case destinationOnSourceDisk

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "Source does not exist: \(path)"
        case .cannotEnumerate(let path): "Cannot enumerate source: \(path)"
        case .cannotCreateOutput(let path): "Cannot create output file: \(path)"
        case .cannotOpen(let path): "Cannot open: \(path)"
        case .deviceAccessDenied(let path): "Access to \(path) was denied. Recovery requires authorization to read the drive."
        case .readFailed(let name, let offset): "Read failed in \(name) at offset \(offset)"
        case .destinationOnSourceDisk: "The destination folder is on the disk being scanned. Choose a folder on a different disk, or the recovery would overwrite the deleted data it is trying to save."
        }
    }
}
