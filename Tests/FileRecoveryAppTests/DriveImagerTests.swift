import Foundation
import Testing
@testable import FileRecoveryApp

@Suite struct DriveImagerTests {
    private func workDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 9 MB + 1 KB of non-repeating bytes: more than two chunks, and not a
    /// multiple of the chunk size.
    private func pattern() -> Data {
        var data = Data(count: 9 * 1024 * 1024 + 1024)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 11) | 1 }
        }
        return data
    }

    @Test func copiesEveryByteAndZeroFillsUnreadableBlocks() async throws {
        let dir = try workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = pattern()
        let sourceURL = dir.appendingPathComponent("drive.bin")
        try original.write(to: sourceURL)

        let clean = try await DriveImager.copy(ScanSource(fileURL: sourceURL), to: dir.appendingPathComponent("clean.img")) { _ in }
        #expect(clean == ImagingResult(copied: UInt64(original.count), total: UInt64(original.count), unreadableBytes: 0, stoppedBecause: nil))
        #expect(try Data(contentsOf: dir.appendingPathComponent("clean.img")) == original)

        // One bad 4 KB block in the second chunk.
        let bad: Range<UInt64> = 5_001_216..<5_005_312
        let failing = try ScanSource(fileURL: sourceURL)
        failing.simulatedBadRanges = [bad]
        let result = try await DriveImager.copy(failing, to: dir.appendingPathComponent("salvaged.img")) { _ in }
        #expect(result.stoppedBecause == nil)
        #expect(result.unreadableBytes == 4096)
        var expected = original
        expected.replaceSubrange(Int(bad.lowerBound)..<Int(bad.upperBound), with: Data(count: 4096))
        #expect(try Data(contentsOf: dir.appendingPathComponent("salvaged.img")) == expected)
    }

    @Test func stoppingKeepsThePartialImage() async throws {
        let dir = try workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = pattern()
        let sourceURL = dir.appendingPathComponent("drive.bin")
        try original.write(to: sourceURL)
        let source = try ScanSource(fileURL: sourceURL)
        let out = dir.appendingPathComponent("partial.img")

        let task = Task { try await DriveImager.copy(source, to: out) { _ in } }
        task.cancel()
        let result = try await task.value

        #expect(result.stoppedBecause != nil)
        #expect(result.copied < UInt64(original.count))
        let kept = try Data(contentsOf: out)
        #expect(UInt64(kept.count) == result.copied)
        #expect(kept == original.prefix(kept.count))
    }

    @Test func refusesADestinationOnTheSourceDriveOrWithoutRoom() throws {
        let dir = try workDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("x.img")
        let volume = try #require(DeviceDiscovery.bsdName(forPath: dir.path))
        let same = ExternalDevice(identifier: volume, volumeName: "Here", size: 1024, isWholeDisk: false)
        #expect(throws: ImagingError.sameDisk) { try DriveImager.checkDestination(out, for: same) }

        let huge = ExternalDevice(identifier: "disk999s1", volumeName: "Huge", size: 1 << 60, isWholeDisk: false)
        #expect(throws: ImagingError.self) { try DriveImager.checkDestination(out, for: huge) }
        let small = ExternalDevice(identifier: "disk999s1", volumeName: "Small", size: 1024, isWholeDisk: false)
        #expect(throws: Never.self) { try DriveImager.checkDestination(out, for: small) }
    }
}
