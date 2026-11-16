import Foundation
import Testing
@testable import FileRecoveryApp

/// End-to-end check against a real exFAT filesystem produced by macOS:
/// create an image, write a JPEG, delete it, then scan the raw image and
/// expect the deleted file back with its original name.
@Suite struct ExfatIntegrationTests {
    /// 5 June 2021, 10:11:12 local time: even seconds, as FAT keeps 2 s steps.
    private var knownDate: Date {
        Calendar.current.date(from: DateComponents(year: 2021, month: 6, day: 5, hour: 10, minute: 11, second: 12))!
    }

    private func run(_ command: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return output
    }

    @Test func recoversDeletedJPEGNameFromRealExfatImage() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exfat-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let imageURL = workDir.appendingPathComponent("volume.dmg")

        _ = try run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "ExFAT", "-volname", "FRTEST", "-layout", "NONE", imageURL.path])
        let attachOutput = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imageURL.path])
        let mountPoint = try #require(
            attachOutput.split(separator: "\n").compactMap { line -> String? in
                guard let range = line.range(of: "/Volumes/") else { return nil }
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }.first
        )

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x11, count: 150_000) + [0xFF, 0xD9])
        let fileURL = URL(fileURLWithPath: mountPoint).appendingPathComponent("vacation.jpg")
        try jpeg.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: knownDate], ofItemAtPath: fileURL.path)
        try FileManager.default.removeItem(at: fileURL)
        _ = try run("/usr/bin/hdiutil", ["detach", mountPoint])

        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .path(imageURL))
        #expect(!plan.deletedFiles.isEmpty, "expected deleted directory entries, note: \(plan.note ?? "nil")")

        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })
        let recovered = try #require(items.first, "no JPEG carved from free space")
        #expect(recovered.originalFilename == "vacation.jpg")
        #expect(recovered.byteLength == UInt64(jpeg.count))
        #expect(recovered.modifiedDate == knownDate)

        // The recovered copy carries the original date, not today's.
        let out = workDir.appendingPathComponent("out", isDirectory: true)
        let written = try scanner.recover(recovered, to: out)
        #expect(written.lastPathComponent == "vacation.jpg")
        let attributes = try FileManager.default.attributesOfItem(atPath: written.path)
        #expect(attributes[.modificationDate] as? Date == knownDate)
        #expect(attributes[.creationDate] as? Date == knownDate)
    }

    /// Unmounts a throwaway disk image and checks the volume is gone while
    /// the device stays attached, which is what a scan needs.
    @Test func unmountLeavesDeviceAttached() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unmount-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let imageURL = workDir.appendingPathComponent("volume.dmg")

        _ = try run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "ExFAT", "-volname", "FRUNMOUNT", "-layout", "NONE", imageURL.path])
        let attachOutput = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imageURL.path])
        let line = try #require(attachOutput.split(separator: "\n").first { $0.contains("/Volumes/") })
        let devicePath = try #require(line.split(whereSeparator: \.isWhitespace).first.map(String.init))
        let mountPoint = String(line[line.range(of: "/Volumes/")!.lowerBound...]).trimmingCharacters(in: .whitespaces)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", devicePath]) }

        let identifier = String(devicePath.dropFirst("/dev/".count))
        #expect(DeviceDiscovery.bsdName(forPath: mountPoint) == identifier)

        let device = ExternalDevice(identifier: identifier, volumeName: "FRUNMOUNT", size: 16 << 20, isWholeDisk: false)
        #expect(DeviceDiscovery.unmount(device) == nil)
        #expect(DeviceDiscovery.bsdName(forPath: mountPoint) != identifier)
        #expect(FileManager.default.fileExists(atPath: devicePath))

        // An unknown device reports diskutil's message instead of succeeding.
        let missing = ExternalDevice(identifier: "disk9999s9", volumeName: nil, size: 0, isWholeDisk: false)
        #expect(DeviceDiscovery.unmount(missing) != nil)
    }

    /// The same end-to-end check on FAT32, which most SD cards use: a long
    /// name in the root, one in a live folder, and one in a deleted folder.
    @Test func recoversDeletedNamesFromRealFAT32Image() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fat32-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let imageURL = workDir.appendingPathComponent("volume.dmg")

        _ = try run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "MS-DOS FAT32", "-volname", "FRFAT", "-layout", "NONE", imageURL.path])
        let attachOutput = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imageURL.path])
        let mountPoint = try #require(
            attachOutput.split(separator: "\n").compactMap { line -> String? in
                guard let range = line.range(of: "/Volumes/") else { return nil }
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }.first
        )
        let root = URL(fileURLWithPath: mountPoint)
        func jpeg(_ fill: UInt8) -> Data {
            Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: fill, count: 150_000) + [0xFF, 0xD9])
        }
        let kept = root.appendingPathComponent("Kept Folder", isDirectory: true)
        let gone = root.appendingPathComponent("Deleted Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let files = [
            root.appendingPathComponent("Summer Vacation 2021.jpg"),
            kept.appendingPathComponent("birthday party.jpg"),
            gone.appendingPathComponent("IMG_0042.JPG"),
        ]
        for (index, file) in files.enumerated() {
            try jpeg(UInt8(0x11 + index)).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: knownDate], ofItemAtPath: file.path)
        }
        try FileManager.default.removeItem(at: files[0])
        try FileManager.default.removeItem(at: files[1])
        try FileManager.default.removeItem(at: gone)
        _ = try run("/usr/bin/hdiutil", ["detach", mountPoint])

        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .path(imageURL))
        #expect(plan.note?.contains("FAT32") == true)
        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })
        let names = Set(items.compactMap(\.originalFilename))
        // IMG_0042.JPG fits 8.3, so it has no long-name entry, and FAT32
        // overwrites a deleted short name's first character. "_" stands in.
        #expect(names == ["Summer Vacation 2021.jpg", "birthday party.jpg", "_MG_0042.JPG"])
        #expect(items.allSatisfy { $0.byteLength == 150_006 })
        // FAT32 keeps wall-clock time with no zone. A camera writes its own
        // clock, which is what the reader assumes. macOS instead writes the
        // time shifted by today's UTC offset, not the offset in force on the
        // file's date, so across a daylight-saving change its stamps read back
        // an hour out. Allow that hour here; nothing on disk says who wrote it.
        for item in items {
            let modified = try #require(item.modifiedDate)
            #expect(abs(modified.timeIntervalSince(knownDate)) <= 3600)
        }
    }
}
