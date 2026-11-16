import Foundation
import Testing
@testable import FileRecoveryApp

@Suite struct DuplicateFinderTests {
    /// A temp folder that cleans itself up.
    private final class Sandbox {
        let root: URL
        init() throws {
            // Resolved, so paths match what the enumerator returns (/private/var…).
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("dupes-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ path: String, _ bytes: [UInt8], modified: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }
    }

    private func names(_ group: DuplicateGroup) -> Set<String> {
        Set(group.files.map(\.url.lastPathComponent))
    }

    @Test func findsOnlyByteIdenticalFiles() async throws {
        let box = try Sandbox()
        let photo = [UInt8](repeating: 0x41, count: 20_000)
        // Same size and same first 4 KB as the photo, different later on:
        // only the full-content pass can tell these apart.
        var nearMiss = photo
        nearMiss[15_000] = 0x42

        try box.write("a/photo.jpg", photo)
        try box.write("b/copy of photo.jpg", photo)
        try box.write("b/deep/renamed.dat", photo)
        try box.write("a/near-miss.jpg", nearMiss)
        try box.write("a/small-1.txt", [1, 2, 3])
        try box.write("a/small-2.txt", [1, 2, 3])
        try box.write("a/unique.txt", [9, 9, 9, 9])
        try box.write("a/empty-1", [])
        try box.write("a/empty-2", [])
        // Left out by design: hidden files and the insides of packages.
        try box.write("a/.hidden-copy.jpg", photo)
        try box.write("a/Some.app/Contents/copy.jpg", photo)
        // The same file under other names, not extra copies.
        try FileManager.default.linkItem(
            at: box.root.appendingPathComponent("a/photo.jpg"),
            to: box.root.appendingPathComponent("a/hardlink.jpg")
        )
        try FileManager.default.createSymbolicLink(
            at: box.root.appendingPathComponent("a/symlink.jpg"),
            withDestinationURL: box.root.appendingPathComponent("a/photo.jpg")
        )

        // The second root overlaps the first; nothing may be counted twice.
        let result = try await DuplicateFinder().find(
            in: [box.root, box.root.appendingPathComponent("b")], progress: { _ in }
        )
        #expect(result.groups.count == 2)
        let big = try #require(result.groups.first)
        #expect(big.size == 20_000)
        #expect(big.files.count == 3)
        #expect(names(big).isSuperset(of: ["copy of photo.jpg", "renamed.dat"]))
        #expect(!names(big).isDisjoint(with: ["photo.jpg", "hardlink.jpg"]))
        #expect(big.reclaimableBytes == 40_000)
        #expect(names(result.groups[1]) == ["small-1.txt", "small-2.txt"])
        #expect(result.unreadable == 0)

        // The size floor drops the small pair.
        let filtered = try await DuplicateFinder().find(in: [box.root], minimumSize: 1000, progress: { _ in })
        #expect(filtered.groups.count == 1)
    }

    @MainActor private func scannedModel(_ box: Sandbox) async throws -> DuplicatesViewModel {
        let model = DuplicatesViewModel(trash: { try FileManager.default.removeItem(at: $0) })
        model.addFolders([box.root])
        model.startScan()
        for _ in 0..<500 where model.stage != .results { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.stage == .results)
        return model
    }

    @MainActor @Test func oneCopyAlwaysStays() async throws {
        let box = try Sandbox()
        let bytes = [UInt8](repeating: 7, count: 5000)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try box.write("old.bin", bytes, modified: old)
        try box.write("mid.bin", bytes, modified: old.addingTimeInterval(1000))
        try box.write("new.bin", bytes, modified: old.addingTimeInterval(2000))

        let model = try await scannedModel(box)
        let group = try #require(model.groups.first)
        #expect(model.suggestedKeeper(in: group)?.url.lastPathComponent == "old.bin")

        // Marking by hand: the third and last copy is refused.
        #expect(model.setMarked(true, file: group.files[0], in: group))
        #expect(model.setMarked(true, file: group.files[1], in: group))
        #expect(!model.setMarked(true, file: group.files[2], in: group))
        #expect(model.marked.count == 2)

        model.markAllDuplicates(keeping: .newest)
        #expect(Set(model.marked.map(\.lastPathComponent)) == ["old.bin", "mid.bin"])
        model.markAllDuplicates(keeping: .oldest)
        #expect(Set(model.marked.map(\.lastPathComponent)) == ["mid.bin", "new.bin"])
        #expect(model.markedBytes == 10_000)

        model.moveMarkedToTrash()
        #expect(model.trashReport == .init(moved: 2, freedBytes: 10_000, failures: []))
        #expect(model.groups.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: box.root.path)
        #expect(left == ["old.bin"])
    }

    /// A file edited after the scan may no longer be a duplicate, and a
    /// keeper that vanished leaves nothing to fall back on. Neither is moved.
    @MainActor @Test func changedFilesAreLeftAlone() async throws {
        let box = try Sandbox()
        let bytes = [UInt8](repeating: 7, count: 5000)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try box.write("one/keep.bin", bytes, modified: old)
        let edited = try box.write("one/edited.bin", bytes, modified: old.addingTimeInterval(10))
        let keeper = try box.write("two/keep.bin", [UInt8](repeating: 8, count: 6000), modified: old)
        let orphan = try box.write("two/orphan.bin", [UInt8](repeating: 8, count: 6000), modified: old.addingTimeInterval(10))

        let model = try await scannedModel(box)
        #expect(model.groups.count == 2)
        model.markAllDuplicates(keeping: .oldest)

        try Data([1, 2, 3]).write(to: edited)              // no longer a duplicate
        try FileManager.default.removeItem(at: keeper)     // the copy to keep is gone

        model.moveMarkedToTrash()
        #expect(model.trashReport?.moved == 0)
        #expect(model.trashReport?.failures.count == 2)
        #expect(FileManager.default.fileExists(atPath: edited.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }
}
