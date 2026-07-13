import Foundation

struct RecoveryScanner: Sendable {
    private let chunkSize = 4 * 1024 * 1024
    private let overlapSize = 128 * 1024
    private let maxSingleFileSize = 2 * 1024 * 1024 * 1024

    func scan(
        source: URL,
        selectedKinds: Set<MediaKind>,
        progress: @escaping @Sendable (ScanProgress) async -> Void,
        itemFound: @escaping @Sendable (RecoveredItem) async -> Void
    ) async throws -> [RecoveredItem] {
        let files = try discoverReadableInputs(at: source)
        let totalBytes = try files.reduce(UInt64(0)) { partial, url in
            partial + (try fileSize(url))
        }

        var allItems: [RecoveredItem] = []
        var bytesScanned: UInt64 = 0

        for file in files {
            try Task.checkCancellation()
            let fileItems = try await scanFile(
                file,
                totalBytes: totalBytes,
                scannedBeforeFile: bytesScanned,
                selectedKinds: selectedKinds,
                progress: progress,
                itemFound: itemFound
            )
            allItems.append(contentsOf: fileItems)
            bytesScanned += try fileSize(file)
        }

        return allItems
    }

    func recover(_ item: RecoveredItem, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputURL = uniqueOutputURL(for: item, in: destination)

        let input = try FileHandle(forReadingFrom: item.sourceURL)
        defer { try? input.close() }

        try input.seek(toOffset: item.byteOffset)
        let output = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard output else {
            throw RecoveryError.cannotCreateOutput(outputURL.path)
        }

        let writer = try FileHandle(forWritingTo: outputURL)
        defer { try? writer.close() }

        var remaining = item.byteLength
        while remaining > 0 {
            let amount = min(UInt64(chunkSize), remaining)
            let data = try input.read(upToCount: Int(amount)) ?? Data()
            guard !data.isEmpty else { break }
            try writer.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }

        return outputURL
    }

    private func scanFile(
        _ url: URL,
        totalBytes: UInt64,
        scannedBeforeFile: UInt64,
        selectedKinds: Set<MediaKind>,
        progress: @escaping @Sendable (ScanProgress) async -> Void,
        itemFound: @escaping @Sendable (RecoveredItem) async -> Void
    ) async throws -> [RecoveredItem] {
        let fileSize = try fileSize(url)
        guard fileSize > 0 else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var items: [RecoveredItem] = []
        var absoluteOffset: UInt64 = 0
        var carry = Data()
        var lastReportedOffset: UInt64 = 0

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }

            var buffer = carry
            buffer.append(chunk)
            let bufferBaseOffset = absoluteOffset >= UInt64(carry.count) ? absoluteOffset - UInt64(carry.count) : 0
            let searchLimit = max(0, buffer.count - overlapSize)

            for candidate in try findCandidates(in: buffer, sourceURL: url, fileSize: fileSize, baseOffset: bufferBaseOffset, searchLimit: searchLimit, selectedKinds: selectedKinds) {
                guard candidate.byteOffset + candidate.byteLength <= fileSize else { continue }
                guard !overlapsExisting(candidate, in: items) else { continue }
                items.append(candidate)
                await itemFound(candidate)
            }

            absoluteOffset += UInt64(chunk.count)
            let carryCount = min(overlapSize, buffer.count)
            carry = buffer.suffix(carryCount)

            if absoluteOffset - lastReportedOffset >= UInt64(chunkSize) || absoluteOffset == fileSize {
                lastReportedOffset = absoluteOffset
                await progress(ScanProgress(
                    bytesScanned: scannedBeforeFile + absoluteOffset,
                    totalBytes: totalBytes,
                    currentPath: url.path
                ))
            }
        }

        if !carry.isEmpty {
            let bufferBaseOffset = fileSize >= UInt64(carry.count) ? fileSize - UInt64(carry.count) : 0
            for candidate in try findCandidates(in: carry, sourceURL: url, fileSize: fileSize, baseOffset: bufferBaseOffset, searchLimit: carry.count, selectedKinds: selectedKinds) {
                guard candidate.byteOffset + candidate.byteLength <= fileSize else { continue }
                guard !overlapsExisting(candidate, in: items) else { continue }
                items.append(candidate)
                await itemFound(candidate)
            }
        }

        return items.sorted { $0.byteOffset < $1.byteOffset }
    }

    private func findCandidates(
        in data: Data,
        sourceURL: URL,
        fileSize: UInt64,
        baseOffset: UInt64,
        searchLimit: Int,
        selectedKinds: Set<MediaKind>
    ) throws -> [RecoveredItem] {
        var results: [RecoveredItem] = []
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }

        var index = 0
        while index < searchLimit {
            let absoluteOffset = baseOffset + UInt64(index)

            if selectedKinds.contains(.jpeg), isJPEGStart(bytes, at: index),
               let length = try findJPEGLength(in: sourceURL, from: absoluteOffset, fileSize: fileSize) {
                results.append(item(.jpeg, sourceURL: sourceURL, byteOffset: absoluteOffset, byteLength: length))
                index += Int(min(length, UInt64(Int.max - index)))
                continue
            }

            if selectedKinds.contains(.png), isPNGStart(bytes, at: index),
               let length = try findPNGLength(in: sourceURL, from: absoluteOffset, fileSize: fileSize) {
                results.append(item(.png, sourceURL: sourceURL, byteOffset: absoluteOffset, byteLength: length))
                index += Int(min(length, UInt64(Int.max - index)))
                continue
            }

            if index >= 4, isFtypBox(bytes, at: index) {
                let start = index - 4
                let absoluteStart = baseOffset + UInt64(start)
                if let mediaKind = mediaKindForFtyp(bytes, at: index), selectedKinds.contains(mediaKind),
                   let length = try parseISOBaseMediaLength(in: sourceURL, from: absoluteStart, fileSize: fileSize) {
                    results.append(item(mediaKind, sourceURL: sourceURL, byteOffset: absoluteStart, byteLength: length))
                    index = start + Int(min(length, UInt64(Int.max - start)))
                    continue
                }
            }

            index += 1
        }

        return results
    }

    private func item(_ kind: MediaKind, sourceURL: URL, byteOffset: UInt64, byteLength: UInt64) -> RecoveredItem {
        RecoveredItem(
            kind: kind,
            sourceURL: sourceURL,
            byteOffset: byteOffset,
            byteLength: byteLength
        )
    }

    private func overlapsExisting(_ item: RecoveredItem, in items: [RecoveredItem]) -> Bool {
        items.contains { existing in
            let existingEnd = existing.byteOffset + existing.byteLength
            let itemEnd = item.byteOffset + item.byteLength
            return item.byteOffset < existingEnd && existing.byteOffset < itemEnd
        }
    }

    private func isJPEGStart(_ bytes: [UInt8], at index: Int) -> Bool {
        index + 2 < bytes.count && bytes[index] == 0xFF && bytes[index + 1] == 0xD8 && bytes[index + 2] == 0xFF
    }

    private func isPNGStart(_ bytes: [UInt8], at index: Int) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard index + signature.count <= bytes.count else { return false }
        return Array(bytes[index..<index + signature.count]) == signature
    }

    private func isFtypBox(_ bytes: [UInt8], at index: Int) -> Bool {
        index + 4 <= bytes.count &&
            bytes[index] == 0x66 &&
            bytes[index + 1] == 0x74 &&
            bytes[index + 2] == 0x79 &&
            bytes[index + 3] == 0x70
    }

    private func mediaKindForFtyp(_ bytes: [UInt8], at ftypIndex: Int) -> MediaKind? {
        guard ftypIndex + 12 <= bytes.count else { return nil }
        let brandData = Data(bytes[ftypIndex + 4..<min(bytes.count, ftypIndex + 28)])
        guard let brands = String(data: brandData, encoding: .ascii) else { return nil }

        if brands.contains("heic") || brands.contains("heix") || brands.contains("mif1") || brands.contains("msf1") {
            return .heic
        }

        if brands.contains("qt  ") || brands.contains("mp41") || brands.contains("mp42") || brands.contains("isom") || brands.contains("avc1") {
            return .video
        }

        return nil
    }

    private func findJPEGLength(in url: URL, from startOffset: UInt64, fileSize: UInt64) throws -> UInt64? {
        let marker: [UInt8] = [0xFF, 0xD9]
        return try findMarkerLength(in: url, startOffset: startOffset, searchOffset: startOffset + 3, fileSize: fileSize, marker: marker)
    }

    private func findPNGLength(in url: URL, from startOffset: UInt64, fileSize: UInt64) throws -> UInt64? {
        let marker: [UInt8] = [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        return try findMarkerLength(in: url, startOffset: startOffset, searchOffset: startOffset + 8, fileSize: fileSize, marker: marker)
    }

    private func findMarkerLength(in url: URL, startOffset: UInt64, searchOffset: UInt64, fileSize: UInt64, marker: [UInt8]) throws -> UInt64? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: searchOffset)

        var absoluteOffset = searchOffset
        var carry = Data()
        while absoluteOffset < fileSize {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            guard !data.isEmpty else { break }

            var buffer = carry
            buffer.append(data)
            let bytes = [UInt8](buffer)
            let bufferBase = absoluteOffset >= UInt64(carry.count) ? absoluteOffset - UInt64(carry.count) : 0

            var index = 0
            while index + marker.count <= bytes.count {
                if Array(bytes[index..<index + marker.count]) == marker {
                    let endOffset = bufferBase + UInt64(index) + UInt64(marker.count)
                    return endOffset - startOffset
                }
                index += 1
            }

            absoluteOffset += UInt64(data.count)
            carry = buffer.suffix(marker.count - 1)
        }

        return nil
    }

    private func parseISOBaseMediaLength(in url: URL, from startOffset: UInt64, fileSize: UInt64) throws -> UInt64? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var cursor = startOffset
        var parsedLength: UInt64 = 0
        while cursor + 8 <= fileSize {
            try handle.seek(toOffset: cursor)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            let size32 = UInt32(bytes[0]) << 24 |
                UInt32(bytes[1]) << 16 |
                UInt32(bytes[2]) << 8 |
                UInt32(bytes[3])
            let boxType = String(bytes: bytes[4..<8], encoding: .ascii) ?? ""

            var boxSize = UInt64(size32)
            if size32 == 1 {
                guard bytes.count >= 16 else { break }
                boxSize = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                parsedLength = fileSize - startOffset
                break
            }

            guard boxSize >= 8, cursor + boxSize <= fileSize, boxSize <= UInt64(maxSingleFileSize) else { break }
            parsedLength = (cursor + boxSize) - startOffset
            cursor += boxSize

            if boxType == "mdat" || parsedLength >= UInt64(maxSingleFileSize) {
                break
            }
        }

        return parsedLength > 16 ? parsedLength : nil
    }

    private func discoverReadableInputs(at source: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw RecoveryError.sourceMissing(source.path)
        }

        if !isDirectory.boolValue {
            return [source]
        }

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
                files.append(url)
            }
        }

        return files
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize {
            return UInt64(size)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? UInt64 ?? 0
    }

    private func uniqueOutputURL(for item: RecoveredItem, in destination: URL) -> URL {
        var candidate = destination.appendingPathComponent(item.displayName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = item.displayName.replacingOccurrences(of: ".\(item.kind.fileExtension)", with: "")
            candidate = destination.appendingPathComponent("\(base)-\(counter).\(item.kind.fileExtension)")
            counter += 1
        }
        return candidate
    }
}

enum RecoveryError: LocalizedError {
    case sourceMissing(String)
    case cannotEnumerate(String)
    case cannotCreateOutput(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): "Source does not exist: \(path)"
        case .cannotEnumerate(let path): "Cannot enumerate source: \(path)"
        case .cannotCreateOutput(let path): "Cannot create output file: \(path)"
        }
    }
}
