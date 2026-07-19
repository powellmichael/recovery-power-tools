import Foundation
import Testing
@testable import FileRecoveryApp

private func makeTempFile(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("manifest-test-\(UUID().uuidString).bin")
    try Data(bytes).write(to: url)
    return url
}

private func jpegBlob(fill: UInt8, payload: Int = 200) -> [UInt8] {
    [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + [UInt8](repeating: fill, count: payload) + [0xFF, 0xD9]
}

/// Scans a blob and returns both the items and the source they came from.
private func scan(_ blob: [UInt8]) async throws -> ([RecoveredItem], ScanSource, URL) {
    let url = try makeTempFile(blob)
    let source = try ScanSource(fileURL: url)
    let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
    let items = try await RecoveryScanner().scan(
        plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in }
    )
    return (items, source, url)
}

@Suite struct ManifestTests {
    @Test func roundTripsThroughJSON() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, _, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 42, sourceName: "Test", scanNote: "note", scanComplete: true
        )
        let decoded = try RecoveryManifest.decode(try manifest.encoded())

        #expect(decoded.volumeID == 42)
        #expect(decoded.scanComplete)
        #expect(decoded.entries.count == items.count)
        #expect(decoded.entries.first?.offset == items.first?.byteOffset)
        #expect(decoded.entries.first?.length == items.first?.byteLength)
        #expect(decoded.entries.first?.fingerprint == items.first?.fingerprint)
    }

    /// The point of the whole feature: unchanged data verifies clean.
    @Test func verifiesUnchangedDataAsRecoverable() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, source, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 7, sourceName: "Test", scanNote: nil, scanComplete: true
        )
        let verified = RecoveryScanner().verify(manifest: manifest, against: source, volumeID: 7)

        #expect(verified.count == items.count)
        #expect(verified.allSatisfy { $0.isRecoverable })
    }

    /// Overwriting the bytes must be caught, not silently recovered as garbage.
    @Test func detectsOverwrittenData() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, _, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 7, sourceName: "Test", scanNote: nil, scanComplete: true
        )

        // Something else now occupies that offset.
        var rewritten = [UInt8](repeating: 0xAA, count: 64)
        rewritten += jpegBlob(fill: 0x99)
        let newURL = try makeTempFile(rewritten)
        defer { try? FileManager.default.removeItem(at: newURL) }
        let newSource = try ScanSource(fileURL: newURL)

        let verified = RecoveryScanner().verify(manifest: manifest, against: newSource, volumeID: 7)
        #expect(verified.allSatisfy { $0.staleness == .contentChanged })
        #expect(verified.allSatisfy { !$0.isRecoverable })
    }

    /// A different drive makes every recorded offset meaningless.
    @Test func rejectsMismatchedVolume() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, source, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 111, sourceName: "Test", scanNote: nil, scanComplete: true
        )
        let verified = RecoveryScanner().verify(manifest: manifest, against: source, volumeID: 222)
        #expect(verified.allSatisfy { $0.staleness == .volumeMismatch })
    }

    /// An entry pointing past the end of a smaller drive can't be read.
    @Test func detectsOffsetPastEndOfDevice() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, _, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 0, sourceName: "Test", scanNote: nil, scanComplete: true
        )
        let smallURL = try makeTempFile([UInt8](repeating: 0x00, count: 16))
        defer { try? FileManager.default.removeItem(at: smallURL) }
        let smallSource = try ScanSource(fileURL: smallURL)

        let verified = RecoveryScanner().verify(manifest: manifest, against: smallSource, volumeID: 0)
        #expect(verified.allSatisfy { $0.staleness == .beyondEnd })
    }

    /// Recovery state travels with the list, labelled as the exporter's claim.
    @Test func carriesRecoveredFlagAcrossExport() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, source, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        var marked = items
        marked[0].previouslyRecovered = true

        let manifest = RecoveryManifest(
            items: marked, volumeID: 7, sourceName: "Test", scanNote: nil, scanComplete: true
        )
        let decoded = try RecoveryManifest.decode(try manifest.encoded())
        #expect(decoded.entries.first?.recoveredOnExportingMachine == true)

        let verified = RecoveryScanner().verify(manifest: decoded, against: source, volumeID: 7)
        #expect(verified.first?.item.previouslyRecovered == true)
    }

    @Test func recordsPartialScan() async throws {
        var blob = [UInt8](repeating: 0xAA, count: 64)
        blob += jpegBlob(fill: 0x11)
        let (items, _, url) = try await scan(blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let manifest = RecoveryManifest(
            items: items, volumeID: 1, sourceName: "Test", scanNote: nil, scanComplete: false
        )
        let decoded = try RecoveryManifest.decode(try manifest.encoded())
        #expect(decoded.scanComplete == false)
    }

    /// A newer format must be refused rather than half-read.
    @Test func refusesUnknownFutureVersion() throws {
        let json = """
        {"version":99,"createdAt":"2026-01-01T00:00:00Z","volumeID":1,
         "sourceName":"x","scanComplete":true,"entries":[]}
        """
        #expect(throws: RecoveryError.self) {
            try RecoveryManifest.decode(Data(json.utf8))
        }
    }
}
