import Foundation

/// A saved list of scan results: enough to recover the files later without
/// re-scanning, plus enough to tell when that's no longer safe.
///
/// Free space is where the OS writes next, so a manifest is a fast path and not
/// a guarantee. Mounting a drive writes to it, and TRIM lets an SSD zero
/// deleted blocks with no filesystem activity at all. Every entry therefore
/// carries the fingerprint it had at scan time, and importing re-reads the
/// drive to confirm the bytes are still there before offering to recover them.
struct RecoveryManifest: Codable {
    /// Bumped when the shape changes; import refuses versions it doesn't know.
    static let currentVersion = 1

    var version = currentVersion
    var createdAt = Date()
    /// Filesystem volume serial. 0 when the filesystem wasn't recognized, in
    /// which case entries can only be matched by source name.
    var volumeID: UInt64
    var sourceName: String
    var scanNote: String?
    /// False when exported before the scan finished — the list is partial.
    var scanComplete: Bool
    var entries: [Entry]

    struct Entry: Codable {
        var offset: UInt64
        var length: UInt64
        var kind: MediaKind
        var fileExtension: String
        var originalFilename: String?
        /// Fragmented-file data runs; nil means contiguous at offset.
        var segments: [Range<UInt64>]?
        var fingerprint: String?
        var isDuplicate: Bool

        /// Whether the machine that wrote this manifest had already recovered
        /// the file. This is that machine's history, not a property of the
        /// drive — another machine can't verify it.
        var recoveredOnExportingMachine: Bool
        /// Set only for files recovered in the exporting session; earlier
        /// recoveries are recorded as a bare flag with no date or destination.
        var recoveredAt: Date?
        var recoveredTo: String?
    }

    /// Why an entry can't be recovered from this manifest any more.
    enum Staleness: String, Codable, Sendable {
        case volumeMismatch = "Different volume"
        case beyondEnd = "Past end of device"
        case contentChanged = "Data no longer matches"
        case unverifiable = "Could not read"
    }
}

extension RecoveryManifest {
    init(items: [RecoveredItem], volumeID: UInt64, sourceName: String, scanNote: String?, scanComplete: Bool) {
        self.volumeID = volumeID
        self.sourceName = sourceName
        self.scanNote = scanNote
        self.scanComplete = scanComplete
        self.entries = items.map { item in
            Entry(
                offset: item.byteOffset,
                length: item.byteLength,
                kind: item.kind,
                fileExtension: item.fileExtension,
                originalFilename: item.originalFilename,
                segments: item.segments,
                fingerprint: item.fingerprint,
                isDuplicate: item.isDuplicate,
                // A file recovered this session counts as recovered, as does one
                // the local log already knew about.
                recoveredOnExportingMachine: item.recoveredURL != nil || item.previouslyRecovered,
                recoveredAt: item.recoveredURL != nil ? Date() : nil,
                recoveredTo: item.recoveredURL?.path
            )
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RecoveryManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(RecoveryManifest.self, from: data)
        guard manifest.version <= currentVersion else {
            throw RecoveryError.manifestUnsupported(manifest.version)
        }
        return manifest
    }
}

/// One manifest entry resolved against a live drive.
struct VerifiedEntry: Identifiable, Sendable {
    let id = UUID()
    let item: RecoveredItem
    /// nil when the data is still exactly where the manifest said it was.
    let staleness: RecoveryManifest.Staleness?

    var isRecoverable: Bool { staleness == nil }
}

extension RecoveryScanner {
    /// Rebuilds items from a manifest and re-reads the drive to confirm each
    /// one's bytes still match. Entries that don't are returned marked rather
    /// than dropped, so the UI can say what was lost instead of silently
    /// shrinking the list.
    func verify(
        manifest: RecoveryManifest,
        against source: ScanSource,
        volumeID: UInt64
    ) -> [VerifiedEntry] {
        // A mismatched volume makes every recorded offset meaningless. Report
        // it once per entry rather than reading a single byte.
        let volumeMatches = manifest.volumeID == 0 || volumeID == 0 || manifest.volumeID == volumeID

        return manifest.entries.map { entry in
            var item = RecoveredItem(
                kind: entry.kind,
                source: source,
                byteOffset: entry.offset,
                byteLength: entry.length,
                fileExtension: entry.fileExtension,
                originalFilename: entry.originalFilename,
                segments: entry.segments
            )
            item.isDuplicate = entry.isDuplicate
            item.fingerprint = entry.fingerprint
            item.previouslyRecovered = entry.recoveredOnExportingMachine

            guard volumeMatches else {
                return VerifiedEntry(item: item, staleness: .volumeMismatch)
            }
            guard entry.offset + entry.length <= source.size else {
                return VerifiedEntry(item: item, staleness: .beyondEnd)
            }
            // Nothing recorded to compare against; treat as unverifiable rather
            // than claiming it's intact.
            guard let expected = entry.fingerprint else {
                return VerifiedEntry(item: item, staleness: .unverifiable)
            }
            guard let actual = fingerprint(for: item) else {
                return VerifiedEntry(item: item, staleness: .unverifiable)
            }
            return VerifiedEntry(item: item, staleness: actual == expected ? nil : .contentChanged)
        }
    }
}
