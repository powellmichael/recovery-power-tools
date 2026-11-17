import Foundation
import Testing
@testable import FileRecoveryApp

@Suite struct VerifiedCopierTests {
    private struct Fixture {
        let root: URL
        let card: URL
        let first: URL
        let second: URL
        let contents: [String: Data]
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("CARD", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        for folder in [card.appendingPathComponent("DCIM/100TEST"), first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // One file larger than a chunk, one small, one empty.
        var big = Data(count: 5 * 1024 * 1024 + 7)
        big.withUnsafeMutableBytes { raw in for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 13 &+ i >> 9) } }
        let contents = ["DCIM/100TEST/IMG_0001.JPG": big, "DCIM/100TEST/IMG_0002.JPG": Data("small".utf8), "notes.txt": Data()]
        for (path, data) in contents {
            try data.write(to: card.appendingPathComponent(path))
        }
        try Data("junk".utf8).write(to: card.appendingPathComponent(".DS_Store"))
        return Fixture(root: root, card: card, first: first, second: second, contents: contents)
    }

    @Test func copiesToTwoDestinationsAndVerifiesEachFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shot = Date(timeIntervalSince1970: 1_600_000_000)
        let dated = fixture.card.appendingPathComponent("DCIM/100TEST/IMG_0002.JPG")
        try FileManager.default.setAttributes([.modificationDate: shot], ofItemAtPath: dated.path)

        let report = try await VerifiedCopier.copy(from: fixture.card, to: [fixture.first, fixture.second], folderName: "CARD copy") { _ in }

        #expect(report.everythingVerified)
        #expect(report.fileCount == 3)
        #expect(report.verified == 3)
        #expect(report.folders.count == 2)
        for folder in report.folders {
            for (path, data) in fixture.contents {
                #expect(try Data(contentsOf: folder.appendingPathComponent(path)) == data)
            }
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path))
            let copied = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("DCIM/100TEST/IMG_0002.JPG").path)
            #expect(copied[.modificationDate] as? Date == shot)
            let manifest = try String(contentsOf: folder.appendingPathComponent(VerifiedCopier.manifestName), encoding: .utf8)
            #expect(manifest.split(separator: "\n").count == 3)
            // SHA-256 of the empty file, in shasum's own format.
            #expect(manifest.contains("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  notes.txt"))
        }

        // A second run does not write into the first run's folder.
        let again = try await VerifiedCopier.copy(from: fixture.card, to: [fixture.first], folderName: "CARD copy") { _ in }
        #expect(again.folders.first?.lastPathComponent == "CARD copy 2")
    }

    @Test func reportsACopyThatDoesNotMatch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Flip one byte of one copy after it is written, as a bad drive would.
        let report = try await VerifiedCopier.copy(
            from: fixture.card,
            to: [fixture.first, fixture.second],
            folderName: "CARD copy",
            afterWrite: { url in
                guard url.path.contains("/second/"), url.lastPathComponent == "IMG_0001.JPG",
                      let handle = try? FileHandle(forUpdating: url) else { return }
                try? handle.seek(toOffset: 4_500_000)
                try? handle.write(contentsOf: Data([0xFF]))
                try? handle.close()
            },
            progress: { _ in }
        )

        #expect(!report.everythingVerified)
        #expect(report.verified == 2)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("IMG_0001.JPG") == true)
        let manifest = try String(contentsOf: report.folders[0].appendingPathComponent(VerifiedCopier.manifestName), encoding: .utf8)
        #expect(!manifest.contains("IMG_0001.JPG"))
    }

    @Test func refusesADestinationOnTheSameDriveAndAnEmptySource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: CopyError.sameVolume("first")) {
            try VerifiedCopier.checkDestinations([fixture.first], source: fixture.card)
        }
        let empty = fixture.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await #expect(throws: CopyError.nothingToCopy) {
            _ = try await VerifiedCopier.copy(from: empty, to: [fixture.first], folderName: "x") { _ in }
        }
    }
}
