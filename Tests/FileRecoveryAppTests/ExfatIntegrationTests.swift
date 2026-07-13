import Foundation
import Testing
@testable import FileRecoveryApp

/// End-to-end check against a real exFAT filesystem produced by macOS:
/// create an image, write a JPEG, delete it, then scan the raw image and
/// expect the deleted file back with its original name.
@Suite struct ExfatIntegrationTests {
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
        try FileManager.default.removeItem(at: fileURL)
        _ = try run("/usr/bin/hdiutil", ["detach", mountPoint])

        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .path(imageURL))
        #expect(!plan.deletedFiles.isEmpty, "expected deleted directory entries, note: \(plan.note ?? "nil")")

        let items = try await scanner.scan(plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in })
        let recovered = try #require(items.first, "no JPEG carved from free space")
        #expect(recovered.originalFilename == "vacation.jpg")
        #expect(recovered.byteLength == UInt64(jpeg.count))
    }
}
