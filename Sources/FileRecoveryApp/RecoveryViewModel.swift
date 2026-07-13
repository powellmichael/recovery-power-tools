import AppKit
import Foundation
import SwiftUI

@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published var target: ScanTarget?
    @Published var destinationURL: URL?
    @Published var selectedKinds: Set<MediaKind> = [.jpeg]
    @Published var items: [RecoveredItem] = []
    @Published var progress = ScanProgress()
    @Published var state: ScanState = .idle
    @Published var selectedItemID: RecoveredItem.ID?
    @Published var selectedRecoveryIDs: Set<RecoveredItem.ID> = []
    @Published var previewImage: NSImage?
    @Published var previewFileURL: URL?
    @Published var previewError: String?
    @Published var externalDevices: [ExternalDevice] = []
    @Published var scanNote: String?

    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pendingItems: [RecoveredItem] = []
    private var flushScheduled = false
    private let scanner = RecoveryScanner()

    init() {
        // SwiftUI's Table focus and bare-key shortcuts are both unreliable on
        // macOS; an AppKit event monitor always sees arrow keys.
        // ponytail: monitor lives for the app's lifetime, never removed —
        // there is exactly one view model per app.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.items.isEmpty,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 125: // down arrow
                self.moveSelection(1)
                return nil
            case 126: // up arrow
                self.moveSelection(-1)
                return nil
            default:
                return event
            }
        }
    }

    var canScan: Bool {
        target != nil && state != .scanning && state != .recovering && !selectedKinds.isEmpty
    }

    var canRecover: Bool {
        destinationURL != nil && !selectedRecoveryIDs.isEmpty && state != .scanning && state != .recovering
    }

    /// Warns when the user picked a folder on an external drive: folder scans
    /// inspect live files only, so deleted files will never appear.
    var sourceWarning: String? {
        guard case .path(let url) = target,
              let device = DeviceDiscovery.externalDevice(containing: url, in: externalDevices) else { return nil }
        return "This folder is on \(device.displayName). Folder scans only look inside existing files — deleted files will NOT be found. Use Choose Drive and pick that device to scan its free space for deleted files."
    }

    var sourceLabel: String? {
        switch target {
        case .path(let url): url.lastPathComponent
        case .device(let device): device.displayName
        case nil: nil
        }
    }

    var selectedItem: RecoveredItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose Source"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            setTarget(.path(url))
        }
    }

    func chooseDevice(_ device: ExternalDevice) {
        setTarget(.device(device))
    }

    func refreshDevices() {
        Task { [weak self] in
            let devices = await Self.listDevices()
            self?.externalDevices = devices
        }
    }

    private nonisolated static func listDevices() async -> [ExternalDevice] {
        DeviceDiscovery.externalDevices()
    }

    private func setTarget(_ newTarget: ScanTarget) {
        target = newTarget
        items = []
        selectedRecoveryIDs = []
        selectedItemID = nil
        previewImage = nil
        previewFileURL = nil
        previewError = nil
        progress = ScanProgress()
        scanNote = nil
        state = .idle
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recovery Destination"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK {
            destinationURL = panel.url
        }
    }

    func toggleKind(_ kind: MediaKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }

    func startScan() {
        guard let target else { return }
        scanTask?.cancel()
        items = []
        selectedRecoveryIDs = []
        selectedItemID = nil
        previewImage = nil
        previewFileURL = nil
        previewError = nil
        progress = ScanProgress()
        scanNote = nil
        state = .scanning

        let scanner = scanner
        let kinds = selectedKinds

        scanTask = Task { [weak self] in
            do {
                // makePlan runs off the main actor; for devices it blocks on the
                // macOS authorization prompt.
                let plan = try await scanner.makePlan(for: target)
                await MainActor.run { self?.scanNote = plan.note }

                let found = try await scanner.scan(
                    plan: plan,
                    selectedKinds: kinds,
                    progress: { newProgress in
                        await MainActor.run { self?.progress = newProgress }
                    },
                    itemFound: { item in
                        await MainActor.run {
                            self?.enqueueFoundItem(item)
                        }
                    }
                )

                await MainActor.run {
                    guard let self else { return }
                    self.flushPendingItems()
                    let existingIDs = Set(self.items.map(\.id))
                    let missing = found.filter { !existingIDs.contains($0.id) }
                    self.items.append(contentsOf: missing)
                    self.selectedRecoveryIDs.formUnion(missing.map(\.id))
                    self.state = .finished
                }
            } catch is CancellationError {
                await MainActor.run { self?.state = .idle }
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        flushPendingItems()
        state = .idle
    }

    /// Found items are buffered and flushed a few times a second — appending
    /// them one at a time rebuilds the table constantly, which eats clicks
    /// and key presses.
    private func enqueueFoundItem(_ item: RecoveredItem) {
        pendingItems.append(item)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.flushScheduled = false
            self?.flushPendingItems()
        }
    }

    private func flushPendingItems() {
        guard !pendingItems.isEmpty else { return }
        items.append(contentsOf: pendingItems)
        selectedRecoveryIDs.formUnion(pendingItems.map(\.id))
        pendingItems = []
        if selectedItemID == nil, let first = items.first {
            selectedItemID = first.id
            preparePreview(for: first)
        }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedItemID } ?? (delta > 0 ? -1 : items.count)
        let newIndex = min(max(currentIndex + delta, 0), items.count - 1)
        selectItem(items[newIndex].id)
    }

    func selectItem(_ itemID: RecoveredItem.ID?) {
        selectedItemID = itemID
        guard let item = selectedItem else {
            previewImage = nil
            previewFileURL = nil
            previewError = nil
            return
        }
        preparePreview(for: item)
    }

    func isSelectedForRecovery(_ item: RecoveredItem) -> Bool {
        selectedRecoveryIDs.contains(item.id)
    }

    func setSelectedForRecovery(_ item: RecoveredItem, isSelected: Bool) {
        if isSelected {
            selectedRecoveryIDs.insert(item.id)
        } else {
            selectedRecoveryIDs.remove(item.id)
        }
    }

    func selectAllForRecovery() {
        selectedRecoveryIDs = Set(items.map(\.id))
    }

    func selectNoneForRecovery() {
        selectedRecoveryIDs = []
    }

    func recoverSelected() {
        guard let destinationURL else { return }
        if case .device(let device) = target,
           DeviceDiscovery.destination(destinationURL, isOnSameDiskAs: device) {
            state = .failed(RecoveryError.destinationOnSourceDisk.localizedDescription)
            return
        }
        state = .recovering

        let scanner = scanner
        let selected = items.filter { selectedRecoveryIDs.contains($0.id) }
        Task.detached { [weak self] in
            var outcomes: [(id: RecoveredItem.ID, url: URL?, error: String?)] = []
            for item in selected {
                if Task.isCancelled { break }
                do {
                    outcomes.append((item.id, try scanner.recover(item, to: destinationURL), nil))
                } catch {
                    outcomes.append((item.id, nil, error.localizedDescription))
                }
            }
            await self?.applyRecoveryOutcomes(outcomes)
        }
    }

    private func applyRecoveryOutcomes(_ outcomes: [(id: RecoveredItem.ID, url: URL?, error: String?)]) {
        for outcome in outcomes {
            guard let index = items.firstIndex(where: { $0.id == outcome.id }) else { continue }
            if let url = outcome.url {
                items[index].recoveredURL = url
                items[index].recoveryError = nil
            } else {
                items[index].recoveryError = outcome.error
            }
        }
        state = .finished
    }

    private func preparePreview(for item: RecoveredItem) {
        previewTask?.cancel()
        previewImage = nil
        previewFileURL = nil
        previewError = nil

        guard item.kind == .jpeg || item.kind == .png || item.kind == .heic || item.kind == .bmp else {
            return
        }

        let scanner = scanner
        previewTask = Task {
            do {
                let outputURL = Self.previewURL(for: item)
                try scanner.write(item, to: outputURL)
                try Task.checkCancellation()

                let image = NSImage(contentsOf: outputURL)

                await MainActor.run {
                    previewFileURL = outputURL
                    previewImage = image
                    previewError = image == nil ? "Preview unavailable" : nil
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    previewError = error.localizedDescription
                }
            }
        }
    }

    private nonisolated static func previewURL(for item: RecoveredItem) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRecoveryPreviews", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
    }
}
