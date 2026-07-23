import Foundation
import Testing
@testable import FileRecoveryApp

private func makeTempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-test-\(UUID().uuidString).bin")
    try data.write(to: url)
    return url
}

private func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

private func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

@Suite struct CarverTests {
    @Test func carvesSyntheticBlob() async throws {
        var blob: [UInt8] = []
        var expected: [(MediaKind, UInt64, UInt64)] = [] // kind, offset, length
        func junk(_ count: Int) { blob.append(contentsOf: [UInt8](repeating: 0xAA, count: count)) }
        func record(_ kind: MediaKind, _ payload: [UInt8]) {
            expected.append((kind, UInt64(blob.count), UInt64(payload.count)))
            blob.append(contentsOf: payload)
        }

        junk(512)

        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        jpeg += [UInt8](repeating: 0x11, count: 100)
        jpeg += [0xFF, 0xD9]
        record(.jpeg, jpeg)

        junk(64)

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += [UInt8](repeating: 0x00, count: 20)
        png += [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        record(.png, png)

        junk(33)

        var bmp: [UInt8] = [0x42, 0x4D]
        bmp += le32(70)                 // file size
        bmp += [0, 0, 0, 0]             // reserved
        bmp += le32(54)                 // pixel data offset
        bmp += le32(40)                 // DIB header size
        bmp += [UInt8](repeating: 0, count: 70 - bmp.count)
        record(.bmp, bmp)

        junk(17)

        var zipData: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        zipData += [UInt8](repeating: 0x00, count: 26)
        zipData += [0x50, 0x4B, 0x05, 0x06]
        zipData += [UInt8](repeating: 0x00, count: 18) // EOCD fields, comment length 0
        record(.zip, zipData)

        junk(99)

        var mp4 = be32(16)
        mp4 += Array("ftypisom".utf8)
        mp4 += [UInt8](repeating: 0x00, count: 4)
        mp4 += be32(24)
        mp4 += Array("mdat".utf8)
        mp4 += [UInt8](repeating: 0x33, count: 16)
        record(.video, mp4)

        junk(256)

        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        let scanner = RecoveryScanner()
        let items = try await scanner.scan(
            plan: plan,
            selectedKinds: Set(MediaKind.allCases),
            progress: { _ in },
            itemFound: { _ in }
        )

        #expect(items.count == expected.count)
        for (item, (kind, offset, length)) in zip(items.sorted { $0.byteOffset < $1.byteOffset }, expected) {
            #expect(item.kind == kind)
            #expect(item.byteOffset == offset)
            #expect(item.byteLength == length)
        }
    }

    @Test func recoveredBytesMatchSource() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 100)
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x42, count: 50) + [0xFF, 0xD9]
        blob += jpeg
        blob += [UInt8](repeating: 0xAA, count: 100)

        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        let scanner = RecoveryScanner()
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })
        let item = try #require(items.first)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-test-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let recovered = try scanner.recover(item, to: destination)
        let recoveredBytes = [UInt8](try Data(contentsOf: recovered))
        #expect(recoveredBytes == jpeg)
    }

    /// An EXIF thumbnail is a whole JPEG nested inside APP1, so its FFD9 comes
    /// before the outer image's. Scanning for the first FFD9 truncates the file
    /// to the header; segment walking must skip APP1 wholesale.
    @Test func exifThumbnailDoesNotTruncateJPEG() async throws {
        var thumbnail: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        thumbnail += [0x00, 0x10] + [UInt8](repeating: 0x11, count: 14)
        thumbnail += [0xFF, 0xD9] // the decoy end marker

        // APP1: FFE1, 2-byte length covering itself, then the nested thumbnail.
        let app1Length = thumbnail.count + 2
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1]
        jpeg += [UInt8(app1Length >> 8 & 0xFF), UInt8(app1Length & 0xFF)]
        jpeg += thumbnail

        // SOS, then entropy data exercising FF00 stuffing and a restart marker.
        jpeg += [0xFF, 0xDA, 0x00, 0x08] + [UInt8](repeating: 0x01, count: 6)
        jpeg += [0x37, 0xFF, 0x00, 0x42, 0xFF, 0xD0, 0x9C]
        jpeg += [0xFF, 0xD9] // the real end marker

        var blob = [UInt8](repeating: 0xAA, count: 128)
        let start = blob.count
        blob += jpeg
        blob += [UInt8](repeating: 0xAA, count: 128)

        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        let scanner = RecoveryScanner()
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })

        let item = try #require(items.first { $0.byteOffset == UInt64(start) })
        #expect(item.byteLength == UInt64(jpeg.count))
    }
}

@Suite struct FreeSpaceTests {
    @Test func parsesFAT32FreeClusters() throws {
        // 512-byte sectors, 1 sector/cluster, 1 reserved, 1 FAT sector, 34 sectors total.
        let bytesPerSector = 512
        let totalSectors: UInt32 = 34
        var image = [UInt8](repeating: 0, count: Int(totalSectors) * bytesPerSector)

        image[11] = 0x00; image[12] = 0x02      // bytes per sector = 512
        image[13] = 1                            // sectors per cluster
        image[14] = 1; image[15] = 0             // reserved sectors
        image[16] = 1                            // FAT count
        image[32...35] = ArraySlice(le32(totalSectors))
        image[36...39] = ArraySlice(le32(1))     // sectors per FAT
        image[82...89] = ArraySlice(Array("FAT32   ".utf8))

        // FAT at sector 1. Entries 0/1 reserved; cluster 2 used, 3 free, 4 used,
        // 5-6 free, rest used.
        func setFAT(_ cluster: Int, _ value: UInt32) {
            let at = bytesPerSector + cluster * 4
            image[at..<at + 4] = ArraySlice(le32(value))
        }
        let used: UInt32 = 0x0FFF_FFFF
        setFAT(0, 0x0FFF_FFF8)
        setFAT(1, used)
        let dataStartSector = 2 // reserved + FAT
        let clusterCount = (Int(totalSectors) - dataStartSector) / 1
        for cluster in 2..<(2 + clusterCount) {
            setFAT(cluster, [3, 5, 6].contains(cluster) ? 0 : used)
        }

        let url = try makeTempFile(Data(image))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let map = try #require(try FreeSpaceMap.read(from: source))
        #expect(map.filesystem == "FAT32")

        let dataStart = UInt64(dataStartSector * bytesPerSector)
        func clusterRange(_ first: Int, _ count: Int) -> Range<UInt64> {
            let lower = dataStart + UInt64(first - 2) * 512
            return lower..<(lower + UInt64(count) * 512)
        }
        #expect(map.regions == [clusterRange(3, 1), clusterRange(5, 2)])
    }

    @Test func parsesExfatDeletedEntries() throws {
        // 512-byte sectors/clusters. FAT at sector 1, cluster heap at sector 4,
        // 16 clusters. Root dir = cluster 2, allocation bitmap = cluster 3.
        let sector = 512
        var image = [UInt8](repeating: 0, count: sector * 24)

        image[3...10] = ArraySlice(Array("EXFAT   ".utf8))
        image[80...83] = ArraySlice(le32(1))    // FAT offset (sectors)
        image[84...87] = ArraySlice(le32(1))    // FAT length
        image[88...91] = ArraySlice(le32(4))    // cluster heap offset (sectors)
        image[92...95] = ArraySlice(le32(16))   // cluster count
        image[96...99] = ArraySlice(le32(2))    // root dir cluster
        image[108] = 9                          // bytes per sector shift
        image[109] = 0                          // sectors per cluster shift

        let heapStart = 4 * sector

        // Root directory (cluster 2): bitmap entry, then a deleted file set.
        var dir = heapStart
        image[dir] = 0x81                                   // allocation bitmap entry
        image[dir + 20...dir + 23] = ArraySlice(le32(3))    // bitmap at cluster 3
        image[dir + 24] = 2                                 // bitmap length (2 bytes)
        dir += 32

        image[dir] = 0x05                                   // deleted file entry
        image[dir + 1] = 2                                  // two secondary entries
        image[dir + 4] = 0x20                               // archive attribute
        dir += 32
        image[dir] = 0x40                                   // deleted stream extension
        image[dir + 1] = 0x02                               // NoFatChain
        image[dir + 3] = 9                                  // name length
        image[dir + 20...dir + 23] = ArraySlice(le32(5))    // first cluster
        image[dir + 24...dir + 27] = ArraySlice(le32(1234)) // data length
        dir += 32
        image[dir] = 0x41                                   // deleted file name entry
        for (i, unit) in "photo.jpg".utf16.enumerated() {
            image[dir + 2 + 2 * i] = UInt8(unit & 0xFF)
            image[dir + 3 + 2 * i] = UInt8(unit >> 8)
        }

        // Bitmap (cluster 3): clusters 2 and 3 used, the rest free.
        image[heapStart + sector] = 0b0000_0011

        let url = try makeTempFile(Data(image))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let map = try #require(try FreeSpaceMap.read(from: source))
        #expect(map.filesystem == "exFAT")

        // Cluster 5 starts at heapStart + 3 clusters.
        let expectedOffset = UInt64(heapStart + 3 * sector)
        #expect(map.deletedFiles == [expectedOffset: DeletedFileEntry(name: "photo.jpg", length: 1234)])
    }
}

@Suite struct DuplicateTests {
    /// Builds a JPEG whose header bytes are seeded so two files can be made
    /// identical or distinct on demand.
    private func jpeg(seed: UInt8, payload: Int = 200) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        bytes += [UInt8](repeating: seed, count: 10)
        bytes += [0xFF, 0xDA, 0x00, 0x08] + [UInt8](repeating: 0x01, count: 6)
        bytes += [UInt8](repeating: seed, count: payload)
        bytes += [0xFF, 0xD9]
        return bytes
    }

    private func scan(_ blob: [UInt8]) async throws -> [RecoveredItem] {
        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        return try await RecoveryScanner().scan(
            plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in }
        )
    }

    @Test func flagsSecondCopyOfIdenticalFile() async throws {
        let copy = jpeg(seed: 0x42)
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += copy
        blob += [UInt8](repeating: 0xAA, count: 64)
        blob += copy

        let items = try await scan(blob)
        #expect(items.count == 2)
        // First occurrence is the keeper; only the later one is flagged.
        #expect(items[0].isDuplicate == false)
        #expect(items[1].isDuplicate == true)
    }

    @Test func doesNotFlagDistinctFiles() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpeg(seed: 0x11)
        blob += [UInt8](repeating: 0xAA, count: 64)
        blob += jpeg(seed: 0x99)

        let items = try await scan(blob)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.isDuplicate })
    }

    /// Files sharing an identical first 4 KB but differing in total size must
    /// stay distinct. Payloads exceed the 4 KB prefix on both sides, so only
    /// the length component of the fingerprint can separate them.
    @Test func doesNotFlagSamePrefixDifferentLength() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpeg(seed: 0x55, payload: 5_000)
        blob += [UInt8](repeating: 0xAA, count: 64)
        blob += jpeg(seed: 0x55, payload: 6_000)

        let items = try await scan(blob)
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.isDuplicate })
    }
}

@Suite struct FastScanTests {
    /// A structurally valid JPEG is still recovered in fast mode — fast only
    /// drops the brute-force fallback, not the structural parser.
    @Test func fastScanStillFindsValidJPEG() async throws {
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        jpeg += [UInt8](repeating: 0x11, count: 14)
        jpeg += [0xFF, 0xDA, 0x00, 0x08] + [UInt8](repeating: 0x01, count: 6)
        jpeg += [0x37, 0xFF, 0x00, 0x42]
        jpeg += [0xFF, 0xD9]

        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpeg
        blob += [UInt8](repeating: 0xAA, count: 64)

        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        var scanner = RecoveryScanner()
        scanner.fastScan = true
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })

        let item = try #require(items.first { $0.byteOffset == 64 })
        #expect(item.byteLength == UInt64(jpeg.count))
    }

    /// A JPEG header with no valid segment structure and no EOI: thorough mode
    /// would scan forward for FFD9; fast mode drops it, so nothing is emitted.
    @Test func fastScanSkipsUnstructuredHeader() async throws {
        // FFD8FF then bytes with no valid marker structure and no FFD9 anywhere.
        var blob: [UInt8] = [0xFF, 0xD8, 0xFF, 0x42]
        for i in 0..<4096 {
            let b = UInt8((i * 7 + 3) % 251)
            if b != 0xD9 && b != 0xFF { blob.append(b) }
        }

        let url = try makeTempFile(Data(blob))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        var scanner = RecoveryScanner()
        scanner.fastScan = true
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })

        #expect(items.isEmpty)
    }
}
