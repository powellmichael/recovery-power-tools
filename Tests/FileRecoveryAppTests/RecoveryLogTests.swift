import Foundation
import Testing
@testable import FileRecoveryApp

private func tempLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("log-test-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("recovered.json")
}

@Suite struct RecoveryLogTests {
    @Test func roundTripsKeys() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var log = RecoveryLog.load(from: url)
        log.record("v1:100:200")
        log.record("v1:300:400")
        #expect(log.save() == nil)

        let reloaded = RecoveryLog.load(from: url)
        #expect(reloaded.contains("v1:100:200"))
        #expect(reloaded.contains("v1:300:400"))
        #expect(!reloaded.contains("v1:999:999"))
    }

    @Test func missingFileIsNormalFirstRun() throws {
        let log = RecoveryLog.load(from: tempLogURL())
        #expect(log.isReadable)
        #expect(log.loadError == nil)
    }

    /// The data-loss guard: a corrupt file must never read as an empty log,
    /// because the next save would overwrite thousands of real records.
    @Test func corruptFileBlocksSaveAndPreservesBytes() throws {
        let url = tempLogURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let corrupt = Data(#"["v1:1:1","v1:2:2"#.utf8) // truncated mid-write
        try corrupt.write(to: url)

        var log = RecoveryLog.load(from: url)
        #expect(!log.isReadable)
        #expect(log.loadError != nil)

        log.record("v1:new:entry")
        #expect(log.save() != nil, "save must refuse and report why")

        // The original bytes must still be on disk, untouched.
        #expect(try Data(contentsOf: url) == corrupt)
    }

    /// A readable log that gains entries must keep the old ones.
    @Test func savePreservesExistingEntries() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var first = RecoveryLog.load(from: url)
        for i in 0..<500 { first.record("v1:\(i):\(i)") }
        #expect(first.save() == nil)

        var second = RecoveryLog.load(from: url)
        second.record("v1:new:entry")
        #expect(second.save() == nil)

        let final = RecoveryLog.load(from: url)
        #expect(final.contains("v1:0:0"))
        #expect(final.contains("v1:499:499"))
        #expect(final.contains("v1:new:entry"))
    }

    /// The real log format is a JSON array of strings; decoding must keep
    /// working against a file written by the previous version.
    @Test func readsExistingArrayFormat() throws {
        let url = tempLogURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Data(#"["v1744734114:44730810368:5465768"]"#.utf8).write(to: url)
        let log = RecoveryLog.load(from: url)
        #expect(log.isReadable)
        #expect(log.contains("v1744734114:44730810368:5465768"))
    }
}
