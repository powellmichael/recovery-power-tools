import Foundation
import Testing
@testable import FileRecoveryApp

/// Every destructive call here runs against a throwaway disk image, never a
/// real drive. Each test erases, then scans the raw image with the recovery
/// engine and expects it to find nothing.
@Suite(.serialized) struct SecureEraserTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x11, count: 150_000) + [0xFF, 0xD9])

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

    private struct Image {
        let imageURL: URL
        let workDir: URL
        let device: ExternalDevice
        let mount: URL
    }

    private func makeImage(name: String) throws -> Image {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erase-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let imageURL = workDir.appendingPathComponent("volume.dmg")
        _ = try run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "ExFAT", "-volname", name, "-layout", "NONE", imageURL.path])
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", imageURL.path])
        let line = try #require(attach.split(separator: "\n").first { $0.contains("/Volumes/") })
        let identifier = try #require(line.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let mountPath = String(line[try #require(line.range(of: "/Volumes/")).lowerBound...]).trimmingCharacters(in: .whitespaces)
        let info = try #require(DeviceDiscovery.diskutilPlist(["info", "-plist", "/dev/\(identifier)"]))
        let size = try #require((info["TotalSize"] as? NSNumber)?.uint64Value)
        return Image(
            imageURL: imageURL,
            workDir: workDir,
            device: ExternalDevice(identifier: identifier, volumeName: name, size: size, isWholeDisk: true, filesystemName: "ExFAT"),
            mount: URL(fileURLWithPath: mountPath)
        )
    }

    /// Detaches the image and counts what a recovery scan still finds in it.
    private func recoverableCount(_ image: Image) async throws -> Int {
        _ = try run("/usr/bin/hdiutil", ["detach", "/dev/\(image.device.identifier)"])
        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .path(image.imageURL))
        return try await scanner.scan(plan: plan, selectedKinds: Set(MediaKind.allCases), progress: { _ in }, itemFound: { _ in }).count
    }

    @Test func wipingFreeSpaceDestroysDeletedFilesAndKeepsLiveOnes() async throws {
        let image = try makeImage(name: "WIPEFREE")
        defer { try? FileManager.default.removeItem(at: image.workDir) }
        let deleted = image.mount.appendingPathComponent("deleted.jpg")
        let kept = image.mount.appendingPathComponent("kept.jpg")
        try jpeg.write(to: deleted)
        try jpeg.write(to: kept)
        try FileManager.default.removeItem(at: deleted)

        try await SecureEraser.wipeFreeSpace(image.device) { _ in }

        #expect(try Data(contentsOf: kept) == jpeg)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: image.mount.path).filter { $0.hasPrefix(".rpt-erase") }
        #expect(leftovers.isEmpty)
        #expect(try await recoverableCount(image) == 0)
    }

    @Test func shreddedFileCannotBeRecovered() async throws {
        let image = try makeImage(name: "SHRED")
        defer { try? FileManager.default.removeItem(at: image.workDir) }
        let folder = image.mount.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let loose = image.mount.appendingPathComponent("secret.jpg")
        let nested = folder.appendingPathComponent("inside.jpg")
        try jpeg.write(to: loose)
        try jpeg.write(to: nested)

        let report = try await SecureEraser.shred([loose, folder]) { _ in }

        #expect(report.files == 2)
        #expect(report.bytes == UInt64(jpeg.count * 2))
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: loose.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await recoverableCount(image) == 0)
    }

    /// On a disk image the format alone already discards the old data, so
    /// this proves the flow end to end, not the overwrite. The overwrite is
    /// the same fill that the free-space test does prove.
    @Test func erasingVolumeLeavesNothingRecoverable() async throws {
        let image = try makeImage(name: "ERASEALL")
        defer { try? FileManager.default.removeItem(at: image.workDir) }
        let live = image.mount.appendingPathComponent("live.jpg")
        let deleted = image.mount.appendingPathComponent("deleted.jpg")
        try jpeg.write(to: live)
        try jpeg.write(to: deleted)
        try FileManager.default.removeItem(at: deleted)

        let complete = try await SecureEraser.eraseVolume(image.device, format: .exfat) { _ in }

        #expect(complete)
        let visible = try FileManager.default.contentsOfDirectory(atPath: image.mount.path).filter { !$0.hasPrefix(".") }
        #expect(visible.isEmpty)
        #expect(try await recoverableCount(image) == 0)
    }

    @Test func refusesInternalAndMismatchedDevices() async throws {
        // The startup disk, described as if it were a chosen target.
        let bootName = try #require(DeviceDiscovery.bsdName(forPath: "/"))
        let bootInfo = try #require(DeviceDiscovery.diskutilPlist(["info", "-plist", "/dev/\(bootName)"]))
        let boot = ExternalDevice(
            identifier: bootName,
            volumeName: bootInfo["VolumeName"] as? String,
            size: (bootInfo["TotalSize"] as? NSNumber)?.uint64Value ?? 0,
            isWholeDisk: false
        )
        #expect(throws: EraseError.notExternal(boot.userFacingName)) { try SecureEraser.verify(boot) }

        // A file on the internal disk is reported and left alone.
        let internalFile = FileManager.default.temporaryDirectory.appendingPathComponent("erase-guard-\(UUID().uuidString).jpg")
        try jpeg.write(to: internalFile)
        defer { try? FileManager.default.removeItem(at: internalFile) }
        if !SecureEraser.isOnExternalDisk(internalFile) {
            let report = try await SecureEraser.shred([internalFile]) { _ in }
            #expect(report.files == 0)
            #expect(report.failures.count == 1)
            #expect(try Data(contentsOf: internalFile) == jpeg)
        }

        // Same identifier, but not the size or name that was confirmed.
        let image = try makeImage(name: "GUARD")
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "/dev/\(image.device.identifier)"])
            try? FileManager.default.removeItem(at: image.workDir)
        }
        try jpeg.write(to: image.mount.appendingPathComponent("keep.jpg"))
        var wrongSize = image.device
        wrongSize = ExternalDevice(identifier: wrongSize.identifier, volumeName: wrongSize.volumeName, size: wrongSize.size + 512, isWholeDisk: true)
        let renamed = ExternalDevice(identifier: image.device.identifier, volumeName: "OTHER", size: image.device.size, isWholeDisk: true)
        for imposter in [wrongSize, renamed] {
            await #expect(throws: EraseError.changed(imposter.userFacingName)) {
                _ = try await SecureEraser.eraseVolume(imposter, format: .exfat) { _ in }
            }
        }
        #expect(FileManager.default.fileExists(atPath: image.mount.appendingPathComponent("keep.jpg").path))
    }

    @Test func volumeNamesFitTheFormat() {
        #expect(EraseFormat.fat32.volumeName(from: "My Holiday Photos 2024") == "MY HOLIDAY")
        #expect(EraseFormat.exfat.volumeName(from: "a/b:c") == "abc")
        #expect(EraseFormat.exfat.volumeName(from: nil) == "UNTITLED")
        #expect(EraseFormat.hfs.volumeName(from: "A:B") == "A-B")
    }
}
