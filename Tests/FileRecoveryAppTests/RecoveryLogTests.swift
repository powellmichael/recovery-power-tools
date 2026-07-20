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

@Suite struct ReviewLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("review-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("review.json")
    }

    @Test func roundTripsMarks() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var log = ReviewLog.load(from: url)
        log.set(.skipped, for: "v1:100:200")
        log.set(.recoveredElsewhere, for: "v1:300:400")
        #expect(log.save() == nil)

        let reloaded = ReviewLog.load(from: url)
        #expect(reloaded.mark(for: "v1:100:200") == .skipped)
        #expect(reloaded.mark(for: "v1:300:400") == .recoveredElsewhere)
        #expect(reloaded.mark(for: "v1:999:999") == nil)
    }

    @Test func clearingAMarkRemovesIt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var log = ReviewLog.load(from: url)
        log.set(.skipped, for: "v1:100:200")
        log.set(nil, for: "v1:100:200")
        #expect(log.save() == nil)
        #expect(ReviewLog.load(from: url).mark(for: "v1:100:200") == nil)
    }

    /// Same data-loss guard as RecoveryLog: corrupt file never reads as empty.
    @Test func corruptFileBlocksSave() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)

        var log = ReviewLog.load(from: url)
        #expect(!log.isReadable)
        log.set(.skipped, for: "v1:1:1")
        #expect(log.save() != nil)
        #expect(try Data(contentsOf: url) == corrupt)
    }
}

@MainActor
@Suite struct MultiSelectionTests {
    /// Builds a view model holding synthetic items. ScanSource needs a real
    /// file, so results are carved from a small blob.
    private func viewModelWithItems(_ count: Int) async throws -> (RecoveryViewModel, [RecoveredItem]) {
        var blob: [UInt8] = []
        for index in 0..<count {
            blob += [UInt8](repeating: 0xAA, count: 32)
            blob += [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
            blob += [UInt8](repeating: UInt8(index &+ 1), count: 100)
            blob += [0xFF, 0xD9]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiselect-\(UUID().uuidString).bin")
        try Data(blob).write(to: url)

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        let items = try await RecoveryScanner().scan(
            plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in }
        )

        let viewModel = RecoveryViewModel()
        viewModel.items = items
        return (viewModel, items)
    }

    /// Ticking one checkbox inside a multi-row selection marks the whole
    /// selection — the point of shift-selecting a range.
    @Test func checkboxAppliesToWholeSelection() async throws {
        let (viewModel, items) = try await viewModelWithItems(4)
        try #require(items.count == 4)

        viewModel.setTableSelection(Set(items.prefix(3).map(\.id)))
        viewModel.setSelectedForRecoveryRespectingSelection(items[0], isSelected: true)

        #expect(viewModel.selectedRecoveryIDs.count == 3)
        #expect(!viewModel.selectedRecoveryIDs.contains(items[3].id))
    }

    /// Clicking a row outside the selection must affect only that row.
    @Test func checkboxOutsideSelectionAffectsOnlyThatRow() async throws {
        let (viewModel, items) = try await viewModelWithItems(4)
        try #require(items.count == 4)

        viewModel.setTableSelection(Set(items.prefix(2).map(\.id)))
        viewModel.setSelectedForRecoveryRespectingSelection(items[3], isSelected: true)

        #expect(viewModel.selectedRecoveryIDs == [items[3].id])
    }

    /// A single highlighted row behaves exactly as before.
    @Test func singleSelectionTogglesOneRow() async throws {
        let (viewModel, items) = try await viewModelWithItems(3)
        try #require(items.count == 3)

        viewModel.setTableSelection([items[1].id])
        viewModel.setSelectedForRecoveryRespectingSelection(items[1], isSelected: true)

        #expect(viewModel.selectedRecoveryIDs == [items[1].id])
        #expect(viewModel.selectedItemID == items[1].id)
    }

    /// Selecting several rows leaves no single item to preview.
    @Test func multiSelectionDoesNotFocusOneItem() async throws {
        let (viewModel, items) = try await viewModelWithItems(3)
        viewModel.setTableSelection([items[0].id])
        #expect(viewModel.selectedItemID == items[0].id)

        viewModel.setTableSelection(Set(items.map(\.id)))
        #expect(viewModel.tableSelection.count == 3)
    }

    /// Shift-click selects the visible range between anchor and target.
    @Test func shiftExtendsRangeFromAnchor() async throws {
        let (viewModel, items) = try await viewModelWithItems(5)
        try #require(items.count == 5)

        viewModel.selectItem(items[1].id)   // anchor
        viewModel.extendSelection(to: items[3])

        #expect(viewModel.tableSelection == Set(items[1...3].map(\.id)))
    }

    /// Ranges work backwards too — anchor after the target.
    @Test func shiftExtendsRangeBackwards() async throws {
        let (viewModel, items) = try await viewModelWithItems(5)
        viewModel.selectItem(items[3].id)
        viewModel.extendSelection(to: items[1])

        #expect(viewModel.tableSelection == Set(items[1...3].map(\.id)))
    }

    /// Range follows what's on screen, not scan order: with a filter applied,
    /// hidden items between the endpoints must not be swept in.
    @Test func shiftRangeRespectsVisibleOrder() async throws {
        let (viewModel, items) = try await viewModelWithItems(5)
        // Hide everything already recovered, leaving a gap in the middle.
        viewModel.items[2].previouslyRecovered = true
        viewModel.recoveredVisibility = .unrecovered

        let visible = viewModel.filteredItems
        try #require(visible.count == 4)

        viewModel.selectItem(visible[0].id)
        viewModel.extendSelection(to: visible[2])

        #expect(viewModel.tableSelection.count == 3)
        #expect(!viewModel.tableSelection.contains(items[2].id))
    }

    /// Command-click adds and removes single cells without clearing the rest.
    @Test func commandTogglesIndividualItems() async throws {
        let (viewModel, items) = try await viewModelWithItems(4)

        viewModel.selectItem(items[0].id)
        viewModel.toggleSelection(items[2])
        #expect(viewModel.tableSelection == [items[0].id, items[2].id])

        viewModel.toggleSelection(items[2])
        #expect(viewModel.tableSelection == [items[0].id])
    }
}

@MainActor
@Suite struct ReviewMarkFilteringTests {
    private func viewModelWithItems(_ count: Int) async throws -> (RecoveryViewModel, [RecoveredItem]) {
        var blob: [UInt8] = []
        for index in 0..<count {
            blob += [UInt8](repeating: 0xAA, count: 32)
            blob += [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
            blob += [UInt8](repeating: UInt8(index &+ 1), count: 100)
            blob += [0xFF, 0xD9]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-vm-\(UUID().uuidString).bin")
        try Data(blob).write(to: url)

        let source = try ScanSource(fileURL: url)
        let plan = ScanPlan(regions: [ScanRegion(source: source, range: 0..<source.size)], note: nil)
        let items = try await RecoveryScanner().scan(
            plan: plan, selectedKinds: [.jpeg], progress: { _ in }, itemFound: { _ in }
        )
        let viewModel = RecoveryViewModel()
        viewModel.items = items
        return (viewModel, items)
    }

    /// "New" means still needing a decision — marked files drop out.
    @Test func newHidesSkippedAndElsewhere() async throws {
        let (viewModel, items) = try await viewModelWithItems(3)
        try #require(items.count == 3)

        viewModel.items[0].reviewMark = .skipped
        viewModel.items[1].reviewMark = .recoveredElsewhere
        viewModel.recoveredVisibility = .unrecovered

        #expect(viewModel.filteredItems.map(\.id) == [items[2].id])
    }

    /// "Recovered elsewhere" is recovered from the user's point of view.
    @Test func recoveredViewIncludesElsewhere() async throws {
        let (viewModel, items) = try await viewModelWithItems(3)
        viewModel.items[1].reviewMark = .recoveredElsewhere
        viewModel.recoveredVisibility = .recovered

        #expect(viewModel.filteredItems.map(\.id) == [items[1].id])
    }

    /// "Marked" shows exactly the recovery queue.
    @Test func markedShowsOnlyCheckedItems() async throws {
        let (viewModel, items) = try await viewModelWithItems(3)
        viewModel.setSelectedForRecovery(items[2], isSelected: true)
        viewModel.recoveredVisibility = .marked

        #expect(viewModel.filteredItems.map(\.id) == [items[2].id])
    }

    /// Select All must not queue files the user chose to skip.
    @Test func selectAllExcludesReviewMarked() async throws {
        let (viewModel, items) = try await viewModelWithItems(4)
        viewModel.items[0].reviewMark = .skipped
        viewModel.items[1].reviewMark = .recoveredElsewhere

        viewModel.selectAllForRecovery()

        #expect(viewModel.selectedRecoveryIDs == Set([items[2].id, items[3].id]))
    }
}
