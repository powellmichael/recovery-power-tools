import Foundation
import Testing
@testable import FileRecoveryApp

@Suite struct NTFSTests {
    @Test func decodesDataRuns() {
        // Classic two-run example: 0x14 clusters at LCN 0x100, then a
        // relative jump of -0x10 to LCN 0xF0 for 0x10 clusters.
        let bytes: [UInt8] = [0x21, 0x14, 0x00, 0x01, 0x11, 0x10, 0xF0, 0x00]
        let runs = NTFS.decodeRuns(bytes, from: 0, to: bytes.count)
        #expect(runs.count == 2)
        #expect(runs[0] == (0x100, 0x14))
        #expect(runs[1] == (0xF0, 0x10))
    }

    @Test func parsesSyntheticNTFSVolume() async throws {
        // 1 MB volume: 512-byte sectors and clusters, 1024-byte MFT records.
        // MFT at cluster 4, $Bitmap data at cluster 40, deleted "photo.jpg"
        // fragmented across clusters 100.. and 200..
        let sector = 512
        let recordSize = 1024
        let totalSectors = 2048
        var image = [UInt8](repeating: 0, count: sector * totalSectors)

        func put16(_ at: Int, _ v: UInt16, into a: inout [UInt8]) { a[at] = UInt8(v & 0xFF); a[at + 1] = UInt8(v >> 8) }
        func put32(_ at: Int, _ v: UInt32, into a: inout [UInt8]) { for k in 0..<4 { a[at + k] = UInt8(v >> (8 * k) & 0xFF) } }
        func put64(_ at: Int, _ v: UInt64, into a: inout [UInt8]) { for k in 0..<8 { a[at + k] = UInt8(v >> (8 * k) & 0xFF) } }

        // Boot sector
        image[3...10] = ArraySlice(Array("NTFS    ".utf8))
        put16(11, UInt16(sector), into: &image)
        image[13] = 1 // sectors per cluster
        put64(40, UInt64(totalSectors), into: &image)
        put64(48, 4, into: &image) // MFT at cluster 4
        image[64] = 0xF6 // MFT record size: 2^10 = 1024

        func dataAttr(runs: [UInt8], realSize: UInt64) -> [UInt8] {
            let runsPadded = runs + [UInt8](repeating: 0, count: (8 - runs.count % 8) % 8)
            var a = [UInt8](repeating: 0, count: 64 + runsPadded.count)
            put32(0, 0x80, into: &a)
            put32(4, UInt32(a.count), into: &a)
            a[8] = 1 // nonresident
            put16(32, 64, into: &a) // runlist offset
            put64(40, realSize, into: &a)
            put64(48, realSize, into: &a)
            a[64...] = ArraySlice(runsPadded)
            return a
        }

        func fileNameAttr(_ name: String) -> [UInt8] {
            let units = Array(name.utf16)
            let contentLength = 66 + units.count * 2
            let padded = contentLength + (8 - contentLength % 8) % 8
            var a = [UInt8](repeating: 0, count: 24 + padded)
            put32(0, 0x30, into: &a)
            put32(4, UInt32(a.count), into: &a)
            put32(16, UInt32(contentLength), into: &a)
            put16(20, 24, into: &a)
            a[24 + 64] = UInt8(units.count)
            a[24 + 65] = 1 // Win32 namespace
            for (k, unit) in units.enumerated() {
                a[24 + 66 + 2 * k] = UInt8(unit & 0xFF)
                a[24 + 67 + 2 * k] = UInt8(unit >> 8)
            }
            return a
        }

        func makeRecord(inUse: Bool, attrs: [[UInt8]]) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: recordSize)
            r[0...3] = ArraySlice(Array("FILE".utf8))
            put16(4, 48, into: &r) // USA offset
            put16(6, 3, into: &r)  // USA count (USN + 2 sectors)
            put16(20, 56, into: &r) // first attribute offset
            put16(22, inUse ? 1 : 0, into: &r)
            var pos = 56
            for attr in attrs {
                r[pos..<pos + attr.count] = ArraySlice(attr)
                pos += attr.count
            }
            put32(pos, 0xFFFF_FFFF, into: &r)
            // Fixups: USN 0x1337, real end-of-sector bytes saved into the USA.
            r[48] = 0x37; r[49] = 0x13
            r[50] = r[510]; r[51] = r[511]; r[510] = 0x37; r[511] = 0x13
            r[52] = r[1022]; r[53] = r[1023]; r[1022] = 0x37; r[1023] = 0x13
            return r
        }

        let mftStart = 4 * sector
        func placeRecord(_ index: Int, _ record: [UInt8]) {
            let at = mftStart + index * recordSize
            image[at..<at + recordSize] = ArraySlice(record)
        }

        // Record 0: $MFT — 16 records = 32 clusters at cluster 4.
        placeRecord(0, makeRecord(inUse: true, attrs: [dataAttr(runs: [0x11, 0x20, 0x04], realSize: 16 * 1024)]))

        // Record 6: $Bitmap — 1 cluster at cluster 40, 256 bytes (2048 clusters / 8).
        placeRecord(6, makeRecord(inUse: true, attrs: [dataAttr(runs: [0x11, 0x01, 0x28], realSize: 256)]))

        // Deleted photo.jpg fragmented in two runs: 2 clusters at 100, then
        // a relative jump of +100 to cluster 200 for 1 cluster.
        let jpegPart1 = [0xFF, 0xD8, 0xFF, 0xE0] as [UInt8] + [UInt8](repeating: 0x11, count: 2 * sector - 4)
        let jpegPart2 = [UInt8](repeating: 0x22, count: 300) + [0xFF, 0xD9]
        let jpegSize = UInt64(jpegPart1.count + jpegPart2.count)
        placeRecord(8, makeRecord(inUse: false, attrs: [
            fileNameAttr("photo.jpg"),
            dataAttr(runs: [0x11, 0x02, 0x64, 0x11, 0x01, 0x64], realSize: jpegSize),
        ]))

        image[100 * sector..<100 * sector + jpegPart1.count] = ArraySlice(jpegPart1)
        image[200 * sector..<200 * sector + jpegPart2.count] = ArraySlice(jpegPart2)

        // $Bitmap data at cluster 40: clusters 0-47 allocated, rest free.
        for i in 0..<6 { image[40 * sector + i] = 0xFF }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ntfs-test-\(UUID().uuidString).bin")
        try Data(image).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try ScanSource(fileURL: url)
        let map = try #require(try FreeSpaceMap.read(from: source))
        #expect(map.filesystem == "NTFS")

        // Free space starts at cluster 48.
        #expect(map.regions.first?.lowerBound == UInt64(48 * sector))

        let entry = try #require(map.deletedFiles[UInt64(100 * sector)])
        #expect(entry.name == "photo.jpg")
        #expect(entry.length == jpegSize)
        #expect(entry.segments == [
            UInt64(100 * sector)..<UInt64(102 * sector),
            UInt64(200 * sector)..<UInt64(201 * sector),
        ])

        // Full pipeline: scan finds it by name; recovery stitches both runs.
        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .path(url))
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })
        let item = try #require(items.first { $0.originalFilename == "photo.jpg" })
        #expect(item.byteLength == jpegSize)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfs-test-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let recovered = try scanner.recover(item, to: destination)
        let bytes = [UInt8](try Data(contentsOf: recovered))
        #expect(bytes == jpegPart1 + jpegPart2)
    }
}
